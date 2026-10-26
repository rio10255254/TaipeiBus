"""Compact fare table for the app from the official TDX snapshot (collect-fares.py).

Metro: the fare between every pair of stations, per operator and rider class, as matrices over station
codes. Classes with the same fares everywhere share one matrix ('classes' maps a class to its index).
Buses: per route, an index into 'busFares' (the electronic-ticket fare of one section per rider class),
whether it is free, and its fare buffer zones (a ride from before a zone to after it pays one more section).

TDX FareClass (公共運輸 swagger): 1 成人, 2 學生, 3 孩童, 4 敬老, 5 愛心, 6 愛心孩童, 7 愛心優待/愛心陪伴,
8 團體 (rail) or 軍警 (bus: 9 軍警). TicketType 1 is the single or cash fare, 3 the electronic ticket."""
import argparse, gzip, json
from pathlib import Path

ELECTRONIC, SINGLE = 3, 1
# The classes a rider can pick. Metro child fares exist only for Taipei and New Taipei citizens
# (CitizenCode TPE/NWT, the same price); Taipei Metro has no student fare, so the app uses the adult one.
CLASSES = {'adult': 1, 'student': 2, 'child': 3, 'elderly': 4, 'disabled': 5}

def price(fares, ticket, fare_class):
    plain = cited = None
    for fare in fares or []:
        if fare.get('FareClass') != fare_class or fare.get('TicketType') != ticket: continue
        if not fare.get('CitizenCode'): plain = fare.get('Price')
        elif fare.get('CitizenCode') in ('TPE', 'NWT') and cited is None: cited = fare.get('Price')
    return plain if plain is not None else cited

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
        matrices, classes = [], {}
        for name, fare_class in CLASSES.items():
            matrix = [[None] * len(codes) for _ in codes]
            for r in rows:
                value = price(r.get('Fares'), SINGLE, fare_class)
                if value is not None: matrix[index[r['OriginStationID']]][index[r['DestinationStationID']]] = value
            if all(v is None for row in matrix for v in row): continue
            if matrix not in matrices: matrices.append(matrix)
            classes[name] = matrices.index(matrix)
        metro[key.split(':')[1]] = {'stations': codes, 'classes': classes, 'matrices': matrices}
    bus, bus_fares = {}, []
    for key in ('bus:Taipei', 'bus:NewTaipei'):
        for r in tables.get(key) or []:
            section = (r.get('SectionFares') or [{}])[0]
            free = bool(r.get('IsFreeBus'))
            fares = {}
            for name, fare_class in CLASSES.items():
                value = price(section.get('Fares'), ELECTRONIC, fare_class)
                if value is None: value = price(section.get('Fares'), SINGLE, fare_class)
                if free: value = 0
                if value is not None: fares[name] = value
            if 'adult' not in fares: continue
            if fares not in bus_fares: bus_fares.append(fares)
            entry = bus.setdefault(r['RouteID'], {'name': r['RouteName'], 'fare': bus_fares.index(fares), 'free': free, 'zones': []})
            # Sub-routes share the route's fare; their buffer zones are merged, once each.
            for zone in section.get('BufferZones') or []:
                item = [str(zone.get('Direction', 0)), zone['FareBufferZoneOrigin']['StopID'], zone['FareBufferZoneOrigin']['StopName'],
                        zone['FareBufferZoneDestination']['StopID'], zone['FareBufferZoneDestination']['StopName']]
                if item not in entry['zones']: entry['zones'].append(item)
    updated = max((r.get('UpdateTime', '') for rows in tables.values() for r in rows), default='')[:10]
    out = {'schema': 2, 'source': 'MOTC TDX official fares', 'license': 'Open Government Data License 1.0',
           'updated': updated, 'metro': metro, 'busFares': bus_fares, 'bus': bus}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    filled = sum(v is not None for m in metro.values() for row in m['matrices'][m['classes']['adult']] for v in row)
    print('metro stations', {k: len(v['stations']) for k, v in metro.items()}, 'classes', {k: v['classes'] for k, v in metro.items()},
          'pairs', filled, 'bus routes', len(bus), 'fare sets', bus_fares, 'zoned', sum(1 for b in bus.values() if b['zones']),
          'bytes', args.out.stat().st_size)

if __name__ == '__main__': main()
