"""Match OpenStreetMap tunnel/bridge/layer tags onto the official TDX metro geometry.

Input: the collect-metro-levels.py snapshot and ios/TaipeiBus/MetroNetwork.json.
Output: ios/TaipeiBus/MetroLevels.json with a height profile ([metres along, height]) for every
pattern, plus an audit of how much of each pattern matched OSM track.

Heights: viaducts sit 9 + 4·layer metres up (layer 1 ≈ 13 m), close to Taipei's viaducts.
Tunnels are layered 10 + 8·|layer| metres down (layer −1 ≈ 18 m), deeper than built, so lines
crossing at different OSM layers stay readable in 3D. Ramps (at most 5 %) lie inside the tunnel
or on the viaduct, starting at the OSM portal or abutment.
"""
import argparse, json, math, pathlib, statistics, collections

parser = argparse.ArgumentParser()
parser.add_argument('--osm', type=pathlib.Path, required=True)
parser.add_argument('--network', type=pathlib.Path, default=pathlib.Path('ios/TaipeiBus/MetroNetwork.json'))
parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path('ios/TaipeiBus/MetroLevels.json'))
args = parser.parse_args()

network = json.loads(args.network.read_text(encoding='utf-8'))
tracks = json.loads((args.osm / 'tracks.json').read_text(encoding='utf-8'))
provenance = json.loads((args.osm / 'provenance.json').read_text(encoding='utf-8'))

def distance(a, b):  # identical to TransitCore Coordinate.distance
    cosine = math.cos((a[0] + b[0]) * math.pi / 360)
    return math.hypot((a[1] - b[1]) * cosine, a[0] - b[0]) * 111_320

def bearing(a, b):
    return (math.degrees(math.atan2((b[1] - a[1]) * math.cos(math.radians(a[0])), b[0] - a[0])) + 360) % 360

def layer(tags):
    try: return int(float(tags.get('layer', '0')))
    except ValueError: return 0

def height(tags):
    tunnel = tags.get('tunnel') not in (None, 'no')
    bridge = tags.get('bridge') not in (None, 'no')
    level = layer(tags)
    if tags.get('tunnel') == 'building_passage':  # through a station building: follow its layer
        tunnel = level < 0
    if tunnel or (level < 0 and not bridge):
        return -(10 + 8 * max(1, abs(level)))
    if bridge:
        return 9 + 4 * max(1, level)
    return 0.0

SKIP = ('機廠', '袋狀軌', '袋形軌', '測試軌', '卸載軌', '機場捷運', 'Crossover')
segments = []  # (a, b, height, bearing, name)
for way in tracks['elements']:
    tags = way.get('tags', {})
    name = tags.get('name') or ''
    if tags.get('service') in ('yard', 'siding', 'spur') or any(word in name for word in SKIP):
        continue
    points = [(p['lat'], p['lon']) for p in way.get('geometry', [])]
    h = height(tags)
    for a, b in zip(points, points[1:]):
        segments.append((a, b, h, bearing(a, b), name))

CELL = 0.002
grid = collections.defaultdict(list)
for index, (a, b, *_rest) in enumerate(segments):
    for lat in range(int(min(a[0], b[0]) / CELL) - 1, int(max(a[0], b[0]) / CELL) + 2):
        for lon in range(int(min(a[1], b[1]) / CELL) - 1, int(max(a[1], b[1]) / CELL) + 2):
            grid[(lat, lon)].append(index)

def project(p, a, b):
    cosine = math.cos(math.radians(p[0]))
    ax, ay, bx, by, px, py = a[1] * cosine, a[0], b[1] * cosine, b[0], p[1] * cosine, p[0]
    dx, dy = bx - ax, by - ay
    squared = dx * dx + dy * dy
    t = 0 if squared == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / squared))
    return distance(p, (ay + dy * t, (ax + dx * t) / cosine))

