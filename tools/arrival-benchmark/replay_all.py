"""Replay every recording in a folder through the App's forecast, then score them together.

Each recording is one extracted arrival-benchmark artifact (gps.csv.gz, eta.csv.gz and, for
some, static/). Recordings without static/ use the route data of the nearest recording that
has it, preferring an earlier one, since that is what phones had downloaded at the time.

    python3 tools/arrival-benchmark/replay_all.py RECORDINGS_DIR --official official-times.json --out OUT

With --city ntpc it replays the New Taipei half of each recording (its ntpc/ folder) instead.
"""
import argparse, gzip, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
BINARY = HERE / 'replay' / '.build' / 'release' / 'ArrivalReplay'


def first_poll(folder):
    with gzip.open(folder / 'gps.csv.gz', 'rt') as handle:
        handle.readline()
        line = handle.readline()
    return datetime.fromisoformat(line.split(',', 1)[0].replace('Z', '+00:00')) if line else None


def has_static(folder):
    return all((folder / 'static' / f'{name}.gz').exists() for name in ('GetRoute', 'GetStop', 'GetPathDetail', 'GetBusShape'))


def static_for(recording, starts, sources):
    start = starts[recording]
    earlier = [s for s in sources if starts[s] <= start]
    if earlier:
        return max(earlier, key=lambda s: starts[s])
    return min(sources, key=lambda s: abs((starts[s] - start).total_seconds()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recordings', type=Path)
    parser.add_argument('--official', type=Path, required=True, help='official-times.json from the travel-time-data release')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument('--every', type=int, default=3)
    parser.add_argument('--tuning', type=Path, help='replay with this runtime/tuning.json candidate')
    parser.add_argument('--city', choices=['tpe', 'ntpc'], default='tpe')
    args = parser.parse_args()
    if not BINARY.exists():
        sys.exit(f'Build the replay first: swift build -c release --package-path {HERE / "replay"}')
    folders = sorted(p if args.city == 'tpe' else p / args.city for p in args.recordings.iterdir() if p.is_dir())
    recordings = [p for p in folders if (p / 'gps.csv.gz').exists() and (p / 'eta.csv.gz').exists()]
    starts = {r: first_poll(r) for r in recordings}
    recordings = [r for r in recordings if starts[r]]
    sources = [r for r in recordings if has_static(r)]
    if not sources:
        sys.exit('No recording contains static/ route data.')

    def name(recording):
        return recording.name if args.city == 'tpe' else recording.parent.name

    def replay(recording):
        target = args.out / 'replay' / name(recording)
        if (target / 'summary.json').exists():
            return recording, 0
        static = static_for(recording, starts, sources) / 'static'
        command = [str(BINARY), '--static', str(static), '--official', str(args.official), '--run', str(recording),
                   '--out', str(target), '--every', str(args.every), '--source', args.city]
        if args.tuning:
            command += ['--tuning', str(args.tuning)]
        result = subprocess.run(command, capture_output=True, text=True)
        (args.out / 'logs').mkdir(parents=True, exist_ok=True)
        (args.out / 'logs' / f'{name(recording)}.log').write_text(result.stdout + result.stderr)
        return recording, result.returncode

    with ThreadPoolExecutor(args.jobs) as pool:
        failures = []
        for recording, code in pool.map(replay, recordings):
            print(f'{name(recording)}: {"ok" if code == 0 else f"failed ({code})"}', flush=True)
            if code:
                failures.append(name(recording))
    done = [args.out / 'replay' / name(r) for r in recordings if (args.out / 'replay' / name(r) / 'summary.json').exists()]
    subprocess.run([sys.executable, str(HERE / 'score.py'), *map(str, done), '--out', str(args.out)], check=True)
    if failures:
        sys.exit(f'Replay failed for: {", ".join(failures)}')


if __name__ == '__main__':
    main()
