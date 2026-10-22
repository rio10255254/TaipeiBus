"""Fit the arrival corrections in ForecastTuning from replayed predictions.

Reads replay folders (tools/arrival-benchmark/replay), keeps the predictions the App showed with a
known actual arrival, and fits:
- workdayPaceFactors / holidayPaceFactors: the median of actual ÷ estimated time by Taipei hour, for
  estimates not built purely from other buses' recent crossings (evidence other than roadHistory).
  The median, not the mean: late buses have a long tail, and matching the mean would make the
  typical bus arrive earlier than shown more often;
- rangeEarlyScale / rangeLateScale: how many uncertainties the reference range must span on each
  side so that about 80% of arrivals fall inside it.

Factors are multiplied into the ones in effect during the replay (--base, a tuning.json; default 1),
so running replay → fit repeatedly converges instead of correcting twice. Hours with little data are
pulled towards 1. Requires pandas and numpy.

    python3 fit_corrections.py results/replay/* [--base runtime/tuning.json] [--test-days 10-21 10-22]
        [--write-swift] [--write-tuning runtime/tuning.json]
"""
import argparse, json, re
from pathlib import Path
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / 'ios/TransitCore/Sources/TransitCore/ForecastTuning.swift'
CALENDAR = ROOT / 'ios/TransitCore/Sources/TransitCore/TransitServiceCalendar.swift'
COLUMNS = ['made_at', 'evidence', 'predicted_s', 'uncertainty_s', 'shown', 'actual_arrive_s']
# Bounds must stay inside ForecastTuning.tables / fields; tighter here so one odd fortnight cannot swing the App far.
FACTOR_RANGE = (0.9, 1.3)
SHRINK = 20000   # rows at which an hour's own ratio counts half
COVERAGE = 0.8


def holidays():
    """The App's office calendar (TransitServiceCalendar.swift): listed holidays plus weekends."""
    text = CALENDAR.read_text(encoding='utf-8')
    listed = set(re.findall(r'"(\d{8})"', text.split('holidays: Set<String> =')[1].split(']')[0]))
    working = set(re.findall(r'"(\d{8})"', text.split('workingWeekends: Set<String> =')[1].split(']')[0]))
    return listed, working


def load(folders):
    frames = []
    for folder in folders:
        df = pd.read_csv(Path(folder) / 'predictions.csv.gz', usecols=COLUMNS)
        frames.append(df[(df.shown == 1) & df.actual_arrive_s.notna() & (df.actual_arrive_s <= 2400)].drop(columns='shown'))
    df = pd.concat(frames, ignore_index=True)
    local = pd.to_datetime(df.made_at, unit='s', utc=True).dt.tz_convert('Asia/Taipei')
    listed, working = holidays()
    key = local.dt.strftime('%Y%m%d')
    df['hour'] = local.dt.hour
    df['day'] = local.dt.strftime('%m-%d')
    df['holiday'] = key.isin(listed) | ((local.dt.dayofweek >= 5) & ~key.isin(working))
    return df


def base_tables(path):
    tables = {'workdayPaceFactors': [1.0] * 24, 'holidayPaceFactors': [1.0] * 24}
    if path:
        document = json.loads(Path(path).read_text(encoding='utf-8'))
        for key in tables:
            tables[key] = [float(v) for v in document.get(key, tables[key])]
    return tables


def fit_factors(df, base):
    rows = df[(df.evidence != 'roadHistory') & (df.predicted_s > 120)]
    ratios = (rows.actual_arrive_s / rows.predicted_s).groupby([rows.holiday, rows.hour]).agg(['median', 'size'])
    tables = {}
    for holiday, key in [(False, 'workdayPaceFactors'), (True, 'holidayPaceFactors')]:
        values = []
        for hour in range(24):
            residual = 1.0
            if (holiday, hour) in ratios.index:
                entry = ratios.loc[(holiday, hour)]
                weight = entry['size'] / (entry['size'] + SHRINK)
                residual = 1 + (entry['median'] - 1) * weight
            values.append(round(float(np.clip(base[key][hour] * residual, *FACTOR_RANGE)), 3))
        tables[key] = values
    return tables


