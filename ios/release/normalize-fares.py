"""Compact fare table for the app from the official TDX snapshot (collect-fares.py).

Metro: the adult fare between every pair of stations, per operator, as a matrix over station codes.
Buses: per route, the adult electronic-ticket fare of one section, whether it is free, and its fare
buffer zones (a ride from before a zone to after it pays one more section)."""
import argparse, gzip, json
from pathlib import Path

ADULT, ELECTRONIC, SINGLE = 1, 3, 1

def price(fares, ticket):
    for fare in fares or []:
        if fare.get('FareClass') == ADULT and fare.get('TicketType') == ticket and not fare.get('CitizenCode'):
            return fare.get('Price')
    return None

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True); parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    snapshot = json.load(gzip.open(args.input, 'rt', encoding='utf-8'))
    tables = snapshot['tables']
    metro = {}
    for key in ('metro:TRTC', 'metro:NTMC'):
        rows = tables.get(key) or []
        codes = sorted({r['OriginStationID'] for r in rows} | {r['DestinationStationID'] for r in rows})
        index = {code: i for i, code in enumerate(codes)}
        matrix = [[None] * len(codes) for _ in codes]
        for r in rows:
            value = price(r.get('Fares'), SINGLE)
            if value is not None: matrix[index[r['OriginStationID']]][index[r['DestinationStationID']]] = value
        metro[key.split(':')[1]] = {'stations': codes, 'adult': matrix}
    bus = {}
    for key in ('bus:Taipei', 'bus:NewTaipei'):
        for r in tables.get(key) or []:
            section = (r.get('SectionFares') or [{}])[0]
            value = price(section.get('Fares'), ELECTRONIC) or price(section.get('Fares'), SINGLE)
            free = bool(r.get('IsFreeBus'))
            if value is None and not free: continue
            entry = bus.setdefault(r['RouteID'], {'name': r['RouteName'], 'price': 0 if free else value, 'free': free, 'zones': []})
            # Sub-routes share the route's fare; their buffer zones are merged, once each.
            for zone in section.get('BufferZones') or []:
                item = [str(zone.get('Direction', 0)), zone['FareBufferZoneOrigin']['StopID'], zone['FareBufferZoneOrigin']['StopName'],
                        zone['FareBufferZoneDestination']['StopID'], zone['FareBufferZoneDestination']['StopName']]
                if item not in entry['zones']: entry['zones'].append(item)
    updated = max((r.get('UpdateTime', '') for rows in tables.values() for r in rows), default='')[:10]
    out = {'schema': 1, 'source': 'MOTC TDX official fares', 'license': 'Open Government Data License 1.0',
           'updated': updated, 'metro': metro, 'bus': bus}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    filled = sum(v is not None for m in metro.values() for row in m['adult'] for v in row)
    print('metro stations', {k: len(v['stations']) for k, v in metro.items()}, 'pairs', filled,
          'bus routes', len(bus), 'zoned', sum(1 for b in bus.values() if b['zones']), 'bytes', args.out.stat().st_size)

if __name__ == '__main__': main()
