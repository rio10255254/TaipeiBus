import importlib.util
import io
import json
import os
import tempfile
import unittest
import urllib.error
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

import official_times_gate as gate

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('collect_route_times', HERE / 'collect-route-times.py')
collect = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collect)

TAIPEI = timezone(timedelta(hours=8))
NOW = datetime(2026, 10, 13, 12, 0, tzinfo=TAIPEI)


def profile(route, updated, subroute=None, direction='0'):
    return {'route': route, 'subroute': subroute or route + '0', 'direction': direction,
            'updated': updated.isoformat(), 'edges': [['A', 'B'], ['B', 'C']],
            'periods': [{'weekday': 2, 'startHour': 8, 'endHour': 9, 'seconds': [60, 75]}]}


def catalog(profiles, generated):
    return {'schema': 1, 'generatedAt': generated.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'source': 'test', 'routes': profiles}


class ProfileRuleTests(unittest.TestCase):
    def test_app_rules_reject_unusable_profiles(self):
        good = profile('1', NOW)
        self.assertEqual(gate.profile_updated(good), NOW)
        for change in ({'direction': '3'}, {'edges': []}, {'edges': [['A', 'A']]}, {'edges': [['A', 'B'], ['A', 'B']]},
                       {'periods': [{'weekday': 7, 'startHour': 8, 'endHour': 9, 'seconds': [60, 75]}]},
                       {'periods': [{'weekday': 2, 'startHour': 9, 'endHour': 9, 'seconds': [60, 75]}]},
                       {'periods': [{'weekday': 2, 'startHour': 8, 'endHour': 9, 'seconds': [60]}]},
                       {'updated': '2026-10-13'}, {'updated': '2026-10-13T12:00:00'}):
            with self.subTest(change=change):
                self.assertIsNone(gate.profile_updated(dict(good, **change)))

    def test_holiday_profile_and_fractional_time_are_accepted(self):
        value = profile('1', NOW)
        value['periods'][0]['weekday'] = 99
        value['updated'] = '2026-10-13T04:00:00.250Z'
        self.assertIsNotNone(gate.profile_updated(value))

    def test_profiles_expire_after_45_days_like_the_app(self):
        self.assertTrue(gate.is_fresh(NOW - timedelta(days=45), NOW))
        self.assertFalse(gate.is_fresh(NOW - timedelta(days=45, seconds=1), NOW))
        self.assertFalse(gate.is_fresh(NOW + timedelta(minutes=6), NOW))

    def test_type_error_rejects_the_whole_catalog(self):
        broken = profile('2', NOW)
        broken['periods'][0]['seconds'] = [60, '75']
        failures = gate.structural_failures(catalog([profile('1', NOW), broken], NOW), 1000)
        self.assertTrue(any('whole catalog' in f for f in failures))

    def test_horizon_is_when_ten_percent_have_expired(self):
        profiles = [profile(str(i), NOW - timedelta(days=i)) for i in range(10)]
        stats = gate.summarize(catalog(profiles, NOW), NOW)
        self.assertEqual(stats['usable_profiles'], 10)
        # One expired profile is exactly 10%; the horizon is when a second one expires.
        self.assertEqual(stats['horizon'], (NOW - timedelta(days=8) + timedelta(days=45)).isoformat())
        self.assertEqual(stats['horizon_days'], 37.0)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.old = catalog([profile(str(i), NOW - timedelta(days=20)) for i in range(40)], NOW - timedelta(days=7))

    def fresh(self, count=40, generated=NOW):
        return catalog([profile(str(i), NOW - timedelta(days=1)) for i in range(count)], generated)

    def test_fresher_complete_catalog_passes(self):
        failures, report = gate.gate(self.fresh(), self.old, NOW)
        self.assertEqual(failures, [])
        self.assertGreater(report['collected']['horizon_days'], report['published']['horizon_days'])

    def test_partial_route_list_cannot_replace_full_catalog(self):
        failures, _ = gate.gate(self.fresh(count=3), self.old, NOW)
        self.assertTrue(any('usable profiles' in f for f in failures))
        failures, _ = gate.gate(self.fresh(count=3), self.old, NOW, allow_smaller=True)
        self.assertEqual(failures, [])

    def test_catalog_that_phones_would_ignore_is_refused(self):
        failures, _ = gate.gate(self.fresh(generated=NOW - timedelta(days=8)), self.old, NOW)
        self.assertTrue(any('not newer' in f for f in failures))

    def test_older_update_times_are_refused(self):
        stale = catalog([profile(str(i), NOW - timedelta(days=30)) for i in range(40)], NOW)
        failures, _ = gate.gate(stale, self.old, NOW)
        self.assertTrue(any('expire sooner' in f for f in failures))

    def test_oversized_catalog_is_refused(self):
        with mock.patch.object(gate, 'MAX_BYTES', 100):
            failures, _ = gate.gate(self.fresh(), self.old, NOW)
        self.assertTrue(any('phones reject more than 100' in f for f in failures))

    def test_unrefreshed_routes_keep_still_valid_profiles(self):
        published = catalog([profile('1', NOW - timedelta(days=10)), profile('2', NOW - timedelta(days=10)),
                             profile('2', NOW - timedelta(days=10), direction='1'), profile('3', NOW - timedelta(days=50))],
                            NOW - timedelta(days=7))
        collected = catalog([profile('1', NOW)], NOW)
        merged, carried = gate.carry_forward(collected, published, NOW)
        self.assertEqual(carried, ['2'])  # 1 was refreshed; 3 has already expired.
        self.assertEqual([(r['route'], r['direction'], r['updated']) for r in merged['routes']],
                         [('1', '0', NOW.isoformat()), ('2', '0', (NOW - timedelta(days=10)).isoformat()),
                          ('2', '1', (NOW - timedelta(days=10)).isoformat())])
        self.assertEqual(merged['generatedAt'], collected['generatedAt'])

    def test_stale_answer_does_not_replace_a_valid_profile(self):
        published = catalog([profile('1', NOW - timedelta(days=10))], NOW - timedelta(days=7))
        collected = catalog([profile('1', NOW - timedelta(days=60))], NOW)
        merged, carried = gate.carry_forward(collected, published, NOW)
        self.assertEqual(carried, ['1'])
        self.assertEqual([r['updated'] for r in merged['routes']], [(NOW - timedelta(days=10)).isoformat()])

    def test_expired_routes_do_not_block_the_rest(self):
        published = catalog([profile(str(i), NOW - timedelta(days=50 if i < 10 else 20)) for i in range(40)], NOW - timedelta(days=7))
        collected, _ = gate.carry_forward(catalog([profile(str(i), NOW) for i in range(10, 30)], NOW), published, NOW)
        failures, report = gate.gate(collected, published, NOW)
        self.assertEqual(failures, [])
        self.assertEqual(report['collected']['usable_profiles'], 30)

    def test_partial_refresh_keeps_the_rest_of_the_catalog(self):
        collected, carried = gate.carry_forward(self.fresh(count=3), self.old, NOW)
        self.assertEqual(len(carried), 37)
        failures, report = gate.gate(collected, self.old, NOW)
        self.assertEqual(failures, [])
        self.assertEqual(report['collected']['usable_profiles'], 40)


