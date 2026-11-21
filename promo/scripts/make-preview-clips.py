#!/usr/bin/env python3
"""Cut the store preview's footage out of the simulator recordings.

    python3 scripts/make-preview-clips.py <folder with preview-testPreviewReel*.mp4> [clip names]

The recordings come from the `app-store-preview` scope of .github/workflows/ios.yml (four paced
walkthroughs of the real app on a 6.9-inch simulator; times below are seconds into each file, read
off the PREVIEW_MARK lines in its log).

A hosted simulator draws in bursts: frames a few milliseconds apart, then nothing for a tenth of a
second or more. Played as recorded that stutters, however it is cut. So the walkthroughs make every
turn, zoom and scroll at a quarter of the speed it should have, and here each clip is played that
much faster, which closes most of the gaps, and the few that are left are filled with frames
estimated from the motion on either side (ffmpeg's motion-compensated interpolation). The last
column printed is the share of frames that still repeat the one before: on a moving clip it should
be near zero. Clips are written to public/preview/ a quarter larger than the App Store's
886 x 1920, so the edit's camera can close in without softening.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "public" / "preview"
LEAD = 0.3  # seconds kept before each clip's first second, for the shot to arrive on (src/StorePreview.tsx)

# name: (recording, first second, last second, speed)
CLIPS = {
    # One take: the map turning around a bus in service, then a tap on it and its card.
    "bus": ("testPreviewReel1LiveBus", 173.5, 190.6, 1.8),
    "search": ("testPreviewReel2PlanTrip", 66.1, 70.2, 1.6),
    "choices": ("testPreviewReel2PlanTrip", 105.3, 115.6, 2.6),
    # The itinerary arriving, then its two scrolls; the still seconds between them are left out.
    "steps-1": ("testPreviewReel2PlanTrip", 135.9, 138.6, 1.3),
    "steps-2": ("testPreviewReel2PlanTrip", 141.8, 144.8, 1.3),
    "steps-3": ("testPreviewReel2PlanTrip", 148.0, 150.6, 1.3),
    "stop-1": ("testPreviewReel3StationWalk", 111.2, 113.8, 1.25),
    "stop-2": ("testPreviewReel3StationWalk", 118.3, 119.7, 1.0),
    "walk-1": ("testPreviewReel3StationWalk", 122.9, 125.4, 1.2),
    "walk-2": ("testPreviewReel3StationWalk", 129.9, 133.2, 1.6),
    "route": ("testPreviewReel4RouteSearch", 113.8, 119.2, 1.0),
}


def repeats(path):
    """The share of frames that show the same picture as the one before."""
    log = subprocess.run(["ffmpeg", "-v", "info", "-i", str(path), "-vf",
        "scale=277:-1,tblend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-an", "-f", "null", "-"],
        capture_output=True, text=True).stderr
    change = [float(v) for v in re.findall(r"YAVG=([0-9.]+)", log)][1:]
    return sum(1 for v in change if v < 0.05) / max(1, len(change))


def main():
    source = Path(sys.argv[1])
    wanted = sys.argv[2:]
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (reel, first, last, speed) in CLIPS.items():
        if wanted and name not in wanted:
            continue
        first -= LEAD * speed
        out = OUT / f"{name}.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{first:.3f}", "-to", f"{last:.3f}", "-i", str(source / f"preview-{reel}.mp4"),
            "-vf", f"setpts=(PTS-STARTPTS)/{speed},scale=1108:-2:flags=lanczos,crop=1108:2400,"
                   "minterpolate=fps=30:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1:scd=none,format=yuv420p",
            "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-g", "15", "-movflags", "+faststart", str(out)], check=True)
        seconds = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(out)]))
        print(f"{name}: {seconds:.2f} s, {out.stat().st_size // 1024} KB, {repeats(out) * 100:.0f}% repeated frames", flush=True)


if __name__ == "__main__":
    main()
