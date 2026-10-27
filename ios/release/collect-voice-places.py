"""Names of the places riders say by voice, from TDX's official tourism data: scenic spots, restaurants
and hotels, with where each is. The app corrects misheard place names against them (by sound) and tells
the recogniser to expect the ones near the rider. Credentials never enter output.

Cities and the area kept are parameters, so covering more of Taiwan is a matter of naming its cities."""
import argparse, datetime, gzip, json, os, re, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

BASE = 'https://tdx.transportdata.tw'
# (kind, list path, name field)
KINDS = [('spot', 'ScenicSpot', 'ScenicSpotName'), ('food', 'Restaurant', 'RestaurantName'), ('hotel', 'Hotel', 'HotelName')]
CITIES = ['Taipei', 'NewTaipei', 'Keelung']
# The app's service area (Geometry.swift isInServiceArea).
AREA = (24.90, 25.25, 121.27, 121.72)
LIMIT = 40 * 1024 * 1024
MAX_PLACES = 6000

def read(url, headers=None, data=None):
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers or {}), timeout=90) as response:
        raw = response.read(LIMIT + 1)
        if len(raw) > LIMIT: raise ValueError('Tourism snapshot size limit')
        if response.headers.get('Content-Encoding') == 'gzip' or raw[:2] == b'\x1f\x8b': raw = gzip.decompress(raw)
        return raw

def clean(name):
    """The name as it is said: no bracketed branch or note, 台 rather than 臺 (as speech is written)."""
    name = re.sub(r'[（(【\[].*?[）)】\]]', '', name or '')
    name = re.sub(r'\s+', '', name).replace('臺', '台').strip('-－·・、,，')
    return name

def usable(name):
    # Two to twelve characters, Chinese for the most part (台北101 is fine, an English hotel name is not).
    if not 2 <= len(name) <= 12: return False
    chinese = sum(1 for c in name if '一' <= c <= '鿿')
    return chinese >= 2 and chinese >= len(name) - 4

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--cities', default=','.join(CITIES))
    args = parser.parse_args()
    cid, secret = os.environ['TDX_CLIENT_ID'], os.environ['TDX_CLIENT_SECRET']
    payload = urllib.parse.urlencode({'grant_type': 'client_credentials', 'client_id': cid, 'client_secret': secret}).encode()
    answer = json.loads(read(BASE + '/auth/realms/TDXConnect/protocol/openid-connect/token', {'Content-Type': 'application/x-www-form-urlencoded'}, payload))
    headers = {'Authorization': 'Bearer ' + answer['access_token'], 'Accept-Encoding': 'gzip'}; del cid, secret, answer, payload
    south, north, west, east = AREA
    places, seen, counts, missing = [], set(), {}, []
    first = True
    for kind, path, field in KINDS:
        for city in [c for c in args.cities.split(',') if c]:
            if not first: time.sleep(6.2)
            first = False
            query = urllib.parse.urlencode({'$select': f'{field},Position', '$format': 'JSON'})
            try:
                rows = json.loads(read(f'{BASE}/api/basic/v2/Tourism/{path}/{city}?{query}', headers))
            except urllib.error.HTTPError as error:
                missing.append(f'{path}/{city} {error.code}'); print(path, city, 'unavailable', error.code, flush=True)
                continue
            kept = 0
            for row in rows if isinstance(rows, list) else []:
                position = row.get('Position') or {}
                lat, lon = position.get('PositionLat'), position.get('PositionLon')
                name = clean(row.get(field, ''))
                if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)): continue
                if not (south <= lat <= north and west <= lon <= east) or not usable(name) or name in seen: continue
                seen.add(name); kept += 1
                places.append([name, round(lat, 5), round(lon, 5), kind])
            counts[f'{path}/{city}'] = kept
            print(path, city, len(rows) if isinstance(rows, list) else 0, 'kept', kept, flush=True)
    # Spots first: they are what riders name most; restaurants and hotels fill what room is left.
    order = {kind: index for index, (kind, _, _) in enumerate(KINDS)}
    places.sort(key=lambda place: (order[place[3]], place[0]))
    places = places[:MAX_PLACES]
    if sum(1 for place in places if place[3] == 'spot') < 100: raise ValueError(f'Too few scenic spots: {counts} {missing}')
    document = {'schema': 1, 'generatedAt': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
                'source': 'MOTC TDX tourism data (ScenicSpot, Restaurant, Hotel)', 'license': 'Open Government Data License 1.0',
                'places': places}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(document, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print('Saved', len(places), 'place names', counts, 'missing', missing, flush=True)

if __name__ == '__main__': main()
