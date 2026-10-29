"""Two-week summary of replayed arrival predictions, split by day type and estimated horizon.

Complements score.py (which groups by the actual remaining time) with the views used to judge and
recalibrate the App after the full 2026-10-14..28 recording:
- the App's shown estimates by *estimated* remaining time (0-5, 5-10, 10-20, 20+ min), separately for
  workdays, weekends and national holidays, plus how often the shown reference range held the arrival;
- the same rows timed with only the generic driving rule (distance / speed + allowance per stop), and the
  speed and allowance that would fit best;
- the official EstimateTime against the next bus to pass, by its own estimate;
- ride times between two stops of one bus, from estimates the App showed (the quantity spreadFraction
  describes), and the spread that holds 80% of them, by evidence;
- days after --holdout-from separately, for checking corrections fitted on earlier days.

Predictions made in the last 45 minutes of a recording are dropped: their buses may arrive after it ends.
Requires pandas and numpy.

    python3 fortnight.py results/replay/* [--holdout-from 2026-10-22T02:00Z] [--json out.json]
"""
import argparse, json, re
from pathlib import Path
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
CALENDAR = ROOT / 'ios/TransitCore/Sources/TransitCore/TransitServiceCalendar.swift'
TAIL = 45 * 60
BUCKETS = [(0, 5), (5, 10), (10, 20), (20, 30)]
PREDICTION_COLUMNS = ['made_at', 'vehicle', 'stop', 'stops_ahead', 'distance_m', 'evidence', 'predicted_s',
                      'uncertainty_s', 'shown', 'actual_arrive_s', 'label_min', 'range_low_min', 'range_high_min']


def holidays():
    text = CALENDAR.read_text(encoding='utf-8')
    return set(re.findall(r'"(\d{8})"', text.split('holidays: Set<String> =')[1].split(']')[0]))


def day_type(made_at, listed):
    local = pd.to_datetime(made_at, unit='s', utc=True).dt.tz_convert('Asia/Taipei')
    key = local.dt.strftime('%Y%m%d')
    kind = np.where(key.isin(listed), 'holiday', np.where(local.dt.dayofweek >= 5, 'weekend', 'workday'))
    return pd.Series(kind, index=made_at.index), local


def stats(error, inside=None):
    if len(error) == 0:
        return {'n': 0}
    absolute = error.abs()
    result = {'n': int(len(error)), 'mae_min': absolute.mean() / 60, 'p90_min': absolute.quantile(0.9) / 60,
              'bias_min': error.mean() / 60, 'median_bias_min': error.median() / 60,
              'within_2min': float((absolute <= 120).mean()), 'early_over_2min': float((error < -120).mean()),
              'late_over_2min': float((error > 120).mean())}
    if inside is not None:
        result['in_range'] = float(inside.mean())
    return result


def bucketed(frame, horizon, error, inside=None):
    out = {}
    for low, high in BUCKETS:
        mask = (horizon >= low * 60) & (horizon < high * 60)
        out[f'{low}-{high}'] = stats(error[mask], None if inside is None else inside[mask])
    out['all'] = stats(error, inside)
    return out


def load(folders):
    frames, officials = [], []
    for folder in folders:
        folder = Path(folder)
        end = json.loads((folder / 'summary.json').read_text())['recordingEnd']
        df = pd.read_csv(folder / 'predictions.csv.gz', usecols=PREDICTION_COLUMNS,
                         dtype={'vehicle': 'category', 'stop': 'category', 'evidence': 'category'})
        # Only rows that can be scored are kept, so two weeks fit in memory.
        frames.append(df[(df.made_at <= end - TAIL) & df.predicted_s.notna() & df.actual_arrive_s.notna()
                         & (df.predicted_s <= 1800)])
        of = pd.read_csv(folder / 'official.csv.gz', usecols=['made_at', 'official_s', 'actual_arrive_s'])
        officials.append(of[(of.made_at <= end - TAIL)])
    frame = pd.concat(frames, ignore_index=True)
    for column in ['vehicle', 'stop', 'evidence']:
        frame[column] = frame[column].astype(str).astype('category')
    return frame, pd.concat(officials, ignore_index=True)


