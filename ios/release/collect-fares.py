"""Official fare tables from TDX: metro station-to-station fares and city bus route fares.
Credentials never enter output. Writes the raw snapshot and a short summary of its shape."""
import argparse, datetime, gzip, json, os, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

BASE = 'https://tdx.transportdata.tw'
SOURCES = [('metro', 'TRTC', '/api/basic/v2/Rail/Metro/ODFare/TRTC'),
           ('metro', 'NTMC', '/api/basic/v2/Rail/Metro/ODFare/NTMC'),
           ('bus', 'Taipei', '/api/basic/v2/Bus/RouteFare/City/Taipei'),
           ('bus', 'NewTaipei', '/api/basic/v2/Bus/RouteFare/City/NewTaipei')]
LIMIT = 60 * 1024 * 1024

def read(url, headers=None, data=None):
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers or {}), timeout=90) as response:
        raw = response.read(LIMIT + 1)
        if len(raw) > LIMIT: raise ValueError('Fare snapshot size limit')
        if response.headers.get('Content-Encoding') == 'gzip' or raw[:2] == b'\x1f\x8b': raw = gzip.decompress(raw)
        return raw

def shape(value, depth=0):
    """Keys and one example, nested, so the format can be read without the whole table."""
    if isinstance(value, list): return [len(value), shape(value[0], depth + 1) if value else None]
    if isinstance(value, dict) and depth < 6: return {k: shape(v, depth + 1) for k, v in value.items()}
    return value

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    cid, secret = os.environ['TDX_CLIENT_ID'], os.environ['TDX_CLIENT_SECRET']
    payload = urllib.parse.urlencode({'grant_type': 'client_credentials', 'client_id': cid, 'client_secret': secret}).encode()
    answer = json.loads(read(BASE + '/auth/realms/TDXConnect/protocol/openid-connect/token', {'Content-Type': 'application/x-www-form-urlencoded'}, payload))
    headers = {'Authorization': 'Bearer ' + answer['access_token'], 'Accept-Encoding': 'gzip'}; del cid, secret, answer, payload
    snapshot = {'schema': 1, 'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'source': 'MOTC TDX official fares', 'license': 'Open Government Data License 1.0', 'tables': {}, 'missing': []}
    summary = {}
    for index, (kind, operator, path) in enumerate(SOURCES):
        if index: time.sleep(12.2)
        try:
            rows = json.loads(read(BASE + path + '?$format=JSON', headers))
            snapshot['tables'][kind + ':' + operator] = rows
            summary[kind + ':' + operator] = shape(rows)
            print(kind, operator, len(rows) if isinstance(rows, list) else type(rows).__name__, flush=True)
        except urllib.error.HTTPError as error:
            snapshot['missing'].append({'table': kind + ':' + operator, 'http': error.code})
            print(kind, operator, 'unavailable', error.code, flush=True)
    with gzip.open(args.out / 'fares-raw.json.gz', 'wt', encoding='utf-8') as file:
        json.dump(snapshot, file, ensure_ascii=False, separators=(',', ':'))
    (args.out / 'fares-shape.json').write_text(json.dumps(summary, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
    if not any(key.startswith('metro:') for key in snapshot['tables']): raise ValueError('No metro fares collected')
    print('Saved official fares; no credentials in output.', flush=True)

if __name__ == '__main__': main()