class CommandTests(unittest.TestCase):
    def run_prepare(self, collected, published, coverage, *flags):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, value in (('collected.json', collected), ('published.json', published), ('coverage.json', coverage)):
                (root / name).write_text(json.dumps(value, ensure_ascii=False))
            args = ['prepare', '--candidate', str(root / 'collected.json'), '--published', str(root / 'published.json'),
                    '--coverage', str(root / 'coverage.json'), '--out', str(root / 'out'), *flags]
            with mock.patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(root / 'summary.md')}), redirect_stdout(io.StringIO()):
                try:
                    gate.main(args, now=NOW)
                    error = None
                except SystemExit as stop:
                    error = stop
            out = root / 'out'
            written = json.loads((out / 'official-times.json').read_text()) if (out / 'official-times.json').exists() else None
            report = json.loads((out / 'coverage.json').read_text()) if (out / 'coverage.json').exists() else None
            return error, written, report, (root / 'summary.md').read_text()

    def test_prepare_writes_merged_catalog_and_report(self):
        published = catalog([profile(str(i), NOW - timedelta(days=20)) for i in range(20)], NOW - timedelta(days=7))
        collected = catalog([profile(str(i), NOW - timedelta(days=1)) for i in range(19)], NOW)
        error, written, report, summary = self.run_prepare(
            collected, published, {'requested_routes': [str(i) for i in range(20)], 'failed_routes': ['19'], 'missing_routes': []})
        self.assertIsNone(error)
        self.assertEqual(len(written['routes']), 20)
        self.assertEqual(report['carried_forward_routes'], ['19'])
        self.assertEqual(report['publication']['failures'], [])
        self.assertIn('Publication checks passed', summary)

    def test_prepare_refuses_or_only_reports(self):
        published = catalog([profile(str(i), NOW - timedelta(days=20)) for i in range(20)], NOW - timedelta(days=7))
        collected = catalog([profile(str(i), NOW - timedelta(days=30)) for i in range(20)], NOW)
        coverage = {'requested_routes': [str(i) for i in range(20)], 'failed_routes': [], 'missing_routes': []}
        error, _, report, summary = self.run_prepare(collected, published, coverage)
        self.assertIsNotNone(error)
        self.assertIn('Blocked', summary)
        self.assertTrue(report['publication']['failures'])
        error, _, _, _ = self.run_prepare(collected, published, coverage, '--report-only')
        self.assertIsNone(error)

    def test_check_fails_before_phones_lose_profiles(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'official-times.json'
            path.write_text(json.dumps(catalog([profile(str(i), NOW - timedelta(days=30)) for i in range(10)], NOW)))
            with redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit):
                    gate.main(['check', '--document', str(path), '--minimum-days', '21'], now=NOW)
                gate.main(['check', '--document', str(path), '--minimum-days', '14'], now=NOW)


