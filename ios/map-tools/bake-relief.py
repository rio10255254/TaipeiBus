"""Bake a Web-Mercator hillshade overlay for greater Taipei from AWS terrarium DEM tiles."""
# Usage: python3 bake-relief.py out.png out.json dem-cache-dir, then quantize to 128 colours
# (PIL Image.quantize(colors=128, method=FASTOCTREE)) and copy to TaipeiBus/hillshade-taipei.png.
import math, os, subprocess, sys, io, json
import numpy as np
from PIL import Image
out_png, out_json, cache = sys.argv[1], sys.argv[2], sys.argv[3]
WEST, EAST, SOUTH, NORTH = 120.95, 122.10, 24.55, 25.36
Z = 12
def tx(lon, z): return (lon + 180) / 360 * 2**z
def ty(lat, z): r = math.radians(lat); return (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * 2**z
x0, x1 = tx(WEST, Z), tx(EAST, Z); y0, y1 = ty(NORTH, Z), ty(SOUTH, Z)
xs, ys = range(int(x0), int(x1) + 1), range(int(y0), int(y1) + 1)
mosaic = np.zeros((len(ys) * 256, len(xs) * 256), dtype=np.float32)
for j, y in enumerate(ys):
    for i, x in enumerate(xs):
        path = os.path.join(cache, f"{Z}_{x}_{y}.png")
        if not os.path.exists(path):
            data = subprocess.run(["curl", "-sf", f"https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{Z}/{x}/{y}.png"], capture_output=True).stdout
            open(path, "wb").write(data)
        rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
        mosaic[j*256:(j+1)*256, i*256:(i+1)*256] = rgb[..., 0] * 256 + rgb[..., 1] + rgb[..., 2] / 256 - 32768
# Crop to the exact box (fractional tile coordinates).
cx0, cy0 = int((x0 - xs[0]) * 256), int((y0 - ys[0]) * 256)
cx1, cy1 = int((x1 - xs[0]) * 256), int((y1 - ys[0]) * 256)
elev = np.maximum(mosaic[cy0:cy1, cx0:cx1], 0)
# Pixel size in metres at this latitude (Mercator scale).
lat_mid = math.radians((NORTH + SOUTH) / 2)
pixel = 40075016.686 * math.cos(lat_mid) / (256 * 2**Z)
gy, gx = np.gradient(elev, pixel)
slope = np.arctan(1.6 * np.hypot(gx, gy))
aspect = np.arctan2(-gx, gy)
azimuth, altitude = math.radians(315), math.radians(45)
shade = math.sin(altitude) * np.cos(slope) + math.cos(altitude) * np.sin(slope) * np.cos(azimuth - math.pi / 2 - aspect)
flat = math.sin(altitude)
shadow = np.clip((flat - shade) / flat, 0, 1)
light = np.clip((shade - flat) / (1 - flat), 0, 1)
h, w = elev.shape
rgba = np.zeros((h, w, 4), dtype=np.float32)
# Shadows: muted green-grey; highlights: soft white. Alpha carries the strength.
sa = np.clip(shadow * 1.35, 0, 1) * 0.62
la = np.clip(light * 1.2, 0, 1) * 0.38
use_shadow = sa >= la
rgba[..., 0] = np.where(use_shadow, 52, 255); rgba[..., 1] = np.where(use_shadow, 66, 255); rgba[..., 2] = np.where(use_shadow, 54, 255)
rgba[..., 3] = np.where(use_shadow, sa, la) * 255
img = Image.fromarray(rgba.astype(np.uint8), "RGBA")
target_w = 2048
img = img.resize((target_w, round(h * target_w / w)), Image.LANCZOS)
img.save(out_png, optimize=True)
json.dump({"west": WEST, "east": EAST, "south": SOUTH, "north": NORTH, "width": img.width, "height": img.height}, open(out_json, "w"))
print(img.size, os.path.getsize(out_png))
