import csv
import gzip
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import collect


def feed(rows, update='2026/10/14 21:15:30'):
    return gzip.compress(json.dumps({'EssentialInfo': {'UpdateTime': update}, 'BusInfo': rows}).encode('utf-8-sig'))


def bus(plate, stamp, route='307'):
    return {'BusID': plate, 'CarID': 1, 'RouteID': route, 'GoBack': '0', 'Longitude': '121.5', 'Latitude': '25.0',
            'Speed': '20', 'Azimuth': '90', 'DataTime': stamp, 'DutyStatus': '0', 'BusStatus': '0', 'ProviderID': 1}


class CollectTests(unittest.TestCase):
    def run_fake(self, polls, until=None, minutes=2):
        now = [1_800_000_000.0]
        gps = iter(polls)

        def read(name):
            if name == 'GetBusData':
                answer = next(gps)
                if isinstance(answer, Exception):
                    raise answer
                return feed(answer)
            if name == 'GetEstimateTime':
                return feed([{'RouteID': 1, 'StopID': stop, 'GoBack': '0', 'EstimateTime': '120'} for stop in range(1000)])
            return b'static'

        def sleep(seconds):
            now[0] += seconds

        folder = tempfile.mkdtemp()
        with redirect_stdout(io.StringIO()):
            counts = collect.run(folder, minutes, until, read=read, clock=lambda: now[0], sleep=sleep)
        return Path(folder), counts

    def rows(self, path):
        with gzip.open(path, 'rt', newline='') as handle:
            return list(csv.reader(handle))[1:]

    def test_each_report_is_stored_once_and_eta_once_a_minute(self):
        polls = [[bus('A', 't1'), bus('B', 't1')], [bus('A', 't1'), bus('B', 't2')], [bus('A', 't3')],
                 [bus('A', 't3')], [bus('A', 't3')], [bus('A', 't3')]]
        folder, counts = self.run_fake(polls)
        self.assertEqual([(r[1], r[9]) for r in self.rows(folder / 'gps.csv.gz')], [('A', 't1'), ('B', 't1'), ('B', 't2'), ('A', 't3')])
        self.assertEqual(counts['gps_polls'], 6)
        self.assertEqual(counts['eta_polls'], 2)  # Polls at 0 s and 60 s of a two-minute run.
        sample = {r[3] for r in self.rows(folder / 'eta.csv.gz')}
        self.assertTrue(150 < len(sample) < 250)  # About 20% of 1,000 stops, the same each minute.
        self.assertEqual(counts['eta_rows'], 2 * len(sample))
        self.assertEqual(sorted(p.name for p in (folder / 'static').iterdir()), sorted(n + '.gz' for n in collect.STATIC))
        self.assertEqual(json.loads((folder / 'counts.json').read_text()), counts)

    def test_feed_errors_are_counted_and_collection_continues(self):
        polls = [OSError('reset'), [bus('A', 't1')], ValueError('bad json')] + [[bus('A', 't1')]] * 3
        folder, counts = self.run_fake(polls)
        self.assertEqual(counts['errors'], 2)
        self.assertEqual(len(self.rows(folder / 'gps.csv.gz')), 1)

    def test_sample_is_stable_across_runs(self):
        self.assertEqual([collect.sampled(s) for s in range(50)], [collect.sampled(str(s)) for s in range(50)])

    def test_nothing_is_recorded_after_the_benchmark_period(self):
        folder, counts = self.run_fake([], until=1_799_999_999)
        self.assertIsNone(counts)
        self.assertFalse((folder / 'gps.csv.gz').exists())

    def test_each_city_reads_its_own_feeds(self):
        asked = []

        class Response:
            def __init__(self, request): asked.append(request.full_url)
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def read(self, _): return b''

        collect.fetch('GetBusData', opener=lambda request, timeout: Response(request))
        collect.fetch('GetBusData', opener=lambda request, timeout: Response(request), base=collect.CITIES['ntpc'])
        self.assertEqual(asked, ['https://tcgbusfs.blob.core.windows.net/blobbus/GetBusData.gz',
                                 'https://tcgbusfs.blob.core.windows.net/ntpcbus/GetBusData.gz'])


if __name__ == '__main__':
    unittest.main()
