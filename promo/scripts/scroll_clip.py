"""A clip of a list being scrolled, made steady by where the list is rather than by when it was drawn.

On a hosted simulator the app moves a dragged list in lurches: a few rows over one stretch, two
hundred in the next tenth of a second. No interpolation in time can smooth that, and a general
interpolator smears text that scrolls past other text like it. But a list only moves one way. So
the distance it has travelled is measured in every recorded frame (the vertical shift that best
lays its rows over an earlier frame's), and the clip is laid out again along that distance: the
list eases from its first position to its last, and each output frame is the recorded frame nearest
that position with its rows moved the last few pixels. Rows that come into view are taken from the
next frame along. Nothing outside the list's rows is moved, and no pixel is invented.
"""
import re
import subprocess

import numpy as np

W, H = 1108, 2400


def _frames(source, first, last):
    """The recording's frames from `first` to `last`, one at a time."""
    # The recorder's last frames carry times that run backwards, and a cut near the end of a file lets
    # them in: anything that steps back in time is left out. Frames are then numbered rather than
    # timed, or those a few milliseconds apart would be merged on the way out.
    chain = f"select='isnan(prev_selected_t)+gte(t,prev_selected_t)',scale={W}:-2:flags=lanczos,crop={W}:{H},setpts=N/(25*TB)"
    pipe = subprocess.Popen(["ffmpeg", "-v", "error", "-ss", f"{first:.3f}", "-to", f"{last:.3f}", "-i", str(source),
        "-vf", chain, "-vsync", "vfr", "-an", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    while True:
        raw = pipe.stdout.read(W * H * 3)
        if len(raw) < W * H * 3:
            break
        yield np.frombuffer(raw, np.uint8).reshape(H, W, 3)
    pipe.stdout.close()
    pipe.wait()


def _grey(frame, top, bottom):
    return frame[top + 60:bottom - 60, ::5].astype(np.float32).mean(axis=2)


def _shift(ga, gb, reach=260):
    """How many rows the list moved up from one frame to another (negative when it moved back), and how well they then agree."""
    costs = {}
    for d in range(-reach, reach + 1):
        x, y = (ga[d:], gb[:len(gb) - d]) if d >= 0 else (ga[:d], gb[-d:])
        costs[d] = float(np.abs(x - y).mean())
    best = min(costs, key=costs.get)
    if best - 1 in costs and best + 1 in costs:
        lo, mid, hi = costs[best - 1], costs[best], costs[best + 1]
        bend = lo - 2 * mid + hi
        if bend > 1e-6:
            return best + 0.5 * (lo - hi) / bend, costs[best]
    return float(best), costs[best]


def positions(source, first, last, top, bottom):
    """How far the list has travelled in each frame, measured against a frame that is replaced before it gets far away."""
    out, anchor, anchor_at = [], None, 0.0
    for frame in _frames(source, first, last):
        grey = _grey(frame, top, bottom)
        if anchor is None:
            anchor = grey
        moved, _ = _shift(anchor, grey)
        out.append(anchor_at + moved)
        if abs(moved) > 120:
            anchor, anchor_at = grey, anchor_at + moved
    return out


def _moved(frame, rows, top, bottom):
    """The list's rows of a frame, moved up by `rows` (which need not be whole); rows from outside it are marked missing."""
    whole = int(np.floor(rows))
    part = rows - whole
    index = np.arange(top, bottom) + whole
    ok = (index >= top) & (index + 1 < bottom)
    index = np.clip(index, top, bottom - 2)
    out = frame[index].astype(np.float32) * (1 - part) + frame[index + 1].astype(np.float32) * part
    return out, ok


def _ease(k):
    """Away gently, steady through the middle, and a long settle, the way a dragged list comes to rest."""
    k = min(1.0, max(0.0, k))
    return k * k * (3 - 2 * k) * 0.35 + (1 - (1 - k) ** 3) * 0.65


def scroll_clip(source, out, first, last, top, bottom, still=0.8, travel=3.2, hold=1.5, fps=30):
    """Write `out`: `still` seconds on the list where it starts, `travel` seconds scrolling to where it ends, `hold` there."""
    where = positions(source, first, last, top, bottom)
    # A drag carries the list past its end and it springs back to rest. Only the frames on the way
    # out are used, up to that resting place: by the time it has settled the app may have refreshed
    # its live times, and a row that changed would not lie over the same row from a moment before.
    rest, furthest = where[-1], int(np.argmax(where))
    keep, at = [0], where[0]
    for i in range(furthest + 1):
        if at + 24 <= where[i] <= rest:
            keep.append(i)
            at = where[i]
    wanted, kept = set(keep), {}
    for i, frame in enumerate(_frames(source, first, last)):
        if i in wanted:
            kept[i] = frame.copy()
    # Measured once more, each chosen frame against the one before it: these are the pairs that get
    # laid over each other, so it is their own distance that has to be exact.
    for before, after in zip(keep, keep[1:]):
        step, _ = _shift(_grey(kept[before], top, bottom), _grey(kept[after], top, bottom))
        where[after] = where[before] + step
    end = where[keep[-1]]
    encode = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(fps), "-i", "-",
        "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-g", "15", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out)], stdin=subprocess.PIPE)
    total = int((still + travel + hold) * fps)
    for n in range(total):
        p = where[0] + (end - where[0]) * _ease((n / fps - still) / travel)
        j = max(1, next((m for m, i in enumerate(keep) if where[i] >= p), len(keep) - 1))
        a, b = kept[keep[j - 1]], kept[keep[j]]
        pa, pb = where[keep[j - 1]], where[keep[j]]
        k = min(1.0, max(0.0, (p - pa) / max(1e-6, pb - pa)))
        frame = a.astype(np.float32) * (1 - k) + b.astype(np.float32) * k
        from_a, in_a = _moved(a, p - pa, top, bottom)
        from_b, in_b = _moved(b, p - pb, top, bottom)
        both = (in_a & in_b)[:, None, None]
        frame[top:bottom] = np.where(both, from_a * (1 - k) + from_b * k, np.where(in_a[:, None, None], from_a, from_b))
        encode.stdin.write(np.clip(frame + 0.5, 0, 255).astype(np.uint8).tobytes())
    encode.stdin.close()
    encode.wait()
    return where


