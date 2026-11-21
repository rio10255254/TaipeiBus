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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scroll_clip import even_clip, scroll_clip  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "public" / "preview"
LEAD = 0.3  # seconds kept before each clip's first second, for the shot to arrive on (src/StorePreview.tsx)

# name: (recording, first second, last second, speed). The recordings are two runs of the same
# walkthroughs on 21 November 2026: `day` at their natural pace (Actions run 44874816397), where the
# bus's tag and card were caught, and `slow` with quarter-speed gestures (run 44878895138).
CLIPS = {
    # One take in two parts, cut where the picture is still: the map turning around a bus in service,
    # laid out again to move evenly for the given number of seconds (the word in place of a speed),
    # then the tap on it and its card.
    "orbit": ("day/testPreviewReel1LiveBus", 173.5, 181.0, "even", 3.9),
    # The recorder missed most of a second while the card came up and the map turned to make room for
    # it. Nothing can be estimated across that much change, so the take stops before it and picks up
    # after, and the edit dissolves between the two.
    "card": ("day/testPreviewReel1LiveBus", 181.0, 184.38, 1.8),
    "card-up": ("day/testPreviewReel1LiveBus", 187.7, 193.0, 1.6),
    # The trip is one run from typing to itinerary, so its times and its route agree from shot to shot.
    "search": ("day/testPreviewReel2PlanTrip", 66.1, 70.2, 1.6),
    "choices": ("day/testPreviewReel2PlanTrip", 105.3, 115.6, 2.6),
    # A list being dragged is laid out again by how far it has moved, not by time, and its speed is
    # ignored (scripts/scroll_clip.py). The last two numbers are the rows of the clip between the
    # sheet's title bar and its button.
    "steps": ("day/testPreviewReel2PlanTrip", 138.5, 150.0, 1.0, 340, 2150),
    "stop": ("slow/testPreviewReel3StationWalk", 137.2, 141.6, 1.5),
    "walk": ("slow/testPreviewReel3StationWalk", 155.2, 181.0, "even", 3.4),
}


def repeats(path):
    """The share of frames that show the same picture as the one before."""
    log = subprocess.run(["ffmpeg", "-v", "info", "-i", str(path), "-vf",
        "scale=277:-1,tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-an", "-f", "null", "-"],
        capture_output=True, text=True).stderr
    change = [float(v) for v in re.findall(r"YAVG=([0-9.]+)", log)][1:]
    return sum(1 for v in change if v < 0.05) / max(1, len(change))


def cut(source, name):
    reel, first, last, speed, *list_rows = CLIPS[name]
    folder, reel = reel.split("/")
    out = OUT / f"{name}.mp4"
    if speed == "even":
        even_clip(source / folder / f"preview-{reel}.mp4", out, first, last, *list_rows)
        seconds = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(out)]))
        return f"{name}: {seconds:.2f} s, {out.stat().st_size // 1024} KB, {repeats(out) * 100:.0f}% repeated frames"
    first -= LEAD * speed
    if list_rows:
        scroll_clip(source / folder / f"preview-{reel}.mp4", out, first + LEAD * speed, last, *list_rows)
        seconds = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(out)]))
        return f"{name}: {seconds:.2f} s, {out.stat().st_size // 1024} KB, {repeats(out) * 100:.0f}% repeated frames"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{first:.3f}", "-to", f"{last:.3f}", "-i", str(source / folder / f"preview-{reel}.mp4"),
        # Frames in which nothing moved are the app itself hitching on the hosted machine. They go first,
        # so that what is estimated across each hitch is the motion, not a copy of the frame before it.
        "-vf", f"mpdecimate,setpts=(PTS-STARTPTS)/{speed},scale=1108:-2:flags=lanczos,crop=1108:2400,"
               "minterpolate=fps=30:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1:scd=none:search_param=64,"
               # A clip that ends on a still screen ends at its last moving frame; hold that frame for the edit to leave on.
               "tpad=stop_mode=clone:stop_duration=1.5,format=yuv420p",
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