def classify(point, heading, line_name):
    best = None
    for index in grid.get((int(point[0] / CELL), int(point[1] / CELL)), []):
        a, b, h, way_bearing, name = segments[index]
        gap = project(point, a, b)
        if gap > 28: continue
        turn = abs((way_bearing - heading + 540) % 360 - 180)
        turn = min(turn, 180 - turn)
        if turn > 35: continue  # a crossing line, not this one
        score = gap + turn * 0.4 - (12 if line_name and line_name in name else 0)
        if best is None or score < best[0]: best = (score, h)
    return None if best is None else best[1]

def keyframes(samples, step, grade=0.05):
    # Smooth single-sample flicker, then fill gaps from the nearest matched neighbour.
    values = list(samples)
    known = [i for i, v in enumerate(values) if v is not None]
    if not known: return [[0.0, 0.0]], 0.0
    for i, v in enumerate(values):
        if v is None:
            nearest = min(known, key=lambda k: abs(k - i)); values[i] = values[nearest]
    window = 4
    target = [statistics.median_low(values[max(0, i - window): i + window + 1]) for i in range(len(values))]
    limit = grade * step
    def sweep(order):
        out = list(target)
        for previous, i in zip(order, order[1:]):
            out[i] = max(out[previous] - limit, min(out[previous] + limit, out[i]))
        return out
    forward, backward = sweep(list(range(len(target)))), sweep(list(range(len(target)))[::-1])
    # Ramps sit inside the tunnel or on the viaduct: of the two sweeps take the one nearer grade.
    heights = [f if abs(f) <= abs(b) else b for f, b in zip(forward, backward)]
    for order in (list(range(len(heights))), list(range(len(heights)))[::-1]):  # close any residual step
        for previous, i in zip(order, order[1:]):
            heights[i] = max(heights[previous] - limit, min(heights[previous] + limit, heights[i]))
    points = [((i + 0.5) * step, round(h, 2)) for i, h in enumerate(heights)]
    frames = [points[0]]
    for i in range(1, len(points) - 1):
        (x0, h0), (x1, h1), (x2, h2) = frames[-1], points[i], points[i + 1]
        expected = h0 + (h2 - h0) * (x1 - x0) / (x2 - x0)
        if abs(expected - h1) > 0.25: frames.append(points[i])
    frames.append(points[-1])
    frames = [[0.0, frames[0][1]]] + [[round(x, 1), h] for x, h in frames] + [[round(len(heights) * step, 1), frames[-1][1]]]
    return frames, len(known) / len(samples)

lines = {line['id']: line['name'] for line in network['lines']}
profiles, audit = {}, {}
STEP = 10.0
for pattern in network['patterns']:
    coordinates = [(c['latitude'], c['longitude']) for c in pattern['coordinates']]
    cumulative = [0.0]
    for a, b in zip(coordinates, coordinates[1:]): cumulative.append(cumulative[-1] + distance(a, b))
    length = cumulative[-1]
    samples, segment = [], 0
    distance_along = STEP / 2
    while distance_along < length:
        while cumulative[segment + 1] < distance_along: segment += 1
        a, b = coordinates[segment], coordinates[segment + 1]
        span = cumulative[segment + 1] - cumulative[segment]
        t = 0 if span == 0 else (distance_along - cumulative[segment]) / span
        point = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        samples.append(classify(point, bearing(a, b), lines.get(pattern['lineID'], '')))
        distance_along += STEP
    frames, coverage = keyframes(samples, STEP)
    key = pattern['id'] + '|' + pattern['direction']
    profiles[key] = frames
    audit[key] = {'lengthMeters': round(length), 'matched': round(coverage, 3),
                  'elevatedMeters': round(sum(STEP for v in samples if v is not None and v > 3)),
                  'undergroundMeters': round(sum(STEP for v in samples if v is not None and v < -3))}

result = {'schema': 1, 'source': 'OpenStreetMap tunnel/bridge/layer tags matched onto MOTC TDX metro geometry',
          'license': provenance['license'], 'networkGeneratedAt': network['generatedAt'],
          'osmBase': provenance['files']['tracks']['osmBase'], 'profiles': profiles}
args.out.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
for key, value in sorted(audit.items()): print(key, value)
