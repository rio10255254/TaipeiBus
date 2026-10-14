"""Decide whether a collected official travel-time catalog may replace the one phones download.

Phones keep a station-to-station profile only while TDX's UpdateTime is at most
45 days old (OfficialTravelTimes.swift). This gate mirrors the app's parsing rules,
carries forward still-valid profiles for routes this run did not refresh, and
refuses anything that would leave phones with fewer or older usable profiles.
"""
import argparse, json, math, os, re
from datetime import datetime, timedelta, timezone
from pathlib import Path

MAX_BYTES = 32 * 1024 * 1024
MAX_ROUTES = 10_000
VALID_DAYS = 45
FUTURE_TOLERANCE = timedelta(seconds=300)
# The horizon is the moment more than this share of usable profiles has expired.
EXPIRED_SHARE = 0.10
MINIMUM_COVERAGE = 0.95
TIMESTAMP = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})')


def timestamp(text):
    if not isinstance(text, str) or not TIMESTAMP.fullmatch(text):
        return None
    try:
        value = datetime.fromisoformat(text.replace('Z', '+00:00'))
    except ValueError:
        return None
    return value if value.tzinfo else None


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def decodable(route):
    """Whether Swift's Codable route type accepts this value; one failure rejects the whole catalog."""
    return (isinstance(route, dict) and all(isinstance(route.get(key), str) for key in ('route', 'subroute', 'direction', 'updated'))
            and isinstance(route.get('edges'), list)
            and all(isinstance(edge, list) and all(isinstance(stop, str) for stop in edge) for edge in route['edges'])
            and isinstance(route.get('periods'), list)
            and all(isinstance(period, dict) and all(is_int(period.get(key)) for key in ('weekday', 'startHour', 'endHour'))
                    and isinstance(period.get('seconds'), list) and all(is_int(value) for value in period['seconds'])
                    for period in route['periods']))


def profile_updated(route):
    """UpdateTime of a profile the app would load, else None (same rules as OfficialTravelTimes.init)."""
    if not decodable(route) or not (route['route'] and route['subroute']) or route['direction'] not in ('0', '1', '2'):
        return None
    edges, periods = route['edges'], route['periods']
    if not 1 <= len(edges) <= 400 or len(periods) > 200:
        return None
    if not all(len(edge) == 2 and edge[0] and edge[1] and edge[0] != edge[1] for edge in edges):
        return None
    if len({tuple(edge) for edge in edges}) != len(edges):
        return None
    if not all(0 <= period['weekday'] <= 6 or period['weekday'] == 99 for period in periods):
        return None
    if not any(0 <= p['startHour'] <= 23 and 1 <= p['endHour'] <= 24 and p['endHour'] > p['startHour']
               and len(p['seconds']) == len(edges) for p in periods):
        return None
    return timestamp(route['updated'])


def is_fresh(updated, now):
    return updated is not None and -FUTURE_TOLERANCE <= now - updated <= timedelta(days=VALID_DAYS)


def summarize(document, now):
    """Counts and expiry horizon of the profiles a phone would use at `now`."""
    routes = document.get('routes') if isinstance(document, dict) else None
    if not isinstance(routes, list):
        routes = []
    updates = [u for u in (profile_updated(r) for r in routes) if u is not None]
    fresh = [u for u in updates if is_fresh(u, now)]
    expiries = sorted(u + timedelta(days=VALID_DAYS) for u in updates)
    horizon = expiries[math.floor(EXPIRED_SHARE * len(expiries))] if expiries else None
    return {
        'profiles': len(routes),
        'valid_profiles': len(updates),
        'usable_profiles': len(fresh),
        'oldest_update': min(updates).isoformat() if updates else None,
        'newest_update': max(updates).isoformat() if updates else None,
        'horizon': horizon.isoformat() if horizon else None,
        'horizon_days': round((horizon - now).total_seconds() / 86400, 1) if horizon else None,
    }


def structural_failures(document, size):
    failures = []
    if not isinstance(document, dict) or not is_int(document.get('schema')) or document['schema'] != 1 \
            or not isinstance(document.get('routes'), list):
        return ['The catalog is not schema 1 with a route list.']
    undecodable = sum(1 for route in document['routes'] if not decodable(route))
    if undecodable:
        failures.append(f'{undecodable} profiles have fields of the wrong type; phones would reject the whole catalog.')
    if size > MAX_BYTES:
        failures.append(f'The catalog is {size} bytes; phones reject more than {MAX_BYTES}.')
    if len(document['routes']) > MAX_ROUTES:
        failures.append(f'The catalog has {len(document["routes"])} profiles; phones reject more than {MAX_ROUTES}.')
    if timestamp(document.get('generatedAt')) is None:
        failures.append('The catalog has no valid generatedAt; phones cannot tell it is newer.')
    return failures


def carry_forward(candidate, published, now):
    """Keep previous still-valid profiles of routes this run did not refresh with usable ones.

    That covers unanswered, unrequested and stale TDX answers. Withdrawn routes drop out by
    themselves once their 45 days pass; the app never matches them.
    """
    refreshed = {r['route'] for r in candidate['routes'] if is_fresh(profile_updated(r), now)}
    kept = [r for r in published.get('routes', []) if isinstance(r, dict) and r.get('route') not in refreshed
            and is_fresh(profile_updated(r), now)]
    carried = sorted({r['route'] for r in kept}, key=lambda x: (len(x), x))
    replaced = set(carried)
    routes = [r for r in candidate['routes'] if not (isinstance(r, dict) and r.get('route') in replaced)] + kept
    return dict(candidate, routes=routes), carried


