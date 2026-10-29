"""The static bus files a source publishes (routes, stops, stop order, providers, shapes), bundled so the
app can plan before its first download. The files are kept exactly as published, gzip and all, and the
provenance records each one's hash, rows and source time for release-check.py. No credentials.

  python3 ios/release/collect-bus-static.py --source ntpc --out ios/TaipeiBus/BusMetadata/ntpc \
      --provenance ios/release/bus-static-ntpc-provenance.json
"""
import argparse, datetime, gzip, hashlib, json, urllib.request
from pathlib import Path

import service_area

NAMES = ['GetRoute', 'GetStop', 'GetPathDetail', 'GetProvider', 'GetBusShape']
LIMIT = 32 * 1024 * 1024

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True, help='a bus source id in Regions/regions.json')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--provenance', type=Path, required=True)
    args = parser.parse_args()
    source = service_area.source(args.source)
    if source['kind'] != 'bus': raise ValueError('Not a bus source')
    feeds = []
    for name in NAMES:
        with urllib.request.urlopen(source['feed'] + name + '.gz', timeout=120) as response:
            raw = response.read(LIMIT + 1)
        if len(raw) > LIMIT: raise ValueError(name + ' size limit')
        decoded = gzip.decompress(raw)
        document = json.loads(decoded.decode('utf-8-sig'))
        rows = document if isinstance(document, list) else document.get('BusInfo', [])
        if not rows: raise ValueError(name + ' is empty')
        essential = document.get('EssentialInfo', {}) if isinstance(document, dict) else {}
        feeds.append({'name': name, 'bytes': len(raw), 'decodedBytes': len(decoded), 'rows': len(rows),
                      'sha256': hashlib.sha256(raw).hexdigest(), 'sourceTime': essential.get('UpdateTime', '')})
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / (name + '.gz')).write_bytes(raw)
        print(name, len(raw), 'bytes', len(rows), 'rows', flush=True)
    provenance = {'collectedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'source': source['feed'], 'feeds': feeds}
    args.provenance.write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

if __name__ == '__main__': main()