def even_clip(source, out, first, last, seconds, hold=1.0, fps=30):
    """Write `out`: a camera move from `first` to `last`, laid out again so that it moves evenly for `seconds`.

    The same trouble as the list, for a map that is turning: the app draws it in lurches. Each recorded
    frame is given a new time by how much of the whole move has happened by then (the picture's change
    from frame to frame, added up), easing to a stop, and the frames in between are then estimated from
    the motion around them. A stall gets no time at all and a lurch gets the time it should have taken.
    """
    frames, small = [], []
    for frame in _frames(source, first, last):
        grey = frame[::8, ::8].astype(np.float32).mean(axis=2)
        if small and float(np.abs(grey - small[-1]).mean()) < 0.04:
            continue  # nothing moved
        frames.append(frame.copy())
        small.append(grey)
    done = np.concatenate([[0.0], np.cumsum([float(np.abs(b - a).mean()) for a, b in zip(small, small[1:])])])
    done /= done[-1]
    # When each frame is due: the move is already under way at the start and slows into its end.
    table = np.linspace(0, 1, 2001)
    eased = 0.45 * table + 0.55 * (1 - (1 - table) ** 2)
    due = np.interp(done, eased, table) * seconds
    # Handed on at a fine, steady rate with each frame repeated until the next is due, which is how
    # its new time reaches the interpolator; the repeats are dropped again before it estimates.
    fine = 120
    encode = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(fine), "-i", "-",
        "-vf", f"mpdecimate=hi=1:lo=1:frac=1,minterpolate=fps={fps}:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1:scd=none:search_param=64,"
               f"tpad=stop_mode=clone:stop_duration={hold},format=yuv420p",
        "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-g", "15", "-movflags", "+faststart", str(out)], stdin=subprocess.PIPE)
    ticks = np.maximum(np.round(due * fine).astype(int), np.arange(len(due)))
    for i, frame in enumerate(frames):
        repeat = (ticks[i + 1] - ticks[i]) if i + 1 < len(frames) else 1
        data = frame.tobytes()
        for _ in range(max(1, repeat)):
            encode.stdin.write(data)
    encode.stdin.close()
    encode.wait()
