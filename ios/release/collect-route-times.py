"""Collect shared official profiles within a fixed free-tier budget. Never prints credentials."""
import argparse, gzip, json, os, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

BASE = 'https://tdx.transportdata.tw'

def read(url, headers=None, data=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    with urllib.request.urlopen(req, timeout=45) as response:
        raw = response.read(16 * 1024 * 1024 + 1)
        if len(raw) > 16 * 1024 * 1024:
            raise ValueError('Response exceeds the per-request budget')
        if response.headers.get('Content-Encoding') == 'gzip' or raw[:2] == b'\x1f\x8b':
            raw = gzip.decompress(raw)
        if len(raw) > 32 * 1024 * 1024:
            raise ValueError('Decoded response exceeds the per-request budget')
        return raw

def compact(row):
    periods = row.get('TravelTimes', [])
    if not periods:
        return None
    edges = []
    for period in periods:
        for edge in period.get('S2STimes', []):
            pair = [str(edge.get('FromStopID', '')), str(edge.get('ToStopID', ''))]
            if pair not in edges and all(pair) and pair[0] != pair[1]:
                edges.append(pair)
    if not edges or len(edges) > 400:
        return None
    result = []
    for period in periods:
        records = {(str(x.get('FromStopID')), str(x.get('ToStopID'))): int(x.get('RunTime', -1)) for x in period.get('S2STimes', [])}
        result.append({'weekday': int(period['Weekday']), 'startHour': int(period['StartHour']), 'endHour': int(period['EndHour']),
                       'seconds': [records.get(tuple(edge), -1) for edge in edges]})
    return {'route': str(row['RouteID']), 'subroute': str(row['SubRouteID']), 'direction': str(row['Direction']),
            'updated': row['UpdateTime'], 'edges': edges, 'periods': result}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--routes', default='')
    parser.add_argument('--maximum-routes', type=int, default=450)
    parser.add_argument('--maximum-decoded-mb', type=int, default=300)
    args = parser.parse_args()
    if not (1 <= args.maximum_routes <= 450 and 1 <= args.maximum_decoded_mb <= 300):
        raise ValueError('Request and byte budgets cannot exceed the fixed limit')
    client_id, client_secret = os.environ.get('TDX_CLIENT_ID', '').strip(), os.environ.get('TDX_CLIENT_SECRET', '').strip()
    if not client_id or not client_secret:
        raise ValueError('Existing TDX credentials are required in encrypted GitHub Secrets; no subscription is created')
    raw = read('https://tcgbusfs.blob.core.windows.net/blobbus/GetRoute.gz')
    published = sorted({str(x['Id']) for x in json.loads(raw)['BusInfo']}, key=int)
    requested = [x.strip() for x in args.routes.split(',') if x.strip()] or published
    if any(x not in published for x in requested) or len(requested) > args.maximum_routes:
        raise ValueError('Requested routes do not fit the published catalog or request budget')
    token, token_at = None, 0
    profiles, missing, failure = [], [], []
    used = 0
    for index, route in enumerate(requested):
        if index:
            time.sleep(12.2)  # Basic member: at most five requests per minute.
        if token is None or time.monotonic() - token_at >= 600:
            payload = urllib.parse.urlencode({'grant_type': 'client_credentials', 'client_id': client_id, 'client_secret': client_secret}).encode()
            answer = json.loads(read(BASE + '/auth/realms/TDXConnect/protocol/openid-connect/token',
                                     {'Content-Type': 'application/x-www-form-urlencoded'}, payload))
            token, token_at = answer['access_token'], time.monotonic()
        url = BASE + '/api/basic/v2/Bus/S2STravelTime/City/Taipei/' + urllib.parse.quote(route) + '?$format=JSON'
        try:
            raw = read(url, {'Authorization': 'Bearer ' + token, 'Accept-Encoding': 'gzip'})
        except urllib.error.HTTPError as error:
            if error.code == 404:
                missing.append(route)
                print(f'Official profiles {index + 1}/{len(requested)}; route {route}; source unavailable', flush=True)
                continue
            raise
        used += len(raw)
        if used > args.maximum_decoded_mb * 1024 * 1024:
            raise ValueError('Fixed transfer budget exhausted; no overage or subscription is requested')
        rows = json.loads(raw)
        decoded = [x for row in rows if str(row.get('RouteID')) == route for x in [compact(row)] if x]
        if decoded:
            profiles.extend(decoded)
        else:
            missing.append(route)
        print(f'Official profiles {index + 1}/{len(requested)}; route {route}; patterns {len(decoded)}', flush=True)
    result = {'schema': 1, 'generatedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'source': BASE + '/api/basic/v2/Bus/S2STravelTime/City/Taipei/{RouteID}', 'routes': profiles}
    blob = json.dumps(result, ensure_ascii=False, separators=(',', ':')).encode()
    if not profiles or len(blob) > 32 * 1024 * 1024:
        raise ValueError('Empty or oversized catalog; existing public data must remain unchanged')
    args.out.parent.mkdir(parents=True, exist_ok=True);args.out.write_bytes(blob)
    report = {'requested_routes': requested, 'loaded_patterns': len(profiles), 'missing_routes': missing,
              'decoded_bytes': used, 'output_bytes': len(blob), 'request_budget': args.maximum_routes,
              'source': result['source'], 'generated_at': result['generatedAt']}
    args.out.with_name('coverage.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Official catalog saved: {len(profiles)} patterns, {len(missing)} source gaps. No credentials in output.')

if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Token-server bodies and request details can contain account data.
        message = str(error) if isinstance(error, ValueError) else type(error).__name__
        raise SystemExit('Official profile collection stopped: ' + message)