def corrected(df, tables, base):
    """Approximate the App's correction per prediction (the App scales segments, not whole estimates)."""
    def factor(column, holiday):
        new = np.array(tables['holidayPaceFactors' if holiday else 'workdayPaceFactors'])
        old = np.array(base['holidayPaceFactors' if holiday else 'workdayPaceFactors'])
        return (new / old)[df.hour.to_numpy()]
    scale = np.where(df.holiday, factor(None, True), factor(None, False))
    scale = np.where(df.evidence == 'roadHistory', 1.0, scale)
    return df.predicted_s * scale, df.uncertainty_s * scale


def fit_range(df, predicted, uncertainty):
    z = (df.actual_arrive_s - predicted) / uncertainty
    tail = (1 - COVERAGE) / 2
    return round(float(np.clip(-z.quantile(tail), 0.5, 3)), 2), round(float(np.clip(z.quantile(1 - tail), 0.5, 4)), 2)


def evaluate(name, df, predicted, uncertainty, early, late, rounding):
    actual = df.actual_arrive_s
    shown = np.maximum(1, rounding(predicted / 60)) * 60
    error = actual - shown
    lower = np.maximum(1, np.round((predicted - early * uncertainty) / 60))
    upper = np.maximum(lower, np.round((predicted + late * uncertainty) / 60))
    inside = ((actual >= lower * 60 - 30) & (actual < upper * 60 + 30)).mean()
    absolute = (actual - predicted).abs()
    print(f'{name:34s} MAE {absolute.mean() / 60:.2f}  p90 {absolute.quantile(.9) / 60:.2f}  bias {(actual - predicted).mean() / 60:+.2f} min | '
          f'shown ±2 min {(error.abs() <= 120).mean():.0%}  early >2 {(error < -120).mean():.1%}  late >2 {(error > 120).mean():.1%} | '
          f'in range {inside:.0%} (width {(upper - lower).mean():.1f} min)')


def write_swift(tables):
    text = SWIFT.read_text(encoding='utf-8')
    def literal(values):
        return '[' + ', '.join(f'{v:g}' for v in values) + ']'
    block = ('    // MEASURED-FACTORS-BEGIN\n'
             f'    static let measuredWorkdayFactors: [Double] = {literal(tables["workdayPaceFactors"])}\n'
             f'    static let measuredHolidayFactors: [Double] = {literal(tables["holidayPaceFactors"])}\n'
             '    // MEASURED-FACTORS-END')
    text = re.sub(r'    // MEASURED-FACTORS-BEGIN.*?// MEASURED-FACTORS-END', block, text, flags=re.S)
    SWIFT.write_text(text, encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('folders', nargs='+')
    parser.add_argument('--base', help='tuning.json whose factors were in effect during the replay')
    parser.add_argument('--test-days', nargs='*', default=[], help='MM-DD days held out from fitting and reported separately')
    parser.add_argument('--write-swift', action='store_true', help='store the factors as the App defaults')
    parser.add_argument('--write-tuning', help='store factors and range scales in this tuning.json')
    parser.add_argument('--json', help='write the fitted values here')
    args = parser.parse_args()

    df = load(args.folders)
    base = base_tables(args.base)
    train = df[~df.day.isin(args.test_days)]
    tables = fit_factors(train, base)
    predicted, uncertainty = corrected(train, tables, base)
    early, late = fit_range(train, predicted, uncertainty)
    print(f'rows: fit {len(train):,}, held out {len(df) - len(train):,}; days {sorted(df.day.unique())}')
    print('workday', tables['workdayPaceFactors'])
    print('holiday', tables['holidayPaceFactors'])
    print(f'range scales: early {early}, late {late}')
    for name, part in [('fit days', train)] + ([('held-out days', df[df.day.isin(args.test_days)])] if args.test_days else []):
        p, u = corrected(part, tables, base)
        evaluate(f'{name}: before (round up)', part, part.predicted_s, part.uncertainty_s, 1, 1, np.ceil)
        evaluate(f'{name}: corrected + nearest', part, p, u, early, late, np.round)

    fitted = {**tables, 'rangeEarlyScale': early, 'rangeLateScale': late}
    if args.json:
        Path(args.json).write_text(json.dumps(fitted, indent=2) + '\n')
    if args.write_swift:
        write_swift(tables)
    if args.write_tuning:
        path = Path(args.write_tuning)
        document = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {'schemaVersion': 1}
        document.update(fitted)
        path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
