#!/usr/bin/env python3
"""Cut the store preview's footage out of the simulator recordings.

    python3 scripts/make-preview-clips.py <folder with preview-testPreviewReel*.mp4>

The recordings come from the `app-store-preview` scope of .github/workflows/ios.yml (four paced
walkthroughs of the real app on a 6.9-inch simulator; times below are seconds into each file, read
off the PREVIEW_MARK lines in its log). The simulator's recorder only writes a frame when the
picture changes, and a hosted simulator draws a moving map at ten to forty frames a second, so each
clip is taken from a stretch where the picture is really moving and played a little faster, enough
to reach a steady 30. Frames are repeated while the screen is still, never blended. Clips are
written to public/preview/ a quarter larger than the App Store's 886 x 1920, so the edit's camera
can push in without softening.
"""
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


def main():
    source = Path(sys.argv[1])
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (reel, first, last, speed) in CLIPS.items():
        first -= LEAD * speed
        out = OUT / f"{name}.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{first:.3f}", "-to", f"{last:.3f}", "-i", str(source / f"preview-{reel}.mp4"),
            "-vf", f"setpts=(PTS-STARTPTS)/{speed},fps=30,scale=1108:-2:flags=lanczos,crop=1108:2400,format=yuv420p",
            "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-g", "15", "-movflags", "+faststart", str(out)], check=True)
        seconds = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(out)]))
        print(f"{name}: {seconds:.2f} s, {out.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
