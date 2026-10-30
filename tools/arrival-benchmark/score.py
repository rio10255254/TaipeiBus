"""Score arrival predictions replayed by tools/arrival-benchmark/replay against actual arrivals.

Reads one or more replay output folders (predictions.csv.gz, official.csv.gz, summary.json)
and writes a Markdown report plus metrics.json. Standard library only.

Error is actual minus predicted: positive means the bus came later than shown,
negative means it came earlier (the costly case: a rider can miss it).
"""
import argparse, csv, gzip, json, math
from datetime import datetime, timezone, timedelta
from pathlib import Path

TAIPEI = timezone(timedelta(hours=8))
# Horizon buckets by the actual remaining time, in minutes.
BUCKETS = [(0, 2), (2, 5), (5, 10), (10, 15), (15, 20), (20, 30)]
LIMIT = 30 * 60
HOURS = [(5, 7, '05–07'), (7, 9, '07–09 早尖峰'), (9, 16, '09–16'), (16, 19, '16–19 晚尖峰'), (19, 24, '19–24'), (0, 5, '00–05')]


def bucket(seconds):
    minutes = seconds / 60
    for low, high in BUCKETS:
        if low <= minutes < high:
            return f'{low}–{high} 分'
    return None


def hour_band(timestamp):
    hour = datetime.fromtimestamp(timestamp, TAIPEI).hour
    for low, high, label in HOURS:
        if low <= hour < high:
            return label
    return '?'


def percentile(sorted_values, share):
    if not sorted_values:
        return None
    index = min(len(sorted_values) - 1, max(0, math.ceil(share * len(sorted_values)) - 1))
    return sorted_values[index]


class Stats:
    """Error statistics for one group of (predicted, actual[, uncertainty]) pairs."""

    def __init__(self):
        self.errors = []
        self.in_range = 0
        self.with_range = 0

    def add(self, predicted, actual, in_range=None):
        self.errors.append(actual - predicted)
        if in_range is not None:
            self.with_range += 1
            self.in_range += in_range

    def summary(self):
        if not self.errors:
            return {'n': 0}
        absolute = sorted(abs(e) for e in self.errors)
        n = len(self.errors)
        result = {
            'n': n,
            'mae_s': sum(absolute) / n,
            'median_ae_s': percentile(absolute, 0.5),
            'p90_ae_s': percentile(absolute, 0.9),
            'bias_s': sum(self.errors) / n,
            'within_1min': sum(a <= 60 for a in absolute) / n,
            'within_2min': sum(a <= 120 for a in absolute) / n,
            'early_over_1min': sum(e < -60 for e in self.errors) / n,
            'early_over_2min': sum(e < -120 for e in self.errors) / n,
            'late_over_2min': sum(e > 120 for e in self.errors) / n,
        }
        if self.with_range:
            result['within_shown_range'] = self.in_range / self.with_range
        return result


def number(text):
    return float(text) if text not in ('', None) else None


def shown_minutes(row, predicted, uncertainty):
    """The minute label and reference range the App showed: recorded by newer replays, otherwise
    rebuilt with the formulas of App versions up to 1.8.18 (both rounded up)."""
    if row.get('label_min'):
        return int(row['label_min']), int(row['range_low_min']), int(row['range_high_min'])
    low = max(1, math.ceil((predicted - uncertainty) / 60))
    return max(1, math.ceil(predicted / 60)), low, max(low, math.ceil((predicted + uncertainty) / 60))


