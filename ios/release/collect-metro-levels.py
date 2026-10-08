"""Collect OpenStreetMap track structure (tunnel / bridge / layer) for Taipei metro lines.

TDX publishes official track geometry but not whether a section runs underground or on a
viaduct. OpenStreetMap contributors map that with tunnel/bridge/layer tags (ODbL). This script
only downloads the public tags and geometry; normalize-metro-levels.py turns them into the
app's height profiles. No credentials are needed or used.
"""
import argparse, json, pathlib, time, urllib.parse, urllib.request, datetime

ENDPOINTS = [
    'https://overpass-api.de/api/interpreter',
    'https://lz4.overpass-api.de/api/interpreter',
    'https://z.overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
]
BBOX = '24.92,121.31,25.19,121.64'
QUERIES = {
    'tracks': f'[out:json][timeout:150];way["railway"~"^(subway|light_rail|monorail)$"]({BBOX});out tags geom;',
    'platforms': f'[out:json][timeout:150];(nwr["railway"="platform"]({BBOX});nwr["public_transport"="platform"]["train"!="yes"]["bus"!="yes"]({BBOX}););out tags center;',
    'stations': f'[out:json][timeout:150];nwr["railway"~"^(station|halt)$"]["station"~"subway|light_rail|monorail"]({BBOX});out tags center;',
}

def fetch(query):
    errors = []
    for attempt in range(3):
        for endpoint in ENDPOINTS:
            try:
                body = urllib.parse.urlencode({'data': query}).encode()
                request = urllib.request.Request(endpoint, body, {'User-Agent': 'TaipeiBus-open-data-collector/1.0 (github.com/rio10255254/TaipeiBus)'})
                with urllib.request.urlopen(request, timeout=200) as response:
                    data = json.loads(response.read())
                if data.get('elements'):
                    return endpoint, data
                errors.append(f'{endpoint}: empty')
            except Exception as error:  # try the next mirror
                errors.append(f'{endpoint}: {error}')
        time.sleep(20 * (attempt + 1))
    raise SystemExit('Overpass unavailable: ' + '; '.join(errors[-5:]))

parser = argparse.ArgumentParser()
parser.add_argument('--out', type=pathlib.Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=True)
provenance = {'license': 'ODbL 1.0, © OpenStreetMap contributors', 'collectedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'bbox': BBOX, 'files': {}}
for name, query in QUERIES.items():
    endpoint, data = fetch(query)
    (args.out / f'{name}.json').write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
    provenance['files'][name] = {'endpoint': endpoint, 'query': query, 'elements': len(data['elements']),
                                 'osmBase': data.get('osm3s', {}).get('timestamp_osm_base')}
    print(name, len(data['elements']), 'from', endpoint)
(args.out / 'provenance.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2), encoding='utf-8')
