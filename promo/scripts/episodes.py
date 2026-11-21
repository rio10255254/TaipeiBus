#!/usr/bin/env python3
"""Write src/episodes.json: every film's lines and shots.

The shots are written here rather than by hand in JSON because a camera pose is easier to say as
"look at this part of the screenshot, this large, this high on the page" (`look`) than as offsets.
Rectangles and points are in screenshot pixels (1206 × 2622). Beats are at 120 bpm, counted from
the start of the shot. See docs/series.md for the storyboards.

    python3 scripts/episodes.py && python3 scripts/make-voice.py && python3 scripts/make-sound.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PX = (620 - 2 * (7 + 10)) / 1206  # page pixels per screenshot pixel at scale 1 (src/kit.tsx)

# The screens, from AppStoreScreenshotTests' live captures (public/shots/<name>.jpg).
S = {
    "bus": "a-07-live-bus-in-3d",
    "busCard": "a-07-live-bus-with-details",
    "stationA": "a-11-live-station-tag",  # beside the bus above, in the same minutes
    "station": "b-11-live-station-tag",
    "compare": "b-02-trip-choices",
    "steps": "b-06-full-itinerary",
    "walk": "b-12-in-app-walking",
    "keypad": "a-03-route-keypad",
    "home": "a-01-nearby-map",
}


def look(cx, cy, s, top=800, rx=4, ry=6, rz=0, dx=0):
    """The pose that puts screenshot point (cx, cy) at page height `top`, centred, at scale `s`."""
    return {"x": round(-(cx - 603) * PX * s + dx), "y": round(top - 960 - (cy - 1311) * PX * s), "s": s, "rx": rx, "ry": ry, "rz": rz}


def whole(y=760, s=1.3, rx=10, ry=-12, rz=2, x=10):
    """The whole phone, low on the page under the cover's headline."""
    return {"x": x, "y": y, "s": s, "rx": rx, "ry": ry, "rz": rz}


def lift(rect, at, z=140, glow=False, out=None, on=None):
    d = {"rect": rect, "z": z, "at": at}
    if glow: d["glow"] = True
    if out is not None: d["out"] = out
    if on: d["on"] = on
    return d


def note(text, x, y, at, tone="amber", tilt=-3, sub=None, size=None, out=None):
    d = {"text": text, "x": x, "y": y, "at": at, "tone": tone, "tilt": tilt}
    if sub: d["sub"] = sub
    if size: d["size"] = size
    if out is not None: d["out"] = out
    return d


END = {"endLine": "公車、捷運、YouBike，一路接到底", "outro": "App Store 免費下載", "outroSay": "一路，App Store 免費下載。", "liftFrom": 1, "endBeats": 8}

# Pieces of the screens, named once.
BUS_TAG = [330, 1196, 912, 1352]
BUS_AT = (1045, 1270)
CARD_FOLLOW = [60, 2436, 606, 2584]
CARD_NEXT = [44, 1930, 1140, 2090]
CARD_SPEED = [44, 2090, 760, 2216]
STATION_TAG = [376, 820, 840, 1078]
STATION_DOT = (602, 1112)
CMP_BEST = [70, 1816, 1136, 2270]
CMP_TIME = [90, 1836, 880, 2112]
CMP_MODES = [100, 2110, 840, 2190]
CMP_ALT1 = [70, 2300, 590, 2440]
CMP_ALT2 = [616, 2300, 1136, 2440]
CMP_STEPS = (1015, 2135)
STEP_HEAD = [28, 396, 1178, 626]
STEP_BIKE = [28, 704, 1178, 1262]
BIKE_PICKUP = [170, 788, 970, 926]
BIKE_RETURN = [170, 940, 970, 1080]
STEP_METRO = [28, 1314, 1178, 1806]
STEP_WALK = [28, 1866, 1178, 2076]
STEP_ARRIVE = [28, 2126, 1178, 2276]
STEP_GO = [54, 2360, 1150, 2500]
WALK_BANNER = [50, 194, 1156, 480]
WALK_ROUTE = [0, 1180, 1206, 1360]
WALK_CARD = [48, 1980, 1162, 2500]
WALK_TIME = [60, 2130, 560, 2310]
WALK_DONE = [620, 2320, 1118, 2456]
KEY_BLUE, KEY_2, KEY_7 = [270, 1924, 478, 2052], [728, 1924, 936, 2052], [498, 2226, 706, 2354]
PAD_FIELD = [50, 374, 1156, 504]
PAD_RESULT = [44, 676, 1160, 812]
HOME_STOP1 = [48, 2180, 584, 2316]
HOME_STOP2 = [618, 2180, 1162, 2316]
HOME_SEARCH = [50, 2350, 824, 2498]

