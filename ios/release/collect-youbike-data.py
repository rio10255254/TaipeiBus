"""Bundled YouBike 2.0 station list for every city the app serves (Taipei, New Taipei).

Each city's public immediate feed carries both the static station record (name, address,
coordinate, dock count) and the live counts. Only the static half is bundled; the app reads
the live half at runtime. No credentials and no live counts are written. The feeds are the
bike sources in Regions/regions.json; New Taipei's names its fields differently.

Python 3.13 refuses New Taipei's certificate chain (its CA certificates carry no key identifier,
which phones and curl do not require). Save each feed with curl and pass the copies with --input.
"""
import argparse, datetime, hashlib, json, urllib.request
from pathlib import Path

import service_area

LIMIT = 12 * 1024 * 1024


def read(url):
    with urllib.request.urlopen(url, timeout=45) as response:
        raw = response.read(LIMIT + 1)
    if len(raw) > LIMIT: raise ValueError('YouBike feed size limit')
    return raw


def name(value):
    text = str(value or '').strip()
    for prefix in ('YouBike2.0_', 'YouBike2.0 ', 'YouBike1.0_'):
        if text.startswith(prefix): text = text[len(prefix):]
    return text.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True, help='BikeNetwork.json to write')
    parser.add_argument('--provenance', type=Path)
    parser.add_argument('--input', type=Path, action='append', default=[],
                        help='A saved copy of each feed, in the order of Regions/regions.json, instead of the network')
    args = parser.parse_args()
    feeds = service_area.sources('bike')
    if args.input and len(args.input) != len(feeds): raise ValueError('One saved copy per YouBike feed')
    stations, skipped, records = {}, 0, []
    for index, feed in enumerate(feeds):
        raw = args.input[index].read_bytes() if args.input else read(feed['feed'])
        rows = json.loads(raw)
        if not isinstance(rows, list) or not rows: raise ValueError('YouBike feed shape: ' + feed['id'])
        before = len(stations)
        skipped += collect(rows, stations)
        if len(stations) - before < 500: raise ValueError('YouBike station count too low: %s %d' % (feed['id'], len(stations) - before))
        records.append({'source': feed['feed'], 'sha256': hashlib.sha256(raw).hexdigest(), 'stations': len(stations) - before})
    network = {
        'schema': 1,
        'generatedAt': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z'),
        'source': 'Taipei City and New Taipei City YouBike 2.0 open data',
        'license': 'Open Government Data License 1.0',
        'stations': [stations[key] for key in sorted(stations)],
    }
    # One compact line, like the bundled metro network: generated data, not hand edited.
    text = json.dumps(network, ensure_ascii=False, separators=(',', ':'))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text, encoding='utf-8')
    print('stations', len(stations), 'skipped', skipped, 'bytes', len(text.encode()))
    if args.provenance:
        args.provenance.write_text(json.dumps({
            'schema': 1,
            'collectedAt': network['generatedAt'],
            'feeds': records,
            'license': network['license'],
            'outputSha256': hashlib.sha256(text.encode()).hexdigest(),
            'stations': len(stations),
            'skipped': skipped,
            'note': 'Static fields only; live bike and dock counts are never bundled.',
        }, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def collect(rows, stations):
    """Adds a feed's stations; returns how many rows were skipped. Taipei's rows say latitude and
    Quantity, New Taipei's lat and tot_quantity."""
    skipped = 0
    for row in rows:
        try:
            identifier = str(row['sno']).strip()
            latitude, longitude = float(row.get('latitude', row.get('lat'))), float(row.get('longitude', row.get('lng')))
            capacity = int(row.get('Quantity') or row.get('tot_quantity') or row.get('tot') or 0)
        except (KeyError, TypeError, ValueError):
            skipped += 1; continue
        if not identifier or identifier in stations: skipped += 1; continue
        if not service_area.contains(latitude, longitude): skipped += 1; continue
        if not 0 <= capacity <= 200: skipped += 1; continue
        title = name(row.get('sna'))
        if not title: skipped += 1; continue
        stations[identifier] = {
            'id': identifier, 'name': title, 'englishName': name(row.get('snaen')),
            'district': str(row.get('sarea') or '').strip(), 'englishDistrict': str(row.get('sareaen') or '').strip(),
            'address': str(row.get('ar') or '').strip(), 'englishAddress': str(row.get('aren') or '').strip(),
            'coordinate': {'latitude': round(latitude, 6), 'longitude': round(longitude, 6)},
            'capacity': capacity,
        }
    return skipped


if __name__ == '__main__':
    main()
