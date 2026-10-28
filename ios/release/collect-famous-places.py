"""How well known each place in the service area is, from Wikimedia: places with coordinates in Wikidata, their
Chinese names and aliases, and QRank, the views their articles had across Wikimedia projects over the last year.
The map shows the better known places first; nobody's searches are needed. Wikidata and QRank are CC0. No
credentials. One query and one download: Wikimedia limits per-article pageview requests too tightly to ask for
thousands of places.

The area kept is a parameter, so covering more of Taiwan is a matter of widening it."""
import argparse, csv, datetime, gzip, io, json, re, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

# The app's service area (Geometry.swift isInServiceArea).
AREA = (24.90, 25.25, 121.27, 121.72)
AGENT = 'OneRoad data collector (https://github.com/rio10255254/TaipeiBus)'
QUERY = '''SELECT ?item ?loc (SAMPLE(?zh) AS ?label) (GROUP_CONCAT(DISTINCT ?alias; separator="|") AS ?aliases) WHERE {
  SERVICE wikibase:box { ?item wdt:P625 ?loc .
    bd:serviceParam wikibase:cornerSouthWest "Point(%(west)s %(south)s)"^^geo:wktLiteral .
    bd:serviceParam wikibase:cornerNorthEast "Point(%(east)s %(north)s)"^^geo:wktLiteral . }
  ?item rdfs:label ?zh . FILTER(LANG(?zh) IN ("zh-tw", "zh-hant", "zh"))
  OPTIONAL { ?item skos:altLabel ?alias . FILTER(LANG(?alias) IN ("zh-tw", "zh-hant", "zh")) }
} GROUP BY ?item ?loc'''
QRANK = 'https://qrank.toolforge.org/download/qrank.csv.gz'
# Monthly views below this make a place no better known than any other on the street.
MIN_VIEWS = 30
LIMIT = 30 * 1024 * 1024

def request(url, accept, form=None):
    data = urllib.parse.urlencode(form).encode() if form else None
    return urllib.request.Request(url, data=data, headers={'User-Agent': AGENT, 'Accept': accept})

def read(url, accept, form=None):
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request(url, accept, form), timeout=180) as response:
                raw = response.read(LIMIT + 1)
                if len(raw) > LIMIT: raise ValueError('Wikidata response size limit')
                return json.loads(raw)
        except urllib.error.HTTPError as error:
            if attempt == 3 or error.code not in (429, 500, 502, 503, 504): raise
            # The query service may allow one request a minute; wait as long as it says.
            wait = error.headers.get('Retry-After', '')
            time.sleep(min(300, int(wait)) if wait.isdigit() else 65)
        except (urllib.error.URLError, TimeoutError):
            if attempt == 3: raise
            time.sleep(2 ** attempt)

def ranks(wanted):
    """QRank for the wanted Wikidata items, read as the file streams in (it lists every item)."""
    found = {}
    with urllib.request.urlopen(request(QRANK, 'application/gzip'), timeout=600) as response:
        for row in csv.reader(io.TextIOWrapper(gzip.GzipFile(fileobj=response), encoding='utf-8')):
            if row and row[0] in wanted and row[1].isdigit(): found[row[0]] = int(row[1])
    return found

def clean(name):
    """The name as it is said: no bracketed note, 台 rather than 臺 (as collect-voice-places.py writes names)."""
    name = re.sub(r'[（(【\[].*?[）)】\]]', '', name or '')
    return re.sub(r'\s+', '', name).replace('臺', '台').strip('-－、,，')

def usable(name):
    # Two to twenty characters, Chinese for the most part (台北101 is fine, an English alias is not).
    if not 2 <= len(name) <= 20: return False
    chinese = sum(1 for c in name if '一' <= c <= '鿿')
    return chinese >= 2 and chinese >= len(name) - 4

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    south, north, west, east = AREA
    query = QUERY % {'south': south, 'north': north, 'west': west, 'east': east}
    # POST: the query is too long to send in a URL reliably.
    rows = read('https://query.wikidata.org/sparql', 'application/sparql-results+json', {'query': query})['results']['bindings']
    items = {}
    for row in rows:
        match = re.match(r'Point\(([-\d.]+) ([-\d.]+)\)', row['loc']['value'])
        if not match: continue
        lon, lat = float(match.group(1)), float(match.group(2))
        if not (south <= lat <= north and west <= lon <= east): continue
        entry = items.setdefault(row['item']['value'].rsplit('/', 1)[-1], {'points': set(), 'names': []})
        entry['points'].add((round(lat, 5), round(lon, 5)))
        for name in map(clean, [row['label']['value']] + row.get('aliases', {}).get('value', '').split('|')):
            if usable(name) and name not in entry['names']: entry['names'].append(name)
    print('Wikidata places with a Chinese name', len(items), flush=True)
    counted = ranks(set(items))
    places = []
    for key, entry in items.items():
        monthly = counted.get(key, 0) / 12
        if monthly < MIN_VIEWS or not entry['names']: continue
        # One place mapped as several points (a park's gates) keeps each.
        for lat, lon in sorted(entry['points']):
            for name in entry['names']: places.append([name, lat, lon, round(monthly)])
    places.sort(key=lambda place: (-place[3], place[0]))
    if sum(1 for place in places if place[3] >= 1000) < 50: raise ValueError('Too few well-known places')
    output = {'schema': 1, 'generatedAt': datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
              'source': 'Wikidata and QRank (both CC0)', 'views': 'monthly average of QRank (views over a year, all Wikimedia projects)',
              'places': places}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(output, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
    print('Saved', len(places), 'names of', sum(1 for key in items if counted.get(key, 0) / 12 >= MIN_VIEWS), 'places', flush=True)

if __name__ == '__main__': main()
