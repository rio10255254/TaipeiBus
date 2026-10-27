"""Names of the places riders say by voice, from the Tourism Administration's open data (觀光資訊資料庫):
attractions, restaurants and hotels, with where each is. The app corrects misheard place names against
them (by sound) and tells the recogniser to expect the ones near the rider. No credentials are needed.

The files cover the whole country; the area kept is a parameter, so covering more of Taiwan is a matter
of widening it."""
import argparse, datetime, io, json, re, ssl, urllib.request, zipfile
from pathlib import Path

SOURCE = 'https://media.taiwan.net.tw/XMLReleaseAll_public/v2.0/Zh_tw/'
# (kind, archive, list file, list key, name field)
KINDS = [('spot', 'Attraction', 'AttractionList.json', 'Attractions', 'AttractionName'),
         ('food', 'Restaurant', 'RestaurantList.json', 'Restaurants', 'RestaurantName'),
         ('hotel', 'Hotel', 'HotelList.json', 'Hotels', 'HotelName')]
# The app's service area (Geometry.swift isInServiceArea).
AREA = (24.90, 25.25, 121.27, 121.72)
LIMIT = 60 * 1024 * 1024
MAX_PLACES = 6000

def read(url):
    # The certificate is verified, but not to Python 3.13's strict profile, which the site's chain fails
    # (no Subject Key Identifier).
    context = ssl.create_default_context()
    context.verify_flags &= ~getattr(ssl, 'VERIFY_X509_STRICT', 0)
    request = urllib.request.Request(url, headers={'User-Agent': 'OneRoad data collector'})
    with urllib.request.urlopen(request, timeout=120, context=context) as response:
        raw = response.read(LIMIT + 1)
        if len(raw) > LIMIT: raise ValueError('Tourism archive size limit')
        return raw

def clean(name):
    """The name as it is said: no bracketed branch or note, 台 rather than 臺 (as speech is written)."""
    name = re.sub(r'[（(【\[].*?[）)】\]]', '', name or '')
    # 「台北典藏植物園_天使館」 is the garden; 「和逸．台北民生館」 is said without the dot.
    name = re.sub(r'\s+', '', name).split('_')[0].replace('臺', '台')
    return re.sub(r'[．·・]', '', name).strip('-－、,，')

def usable(name):
    # Two to twelve characters, Chinese for the most part (台北101 is fine, an English hotel name is not).
    if not 2 <= len(name) <= 12: return False
    chinese = sum(1 for c in name if '一' <= c <= '鿿')
    return chinese >= 2 and chinese >= len(name) - 4

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    south, north, west, east = AREA
    places, seen, counts, updated = [], set(), {}, {}
    for kind, archive, listed, key, field in KINDS:
        with zipfile.ZipFile(io.BytesIO(read(f'{SOURCE}{archive}-json.zip'))) as files:
            document = json.loads(files.read(listed).decode('utf-8-sig'))
        rows = document.get(key) or []
        updated[archive] = document.get('UpdateTime', '')
        kept = 0
        for row in rows:
            lat, lon = row.get('PositionLat'), row.get('PositionLon')
            if not isinstance(lat, (int, float)) or not isinstance(lon, (int, float)): continue
            if not (south <= lat <= north and west <= lon <= east): continue
            # Closed for good (ServiceStatus 0) is left out; other names it goes by count as well.
            if row.get('ServiceStatus', 1) == 0: continue
            for name in [row.get(field, '')] + [n for n in row.get('AlternateNames') or [] if isinstance(n, str)]:
                name = clean(name)
                if not usable(name) or name in seen: continue
                seen.add(name); kept += 1
                places.append([name, round(lat, 5), round(lon, 5), kind])
        counts[archive] = kept
        print(archive, len(rows), 'kept', kept, flush=True)
    # Spots first: they are what riders name most; restaurants and hotels fill what room is left.
    order = {kind: index for index, (kind, *_) in enumerate(KINDS)}
    places.sort(key=lambda place: (order[place[3]], place[0]))
    places = places[:MAX_PLACES]
    if sum(1 for place in places if place[3] == 'spot') < 100: raise ValueError(f'Too few attractions: {counts}')
    output = {'schema': 1, 'generatedAt': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
              'source': 'Tourism Administration, MOTC: 觀光資訊資料庫 (attractions, restaurants, hotels)', 'sourceUpdated': updated,
              'license': 'Open Government Data License 1.0', 'places': places}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(output, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print('Saved', len(places), 'place names', counts, flush=True)

if __name__ == '__main__': main()