EPISODES = [
    {
        "id": "ep1", "label": "#1 公車到哪了", "theme": "night", "title": "站牌寫三分鐘\n**車到底在哪**？", **END,
        "lines": [
            {"text": "站牌寫三分鐘，\n**車到底在哪**？", "say": "[curious] 站牌寫三分鐘，車到底在哪？", "beats": 8, "cues": [[0.2, "pop"]]},
            {"text": "打開地圖，\n**看它開過來**。", "say": "打開地圖，看它開過來。", "beats": 8, "cues": [[0, "whoosh"], [2, "pop"], [4, "chime"]]},
            {"text": "點一下那輛車，\n**鏡頭跟著它走**。", "say": "點一下那輛車，鏡頭跟著它走。", "beats": 9, "cues": [[1, "tap"], [1.4, "whoosh"], [4.5, "pop"], [6, "tap"]]},
            {"text": "下一班還要多久，\n**一眼看完**。", "say": "下一班還要多久，一眼看完。", "beats": 9, "cues": [[1, "pop"], [2.5, "pop"], [4.5, "flip"], [6, "chime"]]},
        ],
        "shots": [
            {"line": 0, "screen": S["bus"], "pose": whole(), "drift": 0.04, "pulses": [{"x": BUS_AT[0], "y": BUS_AT[1], "at": 2}]},
            {"line": 1, "screen": S["bus"], "pose": {"x": -70, "y": -120, "s": 1.75, "rx": 6, "ry": 11, "rz": -1}, "drift": 0.05,
             "pulses": [{"x": BUS_AT[0], "y": BUS_AT[1], "at": 0.5, "until": 2}], "lifts": [lift(BUS_TAG, 2, 150, True)],
             "stickers": [note("車牌、路線", 330, 560, 4, tilt=-4, sub="每輛車都看得到")]},
            {"line": 2, "screen": S["bus"], "pose": {"x": -60, "y": -140, "s": 1.7, "rx": 4, "ry": -8, "rz": 1}, "drift": 0.02,
             "taps": [{"x": 640, "y": 1272, "at": 1}], "swaps": [{"at": 1.4, "screen": S["busCard"], "how": "fade"}]},
            {"line": 2, "from": 3.2, "screen": S["busCard"], "pose": look(603, 2510, 1.8, 1150, rx=3, ry=7, dx=22), "drift": 0.02,
             "lifts": [lift(CARD_FOLLOW, 1.3, 150, True)], "taps": [{"x": 330, "y": 2510, "at": 2.8}],
             "stickers": [note("跟隨公車", 800, 840, 1.6, tilt=3, sub="縮放也不會跟丟")]},
            {"line": 3, "screen": S["busCard"], "pose": look(603, 2010, 1.72, 850, rx=4, ry=-6), "drift": 0.02,
             "lifts": [lift(CARD_NEXT, 1, 160, True), lift(CARD_SPEED, 2.5, 110)], "stickers": [note("官方到站時間", 700, 330, 1.4, tilt=3)]},
            {"line": 3, "from": 4.5, "enter": "flip", "screen": S["stationA"], "pose": {"x": -20, "y": 300, "s": 1.75, "rx": 5, "ry": 8}, "drift": 0.04,
             "lifts": [lift([366, 812, 842, 1086], 1.5, 150, True)], "stickers": [note("點站牌也看得到", 560, 1180, 2.2, tone="paper", tilt=-2)]},
        ],
    },
    {
        "id": "ep2", "label": "#2 怎麼去最快", "theme": "mist", "title": "搭公車、捷運\n**還是騎車**？", **END,
        "lines": [
            {"text": "搭公車、捷運，\n**還是騎車**？", "say": "[curious] 搭公車、捷運，還是騎車？", "beats": 8, "cues": [[0.2, "pop"]]},
            {"text": "輸入目的地，\n**幾種走法一起比**。", "say": "輸入目的地，幾種走法一起比。", "beats": 9, "cues": [[0, "whoosh"], [1.5, "pop"], [3, "pop"], [4, "pop"], [5, "chime"]]},
            {"text": "走路、等車都算進去，\n**幾點到直接寫給你**。", "say": "走路、等車都算進去，幾點到直接寫給你。", "beats": 10, "cues": [[0, "whoosh"], [1, "pop"], [3.5, "pop"]]},
            {"text": "看完步驟，\n**按出發才開始帶路**。", "say": "看完步驟，按出發才開始帶路。", "beats": 10, "cues": [[1, "tap"], [1.5, "whoosh"], [5, "pop"], [7, "tap"], [7.2, "chime"]]},
        ],
        "shots": [
            {"line": 0, "screen": S["compare"], "pose": whole(ry=10, rz=-2, x=-10), "drift": 0.04},
            {"line": 1, "screen": S["compare"], "pose": look(603, 2130, 1.8, 1000, ry=-7), "drift": 0.03,
             "lifts": [lift(CMP_BEST, 1.5, 150, True, out=5), lift(CMP_ALT1, 3, 120, out=7), lift(CMP_ALT2, 4, 120, out=7)],
             "stickers": [note("公車・捷運・YouBike", 540, 470, 5, tilt=-2, size=46)]},
            {"line": 2, "screen": S["compare"], "pose": look(520, 2010, 2.1, 960, ry=8, rx=3), "drift": 0.03,
             "lifts": [lift(CMP_TIME, 1, 150, True), lift(CMP_MODES, 3.5, 120)],
             "stickers": [note("整趟時間", 790, 620, 1.5, tilt=3, sub="含走路與等車")]},
            {"line": 3, "screen": S["compare"], "pose": look(900, 2100, 2.1, 960, ry=-8), "drift": 0.02,
             "taps": [{"x": CMP_STEPS[0], "y": CMP_STEPS[1], "at": 1}], "swaps": [{"at": 1.5, "screen": S["steps"], "how": "slide"}]},
            {"line": 3, "from": 3.4, "screen": S["steps"], "pose": look(603, 1960, 1.55, 760, ry=6), "drift": 0.03,
             "lifts": [lift(STEP_GO, 1.6, 160, True)], "taps": [{"x": 603, "y": 2430, "at": 3.6}],
             "stickers": [note("按了才開始導航", 800, 950, 2, tone="go", tilt=-2)]},
        ],
    },
    {
        "id": "ep3", "label": "#3 每一步先看清楚", "theme": "sand", "title": "轉車最怕\n**坐過站**？", **END,
        "lines": [
            {"text": "轉車最怕\n**坐過站**？", "say": "[worried] 轉車最怕坐過站？", "beats": 7, "cues": [[0.2, "pop"]]},
            {"text": "出發前，\n**整趟先看一遍**。", "say": "出發前，整趟先看一遍。", "beats": 8, "cues": [[0, "whoosh"], [1, "pop"], [3, "pop"]]},
            {"text": "哪裡上車、坐幾站、\n**哪裡下車**。", "say": "哪裡上車、坐幾站、哪裡下車。", "beats": 10, "cues": [[1, "pop"], [2, "chime"], [5, "whoosh"], [5.8, "pop"]]},
            {"text": "走到站牌，\n**App 裡直接帶你走**。", "say": "走到站牌，App 裡直接帶你走。", "beats": 10, "cues": [[0, "flip"], [1.5, "pop"], [5, "whoosh"], [5.8, "pop"], [6.4, "chime"]]},
        ],
        "shots": [
            {"line": 0, "screen": S["steps"], "pose": whole(), "drift": 0.04},
            {"line": 1, "screen": S["steps"], "pose": look(603, 760, 1.66, 780, ry=8), "drift": 0.03,
             "lifts": [lift(STEP_HEAD, 1, 140, True, out=4.5), lift(STEP_BIKE, 3, 130)]},
            {"line": 2, "screen": S["steps"], "pose": look(603, 1556, 1.68, 800, ry=-7), "drift": 0.02,
             "lifts": [lift(STEP_METRO, 1, 150, True)], "stickers": [note("坐幾站都寫好", 800, 1010, 2, tilt=3)]},
            {"line": 2, "from": 5, "screen": S["steps"], "pose": look(603, 2080, 1.68, 780, ry=6), "drift": 0.02,
             "lifts": [lift(STEP_WALK, 0.8, 140, True), lift(STEP_ARRIVE, 1.8, 120)], "stickers": [note("出站後怎麼走", 800, 590, 1.6, tone="paper", tilt=3)]},
            {"line": 3, "enter": "flip", "screen": S["walk"], "pose": look(603, 420, 1.75, 620, ry=-7), "drift": 0.03,
             "lifts": [lift(WALK_BANNER, 1.5, 150, True)], "stickers": [note("步行導航", 300, 1130, 2.4, tilt=-3)]},
            {"line": 3, "from": 5, "screen": S["walk"], "pose": look(603, 2000, 1.75, 800, ry=7), "drift": 0.03,
             "lifts": [lift(WALK_ROUTE, 0.6, 90), lift(WALK_CARD, 0.8, 150, True)]},
        ],
    },
    {
        "id": "ep4", "label": "#4 這班車趕不趕得上", "theme": "slate", "title": "這班車\n**要不要用跑的**？", **END,
        "lines": [
            {"text": "這班車，\n**要不要用跑的**？", "say": "[rushed] 這班車，要不要用跑的？", "beats": 8, "cues": [[0.2, "pop"]]},
            {"text": "車還有幾分鐘，\n**點站牌就知道**。", "say": "車還有幾分鐘，點站牌就知道。", "beats": 9, "cues": [[0, "whoosh"], [1, "tap"], [1.6, "pop"], [3, "chime"]]},
            {"text": "走過去要多久，\n**地圖上直接帶路**。", "say": "走過去要多久，地圖上直接帶路。", "beats": 10, "cues": [[0, "flip"], [1.5, "pop"], [4.5, "whoosh"], [5.3, "pop"]]},
            {"text": "趕不趕得上，\n**出門前就知道**。", "say": "趕不趕得上，出門前就知道。", "beats": 9, "cues": [[0, "whoosh"], [2, "pop"], [3.5, "tap"], [4, "chime"]]},
        ],
        "shots": [
            {"line": 0, "screen": S["station"], "pose": whole(y=700, ry=10, rz=-2, x=-10), "drift": 0.04,
             "pulses": [{"x": STATION_DOT[0], "y": STATION_DOT[1], "at": 2}]},
            {"line": 1, "screen": S["station"], "pose": look(700, 980, 2.1, 760, ry=-7), "drift": 0.04,
             "pulses": [{"x": STATION_DOT[0], "y": STATION_DOT[1], "at": 0.2, "until": 1}], "taps": [{"x": STATION_DOT[0], "y": STATION_DOT[1], "at": 1}],
             "lifts": [lift(STATION_TAG, 1.6, 150, True)], "stickers": [note("官方到站時間", 380, 1130, 3, tilt=-3)]},
            {"line": 2, "enter": "flip", "screen": S["walk"], "pose": look(603, 1100, 1.75, 760, ry=7), "drift": 0.03,
             "lifts": [lift(WALK_ROUTE, 1.5, 120, True)], "stickers": [note("走這條", 300, 420, 2.2, tone="paper", tilt=-4)]},
            {"line": 2, "from": 4.5, "screen": S["walk"], "pose": look(603, 2230, 1.78, 900, ry=-6), "drift": 0.03,
             "lifts": [lift(WALK_TIME, 0.8, 150, True)], "stickers": [note("4 分鐘走得到", 760, 520, 1.4, tilt=3)]},
            {"line": 3, "screen": S["walk"], "pose": look(603, 2300, 1.5, 1050, rx=5, ry=6), "drift": 0.02,
             "lifts": [lift(WALK_DONE, 2, 150, True)], "taps": [{"x": 870, "y": 2390, "at": 3.5}],
             "stickers": [note("趕得上", 300, 620, 4, tone="go", tilt=-4, size=58)]},
        ],
    },
    {
        "id": "ep5", "label": "#5 最後一段路", "theme": "moss", "title": "走到捷運站\n**還要十五分鐘**？", **END,
        "lines": [
            {"text": "走到捷運站，\n**還要十五分鐘**？", "say": "[tired] 走到捷運站，還要十五分鐘？", "beats": 8, "cues": [[0.2, "pop"]]},
            {"text": "規劃路線時，\n**YouBike 一起排進去**。", "say": "規劃路線時，YouBike 一起排進去。", "beats": 9, "cues": [[0, "whoosh"], [1.5, "pop"], [3.5, "pop"], [4, "chime"]]},
            {"text": "借車站有幾輛、\n**還車站有幾格**。", "say": "借車站有幾輛、還車站有幾格。", "beats": 10, "cues": [[1, "tap"], [1.5, "whoosh"], [4.4, "pop"], [5.8, "pop"], [6.2, "chime"]]},
            {"text": "有車、有位，\n**它才會這樣排**。", "say": "有車、有位，它才會這樣排。", "beats": 9, "cues": [[0, "whoosh"], [1, "pop"], [2.5, "stamp"], [5, "pop"]]},
        ],
        "shots": [
            {"line": 0, "screen": S["compare"], "pose": whole(ry=10, rz=-2, x=-10), "drift": 0.04},
            {"line": 1, "screen": S["compare"], "pose": look(603, 2100, 1.85, 980, ry=-7), "drift": 0.03,
             "lifts": [lift(CMP_BEST, 1.5, 150, True), lift(CMP_ALT2, 3.5, 120)],
             "stickers": [note("YouBike 接駁", 760, 480, 2, tilt=3)]},
            {"line": 2, "screen": S["compare"], "pose": look(900, 2100, 2.1, 960, ry=8), "drift": 0.02,
             "taps": [{"x": CMP_STEPS[0], "y": CMP_STEPS[1], "at": 1}], "swaps": [{"at": 1.5, "screen": S["steps"], "how": "slide"}]},
            {"line": 2, "from": 3.4, "screen": S["steps"], "pose": look(580, 950, 2.05, 780, ry=-6), "drift": 0.03,
             "lifts": [lift(BIKE_PICKUP, 1, 160, True), lift(BIKE_RETURN, 2.4, 160, True)],
             "stickers": [note("即時車位", 780, 1130, 3, tilt=3)]},
            {"line": 3, "screen": S["steps"], "pose": look(603, 1000, 1.7, 760, ry=7), "drift": 0.03,
             "lifts": [lift(STEP_BIKE, 1, 140, True)],
             "stickers": [note("有車有位才提出", 540, 300, 2.5, tone="go", tilt=-2), note("數量以現場為準", 800, 990, 5, tone="paper", tilt=2, size=40)]},
        ],
    },
    {
        "id": "ep6", "label": "#6 找路線、找站牌", "theme": "sand", "title": "找一班公車\n**還在慢慢打字**？", **END,
        "lines": [
            {"text": "找一班公車，\n**還在慢慢打字**？", "say": "[teasing] 找一班公車，還在慢慢打字？", "beats": 8, "cues": [[0.2, "pop"]]},
            {"text": "紅、藍、棕、綠，\n**按一下就帶入**。", "say": "紅、藍、棕、綠，按一下就帶入。", "beats": 9, "cues": [[0, "whoosh"], [1.5, "tap"], [3, "tap"], [4.5, "tap"]]},
            {"text": "路線馬上出來，\n**起訖站寫清楚**。", "say": "路線馬上出來，起訖站寫清楚。", "beats": 9, "cues": [[0, "whoosh"], [1, "pop"], [2.5, "pop"], [3, "chime"]]},
            {"text": "附近的站牌，\n**打開就在首頁**。", "say": "附近的站牌，打開就在首頁。", "beats": 9, "cues": [[0, "flip"], [1.5, "pop"], [2.5, "pop"], [4, "pop"]]},
        ],
        "shots": [
            {"line": 0, "screen": S["keypad"], "pose": whole(), "drift": 0.04},
            {"line": 1, "screen": S["keypad"], "pose": look(603, 2200, 1.5, 1010, ry=-6), "drift": 0.02,
             "taps": [{"x": 374, "y": 1988, "at": 1.5}, {"x": 832, "y": 1988, "at": 3}, {"x": 602, "y": 2290, "at": 4.5}],
             "lifts": [lift(KEY_BLUE, 1.5, 150, True, out=2.8), lift(KEY_2, 3, 150, True, out=4.3), lift(KEY_7, 4.5, 150, True, out=5.8)],
             "stickers": [note("藍", 330, 470, 1.7, tone="night", tilt=-5, size=120), note("2", 560, 450, 3.2, tone="night", tilt=3, size=120), note("7", 770, 480, 4.7, tone="night", tilt=-2, size=120)]},
            {"line": 2, "screen": S["keypad"], "pose": look(603, 600, 1.78, 780, ry=7), "drift": 0.03,
             "lifts": [lift(PAD_FIELD, 1, 120), lift(PAD_RESULT, 2.5, 160, True)], "stickers": [note("起點 → 終點", 810, 980, 3, tilt=3)]},
            {"line": 3, "enter": "flip", "screen": S["home"], "pose": look(603, 2300, 1.78, 860, ry=-7), "drift": 0.03,
             "lifts": [lift(HOME_STOP1, 1.5, 150, True), lift(HOME_STOP2, 2.5, 150, True), lift(HOME_SEARCH, 4, 120)],
             "stickers": [note("最近的兩個站牌", 540, 330, 3, tilt=-2)]},
        ],
    },
    {
        "id": "ep7", "label": "#7 打開就能用", "theme": "slate", "title": "查個公車\n**還要先看廣告**？", **END,
        "lines": [
            {"text": "查個公車，\n**還要先看廣告**？", "say": "[annoyed] 查個公車，還要先看廣告？", "beats": 8, "cues": [[0.2, "pop"]]},
            {"text": "一路沒有廣告，\n**也不用登入**。", "say": "一路沒有廣告，也不用登入。", "beats": 9, "cues": [[0, "whoosh"], [1.5, "stamp"], [3, "stamp"], [4.5, "pop"]]},
            {"text": "規劃、導航、到站時間，\n**全部免費**。", "say": "規劃、導航、到站時間，全部免費。", "beats": 11, "cues": [[0, "flip"], [1, "pop"], [3.4, "flip"], [4.4, "pop"], [6.8, "flip"], [7.8, "pop"], [8.4, "chime"]]},
            {"text": "台北、新北，\n**打開就看得到**。", "say": "台北、新北，打開就看得到。", "beats": 9, "cues": [[0, "flip"], [2, "stamp"], [3.5, "pop"]]},
        ],
        "shots": [
            {"line": 0, "screen": S["station"], "pose": whole(ry=10, rz=-2, x=-10), "drift": 0.04},
            {"line": 1, "screen": S["home"], "pose": look(603, 1900, 1.7, 740, ry=-6), "drift": 0.03,
             "lifts": [lift(HOME_SEARCH, 4.5, 150, True)],
             "stickers": [note("沒有廣告", 320, 400, 1.5, tilt=-5, size=64), note("不用登入", 760, 560, 3, tone="paper", tilt=4, size=64)]},
            {"line": 2, "enter": "flip", "screen": S["compare"], "pose": look(603, 2040, 1.75, 800, ry=7), "drift": 0.02,
             "lifts": [lift(CMP_BEST, 1, 150, True)], "stickers": [note("路線規劃", 760, 340, 1.1, tilt=3)]},
            {"line": 2, "from": 3.4, "enter": "flip", "screen": S["walk"], "pose": look(603, 420, 1.75, 640, ry=-7), "drift": 0.02,
             "lifts": [lift(WALK_BANNER, 1, 150, True)], "stickers": [note("導航", 300, 1100, 1.1, tilt=-4)]},
            {"line": 2, "from": 6.8, "enter": "flip", "screen": S["busCard"], "pose": look(603, 2010, 1.7, 850, rx=4, ry=6), "drift": 0.02,
             "lifts": [lift(CARD_NEXT, 1, 160, True)], "stickers": [note("到站時間", 720, 330, 1.1, tilt=3), note("全部免費", 330, 1120, 1.8, tone="go", tilt=-4, size=60)]},
            {"line": 3, "enter": "flip", "screen": S["home"], "pose": {"x": 0, "y": -530, "s": 1.5, "rx": 6, "ry": -8}, "drift": 0.03,
             "lifts": [lift(HOME_STOP1, 3.5, 140), lift(HOME_STOP2, 3.9, 140)], "stickers": [note("台北＋新北", 540, 360, 2, tilt=-3, size=64)]},
        ],
    },
    {
        "id": "launch", "label": "全新改版", "theme": "night", "title": "一路 1.9\n**全新上線**",
        "endLine": "公車、捷運、YouBike，一路接到底", "outro": "App Store 免費下載", "outroSay": "今天出門，就用一路。", "liftFrom": 1, "endBeats": 9,
        "lines": [
            {"text": "一路，\n**全新上線**。", "say": "[excited] 一路，全新上線！", "beats": 6, "cues": [[0.2, "pop"], [1.5, "chime"]]},
            {"text": "看公車、比路線、看步驟、\n走到站牌、查路線，\n**全都在這**。", "say": "看公車、比路線、看步驟、走到站牌、查路線，全都在這。", "beats": 16,
             "cues": [[0, "whoosh"], [1, "pop"], [2.6, "flip"], [3.6, "pop"], [5.2, "flip"], [6.2, "pop"], [7.8, "flip"], [8.8, "pop"], [10.4, "flip"], [11.4, "pop"], [13, "whoosh"], [13.6, "chime"]]},
            {"text": "台北、新北，\n**一路接到底**。", "say": "台北、新北，一路接到底。", "beats": 8, "cues": [[0, "flip"], [1.5, "pop"], [3, "stamp"]]},
            {"text": "沒有廣告、不用登入。\n**App Store 免費下載**。", "say": "沒有廣告、不用登入。App Store 免費下載。", "beats": 10, "cues": [[0, "flip"], [1.2, "stamp"], [2.6, "stamp"], [5, "chime"]]},
        ],
        "shots": [
            {"line": 0, "screen": S["bus"], "pose": whole(y=720), "drift": 0.04, "pulses": [{"x": BUS_AT[0], "y": BUS_AT[1], "at": 1.5}]},
            {"line": 1, "screen": S["bus"], "pose": {"x": -70, "y": -120, "s": 1.75, "rx": 6, "ry": 9, "rz": -1}, "drift": 0.02,
             "lifts": [lift(BUS_TAG, 1, 150, True)], "stickers": [note("看公車", 320, 520, 1.1, tilt=-4, size=58)]},
            {"line": 1, "from": 2.6, "enter": "flip", "screen": S["compare"], "pose": look(603, 2040, 1.75, 800, ry=-7), "drift": 0.02,
             "lifts": [lift(CMP_BEST, 1, 150, True)], "stickers": [note("比路線", 760, 340, 1.1, tilt=3, size=58)]},
            {"line": 1, "from": 5.2, "enter": "flip", "screen": S["steps"], "pose": look(603, 1556, 1.8, 800, ry=7), "drift": 0.02,
             "lifts": [lift(STEP_METRO, 1, 150, True)], "stickers": [note("看步驟", 790, 1030, 1.1, tilt=3, size=58)]},
            {"line": 1, "from": 7.8, "enter": "flip", "screen": S["walk"], "pose": look(603, 420, 1.75, 640, ry=-7), "drift": 0.02,
             "lifts": [lift(WALK_BANNER, 1, 150, True)], "stickers": [note("走到站牌", 760, 1100, 1.1, tilt=3, size=58)]},
            {"line": 1, "from": 10.4, "enter": "flip", "screen": S["keypad"], "pose": look(603, 600, 1.78, 640, ry=7), "drift": 0.02,
             "lifts": [lift(PAD_RESULT, 1, 160, True)], "stickers": [note("查路線", 320, 1050, 1.1, tilt=-4, size=58)]},
            {"line": 1, "from": 13, "enter": "flip", "screen": S["station"], "pose": {"x": 0, "y": -40, "s": 0.92, "rx": 6, "ry": -10}, "drift": 0.02,
             "stickers": [note("看公車", 190, 400, 0.4, tilt=-6, size=46), note("比路線", 900, 480, 0.6, tilt=5, size=46), note("看步驟", 170, 760, 0.8, tone="paper", tilt=4, size=46),
                          note("走到站牌", 910, 860, 1.0, tone="paper", tilt=-4, size=46), note("查路線", 200, 1110, 1.2, tilt=-3, size=46)]},
            {"line": 2, "enter": "flip", "screen": S["compare"], "pose": {"x": 0, "y": -60, "s": 0.86, "rx": 6, "ry": 8}, "drift": 0.03,
             "lifts": [lift(CMP_MODES, 1.5, 150, True)],
             "stickers": [note("公車＋捷運＋YouBike＋步行", 540, 452, 3, tilt=-2, size=44)]},
            {"line": 3, "enter": "flip", "screen": S["bus"], "pose": {"x": 0, "y": 40, "s": 1.0, "rx": 8, "ry": 10}, "drift": -0.06,
             "pulses": [{"x": BUS_AT[0], "y": BUS_AT[1], "at": 1.5}],
             "stickers": [note("沒有廣告", 250, 470, 1.2, tilt=-6, size=66), note("不用登入", 830, 620, 2.6, tone="paper", tilt=5, size=66), note("免費下載", 540, 1170, 5, tone="go", tilt=-2, size=70)]},
        ],
    },
    {
        # The App Store's own app preview: real screen recordings with captions, cut in src/StorePreview.tsx.
        # Only its lines, voice and music come from here; the footage and cuts are in src/preview.json.
        "id": "store", "kind": "preview", "label": "App Store 預覽", "theme": "night", "title": "", "shots": [],
        "endLine": "公車、捷運、YouBike，一路接到底", "outro": "", "outroSay": "一路，出門前看一眼。", "outroAt": 0.9, "liftFrom": 1, "endBeats": 7,
        "lines": [
            {"text": "公車到哪了？\n**地圖上直接看**", "say": "公車到哪了？地圖上直接看。", "beats": 8, "cues": [[0.3, "whoosh"]]},
            {"text": "點一下那輛車，\n**開到哪、開多快都知道**", "say": "點一下那輛車，開到哪、開多快都知道。", "beats": 9, "cues": [[2.14, "tap"], [3.1, "pop"]]},
            {"text": "輸入目的地，\n**幾種走法一起比**", "say": "輸入目的地，公車、捷運、YouBike 一起比。", "beats": 10,
             "cues": [[0, "whoosh"], [3.42, "tap"], [4.0, "whoosh"], [7.2, "chime"], [9.36, "tap"]]},
            {"text": "坐幾站、哪裡下車，\n**出發前先看清楚**", "say": "坐幾站、哪裡下車，出發前先看清楚。", "beats": 9, "cues": [[0, "whoosh"]]},
            {"text": "點站牌看到站時間，\n**再帶你走過去**", "say": "點站牌看到站時間，再帶你走過去。", "beats": 10,
             "cues": [[0, "whoosh"], [0.66, "tap"], [1.4, "pop"], [3.0, "tap"], [3.8, "whoosh"], [7, "chime"]]},
        ],
    },
]

VOICE = {"voiceId": "fQj4gJSexpu8RDE2Ii5m", "model": "eleven_v4", "language": "zh"}

if __name__ == "__main__":
    out = ROOT / "src" / "episodes.json"
    out.write_text(json.dumps({"voice": VOICE, "episodes": EPISODES}, ensure_ascii=False, indent=1) + "\n")
    print(f"{len(EPISODES)} films -> {out.relative_to(ROOT)}")