class CollectorRetryTests(unittest.TestCase):
    def http_error(self, code):
        return urllib.error.HTTPError('https://example.invalid', code, 'error', {}, None)

    def test_temporary_failures_are_retried_with_pauses(self):
        pauses = []
        answers = [urllib.error.URLError('reset'), self.http_error(503), b'ok']

        def read(*_):
            answer = answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return answer

        with mock.patch.object(collect, 'read', read), redirect_stdout(io.StringIO()):
            self.assertEqual(collect.read_with_retry('url', pause=pauses.append), b'ok')
        self.assertEqual(pauses, [15, 30])

    def test_permanent_refusals_are_not_retried(self):
        pauses = []
        with mock.patch.object(collect, 'read', side_effect=self.http_error(401)):
            with self.assertRaises(urllib.error.HTTPError):
                collect.read_with_retry('url', pause=pauses.append)
        self.assertEqual(pauses, [])

    def test_retries_end_with_the_last_error(self):
        pauses = []
        with mock.patch.object(collect, 'read', side_effect=TimeoutError()), redirect_stdout(io.StringIO()):
            with self.assertRaises(TimeoutError):
                collect.read_with_retry('url', pause=pauses.append)
        self.assertEqual(pauses, [15, 30, 60])


class CollectorRunTests(unittest.TestCase):
    """The whole collection with a fake TDX: no network, no credentials, no sleeping."""

    def run_collection(self, behaviour, routes):
        def read(url, headers=None, data=None, accounting=None):
            if url.endswith('GetRoute.gz'):
                return json.dumps({'BusInfo': [{'Id': int(r)} for r in routes]}).encode()
            if 'openid-connect/token' in url:
                return b'{"access_token": "token"}'
            if accounting is not None:
                accounting['requests'] += 1
            route = url.split('/City/Taipei/')[1].split('?')[0]
            answer = behaviour(route)
            if isinstance(answer, Exception):
                raise answer
            return json.dumps([{'RouteID': route, 'SubRouteID': route + '0', 'Direction': 0, 'UpdateTime': '2026-10-12T02:00:00+08:00',
                                'TravelTimes': [{'Weekday': 2, 'StartHour': 8, 'EndHour': 9, 'S2STimes': [
                                    {'FromStopID': 'A', 'ToStopID': 'B', 'RunTime': 60}]}]}]).encode()

        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder) / 'official-times.json'
            argv = ['collect-route-times.py', '--out', str(out)]
            environment = {'TDX_CLIENT_ID': 'id', 'TDX_CLIENT_SECRET': 'secret'}
            with mock.patch.object(collect, 'read', read), mock.patch.object(collect.time, 'sleep'), \
                    mock.patch('sys.argv', argv), mock.patch.dict(os.environ, environment), redirect_stdout(io.StringIO()):
                collect.main()
            return json.loads(out.read_text()), json.loads(out.with_name('coverage.json').read_text())

    def test_unanswered_routes_are_reported_and_collection_continues(self):
        def behaviour(route):
            return {'2': urllib.error.URLError('reset'), '3': urllib.error.HTTPError('u', 404, 'missing', {}, None)}.get(route)

        result, coverage = self.run_collection(behaviour, ['1', '2', '3', '4'])
        self.assertEqual([r['route'] for r in result['routes']], ['1', '4'])
        self.assertEqual(coverage['failed_routes'], ['2'])
        self.assertEqual(coverage['missing_routes'], ['3'])

    def test_quota_refusal_stops_without_writing(self):
        def behaviour(route):
            return urllib.error.HTTPError('u', 429, 'quota', {}, None) if route == '2' else None

        with self.assertRaisesRegex(ValueError, 'HTTP 429'):
            self.run_collection(behaviour, ['1', '2', '3'])

    def test_outage_stops_after_consecutive_failures(self):
        with self.assertRaisesRegex(ValueError, '8 consecutive routes'):
            self.run_collection(lambda route: urllib.error.URLError('down'), [str(i) for i in range(1, 12)])


if __name__ == '__main__':
    unittest.main()
