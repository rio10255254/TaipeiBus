#!/usr/bin/env python3
"""Cut the store preview's footage out of the simulator recordings.

    python3 scripts/make-preview-clips.py <folder with preview-testPreviewReel*.mp4>

The recordings come from the `app-store-preview` scope of .github/workflows/ios.yml (four paced
walkthroughs of the real app on a 6.9-inch simulator; times below are seconds into each file, read
off the PREVIEW_MARK lines in its log). A hosted simulator only draws four to eight frames a second,
so each clip is played faster than it was recorded and its frames are blended up to a steady 30.
Clips are written to public/preview/ at the App Store's preview size, 886 x 1920.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "public" / "preview"
LEAD = 0.3  # seconds of each clip shown under the fade from the one before (src/StorePreview.tsx)

# name: (recording, first second, last second, speed)
CLIPS = {
    # The bus was waiting at a stop for the whole hold, so the opening is the camera flying to it instead.
    "bus-fly": ("testPreviewReel1LiveBus", 111.2, 119.6, 1.8),
    "bus-details": ("testPreviewReel1LiveBus", 133.2, 143.5, 2.2),
    "home-search": ("testPreviewReel2PlanTrip", 76.0, 77.6, 1.0),
    "trip-choices": ("testPreviewReel2PlanTrip", 176.0, 189.0, 3.0),
    "trip-steps": ("testPreviewReel2PlanTrip", 197.7, 211.8, 3.0),
    "stop-arrivals": ("testPreviewReel3StationWalk", 109.7, 116.3, 3.0),
    "stop-walk": ("testPreviewReel3StationWalk", 120.2, 130.6, 3.0),
    "route-map": ("testPreviewReel4RouteSearch", 127.6, 134.2, 1.6),
}


def main():
    source = Path(sys.argv[1])
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (reel, first, last, speed) in CLIPS.items():
        first -= LEAD * speed
        out = OUT / f"{name}.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{first:.3f}", "-to", f"{last:.3f}", "-i", str(source / f"preview-{reel}.mp4"),
            "-vf", f"setpts=(PTS-STARTPTS)/{speed},scale=886:1926:flags=lanczos,crop=886:1920:0:3,framerate=fps=30:interp_start=0:interp_end=255:scene=100,format=yuv420p",
            "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-g", "15", "-movflags", "+faststart", str(out)], check=True)
        seconds = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(out)]))
        print(f"{name}: {seconds:.2f} s, {out.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