def score_predictions(folders):
    overall, displayed, by_bucket, by_evidence, by_hour = Stats(), Stats(), {}, {}, {}
    brackets = []
    coverage = {}  # bucket -> [rows with known actual, rows shown]
    rows = matched = 0
    for folder in folders:
        with gzip.open(folder / 'predictions.csv.gz', 'rt', newline='') as handle:
            for row in csv.DictReader(handle):
                rows += 1
                actual = number(row['actual_arrive_s'])
                if actual is None or actual > LIMIT:
                    continue
                matched += 1
                label = bucket(actual)
                if label is None:
                    continue
                entry = coverage.setdefault(label, [0, 0])
                entry[0] += 1
                if row['shown'] != '1':
                    continue
                entry[1] += 1
                predicted, uncertainty = float(row['predicted_s']), float(row['uncertainty_s'])
                minute, low, high = shown_minutes(row, predicted, uncertainty)
                # The range a rider reads in whole minutes contains the arrival when it rounds into it.
                in_range = low * 60 - 30 <= actual < high * 60 + 30
                overall.add(predicted, actual, in_range)
                # What the rider reads: "約 N 分" (VehicleArrivalPrediction.label).
                displayed.add(minute * 60, actual)
                brackets.append(float(row['arrive_bracket_s']))
                by_bucket.setdefault(label, Stats()).add(predicted, actual, in_range)
                by_evidence.setdefault(row['evidence'], Stats()).add(predicted, actual, in_range)
                by_hour.setdefault(hour_band(float(row['made_at'])), Stats()).add(predicted, actual, in_range)
    return {
        'rows': rows, 'rows_with_actual_within_30min': matched,
        'shown': overall.summary(),
        'shown_as_displayed_minutes': displayed.summary(),
        'actual_bracket_s': {'median': percentile(sorted(brackets), 0.5), 'p90': percentile(sorted(brackets), 0.9)},
        'by_horizon': {k: by_bucket[k].summary() for k in sorted(by_bucket, key=order)},
        'by_evidence': {k: v.summary() for k, v in sorted(by_evidence.items())},
        'by_hour': {k: by_hour[k].summary() for k in [h[2] for h in HOURS] if k in by_hour},
        'coverage': {k: {'known': v[0], 'shown': v[1], 'share': v[1] / v[0] if v[0] else 0}
                     for k, v in sorted(coverage.items(), key=lambda item: order(item[0]))},
    }


def score_official(folders):
    overall, by_bucket, by_hour = Stats(), {}, {}
    rows = matched = 0
    for folder in folders:
        with gzip.open(folder / 'official.csv.gz', 'rt', newline='') as handle:
            for row in csv.DictReader(handle):
                rows += 1
                actual, official = number(row['actual_arrive_s']), float(row['official_s'])
                if actual is None or official > LIMIT or actual > LIMIT:
                    continue
                matched += 1
                label = bucket(actual)
                if label is None:
                    continue
                overall.add(official, actual)
                by_bucket.setdefault(label, Stats()).add(official, actual)
                by_hour.setdefault(hour_band(float(row['made_at'])), Stats()).add(official, actual)
    return {
        'rows': rows, 'rows_with_actual_within_30min': matched,
        'all': overall.summary(),
        'by_horizon': {k: by_bucket[k].summary() for k in sorted(by_bucket, key=order)},
        'by_hour': {k: by_hour[k].summary() for k in [h[2] for h in HOURS] if k in by_hour},
    }


def order(label):
    return float(label.split('–')[0])


def fmt_seconds(value):
    return '—' if value is None else f'{value / 60:.1f} 分'


def fmt_share(value):
    return '—' if value is None else f'{value * 100:.0f}%'


def table(groups, title, with_range=True):
    head = ['', '筆數', '平均誤差', '中位誤差', '90% 誤差在', '偏差', '±1 分內', '±2 分內', '早到 >2 分', '晚到 >2 分']
    if with_range:
        head.append('落在顯示範圍')
    lines = [f'| {title} | ' + ' | '.join(head[1:]) + ' |', '|' + '---|' * len(head)]
    for name, s in groups.items():
        if not s.get('n'):
            continue
        cells = [f"{s['n']:,}", fmt_seconds(s['mae_s']), fmt_seconds(s['median_ae_s']), fmt_seconds(s['p90_ae_s']),
                 ('+' if s['bias_s'] >= 0 else '−') + fmt_seconds(abs(s['bias_s'])),
                 fmt_share(s['within_1min']), fmt_share(s['within_2min']), fmt_share(s['early_over_2min']), fmt_share(s['late_over_2min'])]
        if with_range:
            cells.append(fmt_share(s.get('within_shown_range')))
        lines.append(f'| {name} | ' + ' | '.join(cells) + ' |')
    return '\n'.join(lines)


