#!/usr/bin/env python3
"""Write src/sim/paths.json: the real geometry the simulated store preview moves along.

Everything comes from the data bundled in the app (ios/TaipeiBus): the published shapes of bus
routes 939 and 仁愛幹線, the track of the Wenhu line, and its stations. Nothing is drawn by hand.
"""
import gzip
import json
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT.parent / "ios" / "TaipeiBus"


def metres(a, b):
    return math.hypot((a[0] - b[0]) * 101_000, (a[1] - b[1]) * 111_000)


def length(p):
    return sum(metres(a, b) for a, b in zip(p, p[1:]))


def shapes(folder, name):
    routes = json.loads(gzip.open(APP / folder / "GetRoute.gz").read())["BusInfo"]
    ids = {r["Id"] for r in routes if r["nameZh"] == name}
    out = []
    for s in json.loads(gzip.open(APP / folder / "GetBusShape.gz").read()):
        if s["RouteID"] in ids:
            out.append([tuple(map(float, p.split())) for p in re.search(r"\((.*)\)", s["wkt"]).group(1).split(", ")])
    return out


def dense(p, step=15):
    """A point at least every `step` metres: published shapes have none along a straight street."""
    out = [p[0]]
    for a, b in zip(p, p[1:]):
        n = max(1, math.ceil(metres(a, b) / step))
        out += [(a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n) for k in range(1, n + 1)]
    return out


def nearest(p, point):
    return min(range(len(p)), key=lambda i: metres(p[i], point))


def between(p, a, b):
    i, j = nearest(p, a), nearest(p, b)
    return p[i:j + 1] if i <= j else p[j:i + 1][::-1]


def towards(a, b, distance):
    k = min(0.5, distance / max(1e-6, metres(a, b)))
    return (a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k)


def rounded(p, radius=16, steps=14):
    """Each corner taken as a curve of about `radius` metres, the way a bus turns, instead of a point."""
    out = [p[0]]
    for before, corner, after in zip(p, p[1:], p[2:]):
        start, end = towards(corner, before, radius), towards(corner, after, radius)
        for n in range(steps + 1):
            k = n / steps
            out.append(tuple((1 - k) ** 2 * start[i] + 2 * k * (1 - k) * corner[i] + k * k * end[i] for i in (0, 1)))
    return out + [p[-1]]


def main():
    hall = (121.5578, 25.0376)
    # 939 towards City Hall: east along Ren'ai Road, north at Songzhi Road, then east again.
    turn, north = (121.56361, 25.03749), (121.56368, 25.03916)
    best = None
    for shape in shapes("BusMetadata/ntpc", "939"):
        i = nearest(shape, turn)
        if 0 < i < len(shape) - 2 and metres(shape[i], turn) < 30 and metres(shape[i + 1], north) < 30:
            best = [shape[i - 1], shape[i], shape[i + 1], shape[i + 2]]
    # The trip the recorded itinerary shows: 967 from the Memorial Hall to Zhongxiao Dunhua, then 630 to Neihu Station.
    home, change, neihu = (121.5609264, 25.03768543), (121.549174, 25.0430127), (121.594132, 25.08334)

    def leg(folder, name, a, b):
        found = None
        for shape in map(dense, shapes(folder, name)):
            # A route passes the same street in both directions: every pass near each stop is tried.
            starts = [i for i, p in enumerate(shape) if metres(p, a) < 45]
            ends = [j for j, p in enumerate(shape) if metres(p, b) < 45]
            for i in starts:
                for j in ends:
                    if i < j:
                        part = [a] + shape[i + 1:j] + [b]
                        if found is None or length(part) < length(found):
                            found = part
        return found or []

    renai = max(shapes("BusMetadata", "仁愛幹線"), key=lambda s: nearest(s, hall) - nearest(s, (121.5440, 25.0379)))  # the westbound one
    stop = (121.5571, 25.0379)
    out = {
        "bus": rounded(best) if best else [],
        "trip": [leg("BusMetadata/ntpc", "967", home, change), leg("BusMetadata", "630", change, neihu)],
        "tripStops": [home, change, neihu],
        "stop": stop,
        # 259 m along Ren'ai Road to the stop, as the app's own walking guidance drew it.
        "walk": between(dense(renai), (121.5597, 25.0376), stop),
    }
    paths = {"bus": out["bus"], "trip 967": out["trip"][0], "trip 630": out["trip"][1], "walk": out["walk"]}
    for key, line in paths.items():
        print(key, len(line), round(length(line)), "m", line[0], line[-1])

    def tidy(value):
        if isinstance(value, (list, tuple)) and value and isinstance(value[0], (int, float)):
            return [round(value[0], 6), round(value[1], 6)]
        return [tidy(v) for v in value]
    # The map is drawn with the app's own style, copied so the edit builds without reaching outside its folder.
    (ROOT / "src" / "sim" / "style.json").write_text((APP / "taipei.json").read_text())
    (ROOT / "src" / "sim" / "paths.json").write_text(json.dumps({k: tidy(v) for k, v in out.items()}) + "\n")


if __name__ == "__main__":
    main()
