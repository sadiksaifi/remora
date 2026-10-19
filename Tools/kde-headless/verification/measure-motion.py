#!/usr/bin/env python3
"""Count visible source IDs or window positions using the recording's real PTS."""
import argparse
import json
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('video')
parser.add_argument('--mode', choices=('barcode', 'drag'), default='barcode')
parser.add_argument('--origin', type=int, nargs=2, default=(316, 129), metavar=('X', 'Y'),
                    help='client-area origin of the numbered motion window')
args = parser.parse_args()
frames = json.loads(subprocess.check_output([
    'ffprobe', '-v', 'error', '-show_frames', '-show_entries',
    'frame=best_effort_timestamp_time', '-of', 'json', args.video,
]))['frames']
timestamps = [float(frame['best_effort_timestamp_time']) for frame in frames]
if args.mode == 'barcode':
    x, y = args.origin
    filter_text = f'format=gray,crop=640:1:{x + 16}:{y + 44}'
    pixel_format, stride = 'gray', 640
else:
    filter_text = 'format=rgb24,crop=1280:1:0:600'
    pixel_format, stride = 'rgb24', 3840
# Give rawvideo a synthetic time base only for transport. Analysis uses ffprobe PTS.
proc = subprocess.Popen([
    'ffmpeg', '-v', 'error', '-i', args.video, '-vf',
    filter_text + ',setpts=N/(60*TB)', '-enc_time_base', '1:60',
    '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', pixel_format, '-',
], stdout=subprocess.PIPE)
values = []
while data := proc.stdout.read(stride):
    if len(data) != stride:
        raise RuntimeError('Incomplete decoded scanline')
    if args.mode == 'barcode':
        values.append(sum((data[20 + bit * 40] > 128) << bit for bit in range(16)))
    else:
        # The blue stripe is below the background window and away from the pointer.
        values.append(next((i // 3 for i in range(0, stride, 3)
                            if data[i + 1] - data[i] > 40 and data[i + 2] - data[i] > 100), -1))
if proc.wait() or len(values) != len(timestamps):
    raise RuntimeError('Decode failed or timestamp/frame counts differ')
changes = [(time, value) for i, (time, value) in enumerate(zip(timestamps, values))
           if i and value != values[i - 1]]
if args.mode == 'barcode':
    changes = [(time, value) for time, value in changes if 180 <= value <= 1380]
else:
    if len(changes) < 2:
        raise RuntimeError('No window motion detected on scanline 600')
    start, end = changes[0][0] + 2, changes[-1][0] - 2
    changes = [(time, value) for time, value in changes if start <= time <= end]
if len(changes) < 2:
    raise RuntimeError('No usable motion segment; check the window origin and workload')
intervals = sorted((b[0] - a[0]) * 1000 for a, b in zip(changes, changes[1:]))
duration = changes[-1][0] - changes[0][0]
print(json.dumps({
    'mode': args.mode,
    'distinct_updates': len(changes),
    'duration_seconds': duration,
    'updates_per_second': (len(changes) - 1) / duration,
    'interval_ms': {
        'mean': statistics.mean(intervals),
        'p95': intervals[int(.95 * (len(intervals) - 1))],
        'max': max(intervals),
    },
    'gaps_over_100ms': sum(interval > 100.01 for interval in intervals),
    'value_range': [min(value for _, value in changes), max(value for _, value in changes)],
}, indent=2))