EVIDENCE = {'roadHistory': '近期車輛通過紀錄', 'officialProfile': '官方分時段車程', 'recentMovement': '這輛車近期行駛',
            'routeProgress': 'GPS 位置與沿線車程', 'limited': '資料有限'}


def report(metrics, summaries):
    p, o = metrics['predictions'], metrics['official']
    spans = ', '.join(f"{datetime.fromisoformat(s['firstPoll'].replace('Z', '+00:00')).astimezone(TAIPEI):%m-%d %H:%M}"
                      f"–{datetime.fromisoformat(s['lastPoll'].replace('Z', '+00:00')).astimezone(TAIPEI):%H:%M}"
                      for s in summaries if s.get('firstPoll'))
    out = ['# 到站預估基準分數', '',
           f'錄製時段（台北時間）：{spans}。', '',
           '誤差 = 實際到站 − 預估。正值代表公車比顯示的晚到，負值代表提早到（乘客可能錯過）。'
           '「實際到站」是同一輛車的 GPS 軌跡進入站牌前 30 公尺的時間，以相鄰兩筆回報內插；只計算 30 分鐘內實際到站的情況。', '',
           '## App 每輛車的「約幾分」', '',
           f"App 實際會顯示分鐘數的預估共 {p['shown'].get('n', 0):,} 筆（逐分鐘、逐車、抽樣 20% 站牌）。", '',
           table({'預估秒數': p['shown']}, '整體'), '',
           table({'畫面上的整數分鐘': p['shown_as_displayed_minutes']}, '乘客看到的', with_range=False), '',
           f"實際到站時間由前後兩筆 GPS 回報內插，兩筆間隔中位數 {p['actual_bracket_s']['median']:.0f} 秒、"
           f"90% 在 {p['actual_bracket_s']['p90']:.0f} 秒內，所以「實際到站」本身約有 ±10–15 秒的不確定。", '',
           table(p['by_horizon'], '依實際剩餘時間'), '',
           table({EVIDENCE.get(k, k): v for k, v in p['by_evidence'].items()}, '依推估依據'), '',
           table(p['by_hour'], '依時段'), '',
           '### 顯示比例', '', '同一輛車在 30 分鐘內確實到站時，App 有多少比例會顯示分鐘數（其餘顯示站數或「時間待確認」）。', '',
           '| 實際剩餘時間 | 有實際到站 | 顯示分鐘 | 比例 |', '|---|---|---|---|']
    for name, c in p['coverage'].items():
        out.append(f"| {name} | {c['known']:,} | {c['shown']:,} | {fmt_share(c['share'])} |")
    out += ['', '## 官方路線預估（EstimateTime，下一班）', '',
            '官方預估不指定車牌，這裡對照的是同路線下一輛實際通過該站的公車。若有公車沒有回報 GPS，'
            '「下一班」會被誤認為更晚的一班，所以官方誤差可能被高估；兩張表的對象不同，不是同一題的直接比較。', '',
            table({'全部': o['all']}, '整體', with_range=False), '',
            table(o['by_horizon'], '依實際剩餘時間', with_range=False), '',
            table(o['by_hour'], '依時段', with_range=False), '',
            '## 資料涵蓋', '',
            f"- 預估列：{p['rows']:,}，其中 30 分鐘內有實際到站：{p['rows_with_actual_within_30min']:,}",
            f"- 官方預估列：{o['rows']:,}，其中 30 分鐘內找到下一班：{o['rows_with_actual_within_30min']:,}", '']
    return '\n'.join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folders', nargs='+', type=Path, help='replay output folders')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    summaries = [json.loads((f / 'summary.json').read_text()) for f in args.folders]
    metrics = {'predictions': score_predictions(args.folders), 'official': score_official(args.folders), 'runs': summaries}
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'metrics.json').write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + '\n')
    (args.out / 'report.md').write_text(report(metrics, summaries), encoding='utf-8')
    print((args.out / 'report.md').read_text(encoding='utf-8'))


if __name__ == '__main__':
    main()
