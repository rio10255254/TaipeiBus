#!/usr/bin/env python3
"""Cut the store preview's footage out of the simulator recordings.

    python3 scripts/make-preview-clips.py <folder with preview-testPreviewReel*.mp4> [clip names]

The recordings come from the `app-store-preview` scope of .github/workflows/ios.yml (four paced
walkthroughs of the real app on a 6.9-inch simulator; times below are seconds into each file, read
off the PREVIEW_MARK lines in its log).

A hosted simulator draws in bursts, and the app itself hitches on it: frames a few milliseconds
apart, then nothing moving for a tenth of a second or more. Played as recorded that stutters,
however it is cut. So the walkthroughs make every turn, zoom and scroll at a quarter of the speed
it should have, and here each clip is played that much faster, which closes most of the gaps. The
frames in which nothing moved are then dropped, and the gaps they leave are filled with frames
estimated from the motion on either side (ffmpeg's motion-compensated interpolation), placed by the
recording's own timestamps. The last column printed is the share of frames that still repeat the
one before: on a moving clip it should be near zero. Clips are written to public/preview/ a quarter
larger than the App Store's 886 x 1920, so the edit's camera can close in without softening.
"""
import re
from concurrent.futures import ThreadPoolExecutor
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "public" / "preview"
LEAD = 0.3  # seconds kept before each clip's first second, for the shot to arrive on (src/StorePreview.tsx)

# name: (recording, first second, last second, speed). The recordings are two runs of the same
# walkthroughs on 21 November 2026: `day` at their natural pace (Actions run 44874816397), where the
# bus's tag and card were caught, and `slow` with quarter-speed gestures (run 44878895138).
CLIPS = {
    # One take: the map turning around a bus in service, then a tap on it and its card.
    "bus": ("day/testPreviewReel1LiveBus", 173.5, 190.6, 1.8),
    "search": ("slow/testPreviewReel2PlanTrip", 64.0, 76.5, 4.5),
    "choices": ("slow/testPreviewReel2PlanTrip", 100.4, 117.6, 4.0),
    "steps": ("slow/testPreviewReel2PlanTrip", 148.5, 168.4, 4.0),
    "stop": ("slow/testPreviewReel3StationWalk", 133.6, 138.4, 2.0),
    "walk": ("slow/testPreviewReel3StationWalk", 154.9, 181.0, 6.5),
}


def repeats(path):
    """The share of frames that show the same picture as the one before."""
    log = subprocess.run(["ffmpeg", "-v", "info", "-i", str(path), "-vf",
        "scale=277:-1,tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-an", "-f", "null", "-"],
        capture_output=True, text=True).stderr
    change = [float(v) for v in re.findall(r"YAVG=([0-9.]+)", log)][1:]
    return sum(1 for v in change if v < 0.05) / max(1, len(change))


def cut(source, name):
    reel, first, last, speed = CLIPS[name]
    folder, reel = reel.split("/")
    first -= LEAD * speed
    out = OUT / f"{name}.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{first:.3f}", "-to", f"{last:.3f}", "-i", str(source / folder / f"preview-{reel}.mp4"),
        # Frames in which nothing moved are the app itself hitching on the hosted machine. They go first,
        # so that what is estimated across each hitch is the motion, not a copy of the frame before it.
        "-vf", f"mpdecimate,setpts=(PTS-STARTPTS)/{speed},scale=1108:-2:flags=lanczos,crop=1108:2400,"
               "minterpolate=fps=30:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1:scd=none:search_param=64,format=yuv420p",
        "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-g", "15", "-movflags", "+faststart", str(out)], check=True)
    seconds = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(out)]))
    return f"{name}: {seconds:.2f} s, {out.stat().st_size // 1024} KB, {repeats(out) * 100:.0f}% repeated frames"


def main():
    source = Path(sys.argv[1])  # holds day/ and slow/, each with that run's preview-*.mp4
    names = [name for name in CLIPS if not sys.argv[2:] or name in sys.argv[2:]]
    OUT.mkdir(parents=True, exist_ok=True)
    # Estimating motion is slow and single-threaded, so the clips are cut side by side.
    with ThreadPoolExecutor(max_workers=4) as pool:
        for line in pool.map(lambda name: cut(source, name), names):
            print(line, flush=True)


if __name__ == "__main__":
    main()