def encode(document):
    return json.dumps(document, ensure_ascii=False, separators=(',', ':')).encode()


def gate(candidate, published, now, allow_smaller=False):
    """Failures that must stop publication, plus the comparison shown in the run summary."""
    blob = encode(candidate)
    failures = structural_failures(candidate, len(blob))
    new, old = summarize(candidate, now), summarize(published, now)
    new_generated, old_generated = timestamp(candidate.get('generatedAt')), timestamp(published.get('generatedAt'))
    if new_generated and old_generated and new_generated <= old_generated:
        failures.append('The collected catalog is not newer than the published one; phones would ignore it.')
    if new['usable_profiles'] == 0:
        failures.append('No collected profile is usable by the app.')
    required = math.ceil(MINIMUM_COVERAGE * old['usable_profiles'])
    if not allow_smaller and new['usable_profiles'] < required:
        failures.append(f'Only {new["usable_profiles"]} usable profiles; the published catalog has {old["usable_profiles"]} '
                        f'(at least {required} required unless allow_smaller is set).')
    if old['horizon_days'] is not None and (new['horizon_days'] is None or new['horizon_days'] < old['horizon_days']):
        failures.append(f'Collected profiles expire sooner ({new["horizon"]}) than the published ones ({old["horizon"]}).')
    return failures, {'collected': new, 'published': old, 'bytes': len(blob)}


def write_summary(lines):
    text = '\n'.join(lines) + '\n'
    print(text, end='')
    path = os.environ.get('GITHUB_STEP_SUMMARY')
    if path:
        with open(path, 'a', encoding='utf-8') as handle:
            handle.write(text)


def describe(name, stats):
    return (f'| {name} | {stats["valid_profiles"]} | {stats["usable_profiles"]} | {stats["oldest_update"]} | '
            f'{stats["horizon"]} | {stats["horizon_days"]} |')


def prepare(args, now):
    candidate = json.loads(args.candidate.read_text(encoding='utf-8'))
    published = json.loads(args.published.read_text(encoding='utf-8'))
    coverage = json.loads(args.coverage.read_text(encoding='utf-8'))
    if not isinstance(candidate, dict) or not isinstance(candidate.get('routes'), list):
        raise ValueError('The collected catalog is not a route list')
    merged, carried = carry_forward(candidate, published if isinstance(published, dict) else {}, now)
    failures, report = gate(merged, published if isinstance(published, dict) else {}, now, args.allow_smaller)
    coverage['carried_forward_routes'] = carried
    coverage['publication'] = {'checked_at': now.isoformat(), 'failures': failures, **report}
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / 'official-times.json').write_bytes(encode(merged))
    (args.out / 'coverage.json').write_text(json.dumps(coverage, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    write_summary(['### Official travel-time catalog', '',
                   '| Catalog | Valid profiles | Usable now | Oldest UpdateTime | 10% expired at | Days left |',
                   '|---|---|---|---|---|---|', describe('Published', report['published']), describe('Collected', report['collected']), '',
                   f'Routes failed or without data this run: {len(coverage.get("failed_routes", []))} failed, '
                   f'{len(coverage.get("missing_routes", []))} without source data; carried forward: {len(carried)}.', ''] +
                  ([f'- Blocked: {f}' for f in failures] or ['Publication checks passed.']))
    if failures and not args.report_only:
        raise SystemExit('Publication refused; the published catalog stays unchanged.')


def check(args, now):
    data = args.document.read_bytes()
    document = json.loads(data)
    failures = structural_failures(document, len(data))
    stats = summarize(document, now)
    if stats['horizon_days'] is None or stats['horizon_days'] < args.minimum_days:
        failures.append(f'More than {EXPIRED_SHARE:.0%} of profiles expire by {stats["horizon"]}, '
                        f'within {args.minimum_days} days; the weekly refresh is not reaching phones.')
    write_summary(['### Catalog phones download', '',
                   '| Catalog | Valid profiles | Usable now | Oldest UpdateTime | 10% expired at | Days left |',
                   '|---|---|---|---|---|---|', describe('Published', stats), ''] +
                  ([f'- Problem: {f}' for f in failures] or ['The published catalog is healthy.']))
    if failures:
        raise SystemExit('The published official travel-time catalog needs attention.')


def main(argv=None, now=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('prepare', help='Carry forward unanswered routes and gate publication')
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--coverage', type=Path, required=True)
    p.add_argument('--published', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--allow-smaller', action='store_true', help='Accept fewer usable profiles, e.g. after routes are withdrawn')
    p.add_argument('--report-only', action='store_true', help='Report gate failures without failing (dry runs)')
    c = commands.add_parser('check', help='Fail when the catalog phones download is close to expiring')
    c.add_argument('--document', type=Path, required=True)
    c.add_argument('--minimum-days', type=float, default=21)
    args = parser.parse_args(argv)
    now = now or datetime.now(timezone.utc)
    (prepare if args.command == 'prepare' else check)(args, now)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(f'Official travel-time gate stopped: {error}')
