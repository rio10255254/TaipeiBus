"""Record Taipei's or New Taipei's public bus feeds for measuring arrival-prediction accuracy.

Stores what is needed to replay every prediction method later, not the raw feeds:
- gps.csv.gz: each bus report once (a new DataTime for that bus), polled every 20 s.
- eta.csv.gz: official EstimateTime every 60 s for a fixed 20% sample of stops, or with --sample route for
  every stop of a fixed 20% sample of routes, so consecutive stops can be compared (an estimate difference
  times a segment, which New Taipei relies on without official station-to-station times).
- static/: route, stop, path and shape feeds once per UTC day.
Both cities publish the same feeds from one data centre (--city tpe or ntpc). Public data only;
no credentials and no passenger information, and no TDX quota.
"""
import argparse, csv, gzip, hashlib, json, os, time, urllib.request, zlib
from datetime import datetime, timezone
from pathlib import Path

CITIES = {'tpe': 'https://tcgbusfs.blob.core.windows.net/blobbus/',
          'ntpc': 'https://tcgbusfs.blob.core.windows.net/ntpcbus/'}
BASE = CITIES['tpe']
STATIC = ['GetRoute', 'GetStop', 'GetPathDetail', 'GetBusShape']
GPS_FIELDS = ['BusID', 'CarID', 'RouteID', 'GoBack', 'Longitude', 'Latitude', 'Speed', 'Azimuth', 'DataTime', 'DutyStatus', 'BusStatus', 'ProviderID']
SAMPLE_PERCENT = 20


def fetch(name, opener=None, base=BASE):
    """Raw gzip bytes of one feed; decoding happens separately so it can be tested."""
    request = urllib.request.Request(base + name + '.gz')
    with (opener or urllib.request.urlopen)(request, timeout=30) as response:
        return response.read(64 * 1024 * 1024)


def decode(raw):
    data = gzip.decompress(raw) if raw[:2] == b'\x1f\x8b' else raw
    document = json.loads(data.decode('utf-8-sig'))
    rows = document.get('BusInfo', []) if isinstance(document, dict) else document
    update = document.get('EssentialInfo', {}).get('UpdateTime', '') if isinstance(document, dict) else ''
    return rows, update


def sampled(stop_id):
    """A stable sample: the same stops every run, so samples join across days."""
    return int(hashlib.sha1(str(stop_id).encode()).hexdigest()[:8], 16) % 100 < SAMPLE_PERCENT


def sampled_route(route_id):
    """The same, by route: all of a sampled route's stops."""
    return sampled('route:' + str(route_id))


class Recorder:
    def __init__(self, folder, sample='stop'):
        self.keep = (lambda row: sampled_route(row.get('RouteID'))) if sample == 'route' else (lambda row: sampled(row.get('StopID')))
        self.folder = Path(folder)
        self.folder.mkdir(parents=True, exist_ok=True)
        self.gps = gzip.open(self.folder / 'gps.csv.gz', 'wt', newline='', encoding='utf-8')
        self.eta = gzip.open(self.folder / 'eta.csv.gz', 'wt', newline='', encoding='utf-8')
        self.gps_writer, self.eta_writer = csv.writer(self.gps), csv.writer(self.eta)
        self.gps_writer.writerow(['received'] + GPS_FIELDS)
        self.eta_writer.writerow(['received', 'source_update', 'RouteID', 'StopID', 'GoBack', 'EstimateTime'])
        self.last_report = {}
        self.counts = {'gps_polls': 0, 'gps_rows': 0, 'eta_polls': 0, 'eta_rows': 0, 'errors': 0}

    def record_gps(self, rows, received):
        self.counts['gps_polls'] += 1
        for row in rows:
            key = (str(row.get('BusID', '')), str(row.get('CarID', '')))
            stamp = str(row.get('DataTime', ''))
            if not key[0] or not stamp or self.last_report.get(key) == stamp:
                continue
            self.last_report[key] = stamp
            self.gps_writer.writerow([received] + [row.get(field, '') for field in GPS_FIELDS])
            self.counts['gps_rows'] += 1

    def record_eta(self, rows, update, received):
        self.counts['eta_polls'] += 1
        for row in rows:
            if self.keep(row):
                self.eta_writer.writerow([received, update, row.get('RouteID', ''), row.get('StopID', ''),
                                          row.get('GoBack', ''), row.get('EstimateTime', '')])
                self.counts['eta_rows'] += 1

    def close(self):
        self.gps.close(); self.eta.close()
        (self.folder / 'counts.json').write_text(json.dumps(self.counts, indent=2) + '\n')


def save_static(folder, read=fetch):
    target = Path(folder) / 'static'
    target.mkdir(parents=True, exist_ok=True)
    for name in STATIC:
        try:
            (target / (name + '.gz')).write_bytes(read(name))
        except Exception as error:  # A missing static copy only means using another day's.
            print(f'Static {name} unavailable: {type(error).__name__}', flush=True)


def run(folder, minutes, until, read=fetch, clock=time.time, sleep=time.sleep, static=True, sample='stop'):
    stop_at = clock() + minutes * 60
    if until and clock() >= until:
        print('Benchmark period has ended; nothing recorded.', flush=True)
        return None
    if static:
        save_static(folder, read)
    recorder = Recorder(folder, sample)
    next_eta = clock()
    try:
        while clock() < stop_at and not (until and clock() >= until):
            started = clock()
            received = datetime.fromtimestamp(started, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            try:
                rows, _ = decode(read('GetBusData'))
                recorder.record_gps(rows, received)
                if started >= next_eta:
                    next_eta = started + 60
                    rows, update = decode(read('GetEstimateTime'))
                    recorder.record_eta(rows, update, received)
            except (OSError, ValueError, zlib.error, EOFError) as error:
                recorder.counts['errors'] += 1
                print(f'{received} feed error: {type(error).__name__}', flush=True)
            if recorder.counts['gps_polls'] % 180 == 1:
                print(f'{received} {json.dumps(recorder.counts)}', flush=True)
            sleep(max(0, 20 - (clock() - started)))
    finally:
        recorder.close()
    return recorder.counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--minutes', type=float, default=345)
    parser.add_argument('--until', default=os.environ.get('BENCHMARK_UNTIL', ''))
    parser.add_argument('--no-static', action='store_true')
    parser.add_argument('--city', choices=sorted(CITIES), default='tpe')
    parser.add_argument('--sample', choices=['stop', 'route'], default='stop', help='which official estimates to keep')
    args = parser.parse_args()
    until = datetime.fromisoformat(args.until).timestamp() if args.until else None
    base = CITIES[args.city]
    counts = run(args.out, args.minutes, until, read=lambda name: fetch(name, base=base), static=not args.no_static,
                 sample=args.sample)
    print('Recorded:', json.dumps(counts))


if __name__ == '__main__':
    main()