def ride_pairs(df):
    """Consecutive sampled stops of one bus at one moment: predicted vs actual time between them."""
    rows = df[df.actual_arrive_s.notna() & (df.predicted_s > 0)].sort_values(['vehicle', 'made_at', 'stops_ahead'])
    same = (rows.vehicle.values[1:] == rows.vehicle.values[:-1]) & (rows.made_at.values[1:] == rows.made_at.values[:-1])
    predicted = rows.predicted_s.values[1:] - rows.predicted_s.values[:-1]
    actual = rows.actual_arrive_s.values[1:] - rows.actual_arrive_s.values[:-1]
    pairs = pd.DataFrame({'predicted': predicted, 'actual': actual, 'evidence': rows.evidence.values[1:]})[same]
    return pairs[(pairs.predicted >= 180) & (pairs.actual > 0)]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('folders', nargs='+')
    parser.add_argument('--holdout-from', help='ISO time; predictions from then on are also reported separately')
    parser.add_argument('--json')
    args = parser.parse_args()
    listed = holidays()
    df, official = load(args.folders)
    df['kind'], local = day_type(df.made_at, listed)
    df['hour'] = local.dt.hour
    known = df[df.actual_arrive_s.notna()]
    shown = known[(known.shown == 1) & (known.predicted_s <= 1800)].copy()
    shown_estimate = shown.label_min * 60
    error = shown.actual_arrive_s - shown_estimate
    inside = (shown.actual_arrive_s >= shown.range_low_min * 60 - 30) & (shown.actual_arrive_s < shown.range_high_min * 60 + 30)
    result = {'rows': {'scored_candidates': int(len(known)), 'shown_scored': int(len(shown))},
              'first': str(local.min()), 'last': str(local.max())}

    result['app_shown'] = {kind: bucketed(shown[m], shown_estimate[m], error[m], inside[m])
                           for kind in ['workday', 'weekend', 'holiday'] for m in [shown.kind == kind]}
    result['app_shown']['all'] = bucketed(shown, shown_estimate, error, inside)
    result['app_by_evidence'] = {str(e): stats(error[shown.evidence == e], inside[shown.evidence == e])
                                 for e in shown.evidence.cat.categories if (shown.evidence == e).any()}
    if args.holdout_from:
        cut = pd.Timestamp(args.holdout_from).timestamp()
        for name, m in [('before', shown.made_at < cut), ('from', shown.made_at >= cut)]:
            result[f'holdout_{name}'] = bucketed(shown[m], shown_estimate[m], error[m], inside[m])

    # The generic rule on the same rows, and the rule that would fit them best.
    generic = shown.distance_m / 4.5 + 20 * shown.stops_ahead
    result['generic_4.5_20'] = bucketed(shown, generic, shown.actual_arrive_s - generic)
    result['app_raw_same_rows'] = bucketed(shown, shown.predicted_s, shown.actual_arrive_s - shown.predicted_s)
    sample = shown.sample(min(len(shown), 2_000_000), random_state=1)
    best = None
    for speed in np.arange(3.0, 9.01, 0.25):
        for allowance in range(0, 61, 5):
            mae = (sample.actual_arrive_s - sample.distance_m / speed - allowance * sample.stops_ahead).abs().mean()
            if best is None or mae < best[0]:
                best = (mae, float(speed), allowance)
    speed, allowance = best[1], best[2]
    fitted = shown.distance_m / speed + allowance * shown.stops_ahead
    result['generic_best'] = {'speed_mps': speed, 'stop_s': allowance,
                              'metrics': bucketed(shown, fitted, shown.actual_arrive_s - fitted)}

    # Official EstimateTime against the next bus, grouped by its own estimate.
    official['kind'], _ = day_type(official.made_at, listed)
    of = official[(official.official_s > 0) & official.actual_arrive_s.notna() & (official.official_s <= 1800)]
    result['official'] = {kind: bucketed(of[m], of.official_s[m], (of.actual_arrive_s - of.official_s)[m])
                          for kind in ['workday', 'weekend', 'holiday'] for m in [of.kind == kind]}
    result['official']['all'] = bucketed(of, of.official_s, of.actual_arrive_s - of.official_s)

    # Ride time between stops: the spread that holds 80% of rides.
    pairs = ride_pairs(known[known.shown == 1])
    ratio = (pairs.actual / pairs.predicted - 1).abs()
    result['ride_spread'] = {str(e): {'n': int(m.sum()), 'p80_abs_ratio': float(ratio[m].quantile(0.8)),
                                      'median_ratio': float((pairs.actual / pairs.predicted)[m].median())}
                             for e in pairs.evidence.cat.categories for m in [pairs.evidence == e] if m.sum() > 1000}
    result['ride_spread']['all'] = {'n': int(len(pairs)), 'p80_abs_ratio': float(ratio.quantile(0.8)),
                                    'median_ratio': float((pairs.actual / pairs.predicted).median())}

    text = json.dumps(result, ensure_ascii=False, indent=1, default=float)
    if args.json:
        Path(args.json).write_text(text + '\n')
    print(text)


if __name__ == '__main__':
    main()
