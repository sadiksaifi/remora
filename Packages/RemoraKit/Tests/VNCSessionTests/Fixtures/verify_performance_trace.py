"""Capture the public session fixture and validate only numeric signpost fields.

Run from the repository root after swift test has built the test products:
python3 Packages/RemoraKit/Tests/VNCSessionTests/Fixtures/verify_performance_trace.py <private-output-directory> [--attach]
Raw tool output stays in that directory. No TOC or environment is exported.
"""
import json
import os
import queue
import threading
import uuid
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

FIELDS = {
    'VNCUpdate': set('seq ok declared_rects header_known wire_rects callbacks request_known prefetched_start req_to_ready_us ready_to_header_us message_us read_wait_us logical_bytes buffered_end cpu_us callback_us area_sum area_max enc_mask requests_during inputs_during'.split()),
    'VNCPixelRect': set('seq index x y w h encoding rect_bytes zrle_len header_to_len_us len_to_body_us body_to_callback_us rect_wait_us'.split()),
    'VNCRequest': set('seq incremental full_area write_us ok'.split()),
    'VNCInput': set('seq kind ok'.split()),
}

def rows(path):
    root = ET.parse(path).getroot()
    ids = {node.get('id'): node for node in root.iter() if node.get('id')}
    def value(node):
        if node is None:
            return ''
        if node.get('ref') in ids:
            return value(ids[node.get('ref')])
        return ''.join(node.itertext())
    events = {}
    for row in root.findall('.//row'):
        name = value(row.find('signpost-name'))
        if name not in FIELDS:
            continue
        stamp = value(row.find('event-time'))
        identity = value(row.find('os-signpost-identifier'))
        assert stamp.isdigit() and identity.isdigit()
        label = value(row.find('string'))
        assert re.fullmatch(r'arg\d+', label)
        fmt = value(row.find('format-string'))
        fields = re.findall(r'([a-z_]+)=%\{public\}(llu|lld|u|d)', fmt)
        assert len(fields) > int(label[3:])
        field, kind = fields[int(label[3:])]
        assert {key for key, _ in fields} == FIELDS[name]
        number = value(row.find('uint64'))
        assert re.fullmatch(r'-?\d+', number)
        number = int(number)
        if kind in ('lld', 'd') and number >= 2**63:
            number -= 2**64
        event = events.setdefault((int(stamp), int(identity), name), {'name': name, 'at_ns': int(stamp), 'client': int(identity)})
        assert field not in event
        event[field] = number
    return sorted(events.values(), key=lambda row: row['at_ns'])

def verify(events, expected, attached=False):
    updates = [e for e in events if e['name'] == 'VNCUpdate']
    count = 3 if attached else 4
    assert len(updates) == count, f'Expected {count} updates, observed {len(updates)}'
    assert [e['seq'] for e in updates] == ([2, 3, 4] if attached else [1, 2, 3, 4])
    assert len({e['client'] for e in events}) == 1
    pixels, empty, failed = updates[-3:]
    if not attached:
        resize = updates[0]
        assert (resize['declared_rects'], resize['wire_rects'], resize['callbacks'], resize['logical_bytes'], resize['requests_during']) == (1, 1, 0, 16, 1)
        assert resize['request_known'] == 1 and resize['req_to_ready_us'] >= 0
    else:
        assert (pixels['request_known'], pixels['prefetched_start'], pixels['req_to_ready_us']) == (0, 0, -1)
    assert (pixels['declared_rects'], pixels['wire_rects'], pixels['callbacks'], pixels['logical_bytes']) == (65535, 4, 2, expected['logical'])
    assert (pixels['area_sum'], pixels['area_max'], pixels['enc_mask'], pixels['inputs_during'], pixels['requests_during']) == (512, 256, 16, 3, 0)
    assert pixels['read_wait_us'] >= 200000
    assert pixels['message_us'] >= pixels['read_wait_us']
    assert pixels['buffered_end'] >= 4
    assert (empty['declared_rects'], empty['wire_rects'], empty['callbacks'], empty['logical_bytes'], empty['prefetched_start'], empty['request_known'], empty['req_to_ready_us']) == (0, 0, 0, 4, 1, 0, -1)
    assert (failed['ok'], failed['declared_rects'], failed['wire_rects'], failed['callbacks']) == (0, 1, 1, 0)
    for key in ('req_to_ready_us', 'ready_to_header_us', 'message_us', 'read_wait_us', 'logical_bytes', 'buffered_end', 'cpu_us', 'callback_us'):
        assert failed[key] == -1
    rects = [e for e in events if e['name'] == 'VNCPixelRect']
    assert len(rects) == 2
    for index, rect in enumerate(rects):
        length = expected['first' if index == 0 else 'second']
        assert (rect['seq'], rect['index'], rect['x'], rect['y'], rect['w'], rect['h'], rect['encoding']) == (2, index, index*16, 0, 16, 16, 16)
        assert (rect['rect_bytes'], rect['zrle_len']) == (length+16, length)
        assert all(rect[key] >= 0 for key in ('header_to_len_us', 'len_to_body_us', 'body_to_callback_us', 'rect_wait_us'))
    assert rects[0]['len_to_body_us'] >= 200000
    requests = [e for e in events if e['name'] == 'VNCRequest']
    expected_requests = [(2,1,1,1),(3,1,1,1)]
    if not attached: expected_requests = [(0,0,1,1),(1,0,1,1),(1,1,1,1)] + expected_requests
    assert [(e['seq'], e['incremental'], e['full_area'], e['ok']) for e in requests] == expected_requests
    inputs = [e for e in events if e['name'] == 'VNCInput']
    assert [(e['seq'], e['kind'], e['ok']) for e in inputs] == [(2,1,1),(2,1,1),(2,2,1)]
    assert max(e['at_ns'] for e in inputs) < rects[0]['at_ns']
    assert all(e['ok'] == 1 for e in updates[:-1])
    for update in updates[:-1]:
        assert update['header_known'] == 1
        for field in ('ready_to_header_us', 'read_wait_us', 'cpu_us', 'callback_us'):
            assert 0 <= update[field] <= update['message_us']

def main():
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True, mode=0o700)
    options = out/'recording-options.json'
    options.write_text(json.dumps({'os_signpost': {'dynamicTracingEnabledSubsystems': ['com.peblon.remora'], 'recordAllProcessesInSingleProcessMode': False}}))
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    swift = Path(subprocess.check_output(['xcrun', '--find', 'swift'], text=True).strip())
    helper = swift.parent.parent/'libexec/swift/pm/swiftpm-testing-helper'
    bundle = next(Path('Packages/RemoraKit/.build').glob('out/Products/Debug/VNCSessionTests.xctest/Contents/MacOS/VNCSessionTests')).resolve()
    platform = developer/'Platforms/MacOSX.platform/Developer'
    attached = len(sys.argv) > 2 and sys.argv[2] == '--attach'
    arguments = [str(helper), '--test-bundle-path', str(bundle), '--testing-library', 'swift-testing', '--filter', 'vncPerformanceTraceFixture']
    environment = {'DYLD_FRAMEWORK_PATH': str(platform/'Library/Frameworks'), 'DYLD_LIBRARY_PATH': str(platform/'usr/lib'), 'CFFIXED_USER_HOME': str(out/'test-home')}
    command = ['xcrun', 'xctrace', 'record', '--instrument', 'os_signpost', '--recording-options', str(options), '--time-limit', '8s', '--output', str(out/'capture.trace')]
    with (out/'capture.log').open('w') as log:
        if attached:
            test = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=dict(os.environ, **environment, REMORA_TEST_TRACE_ATTACH='1'))
            ready = queue.Queue()
            def reader():
                with (out/'test.log').open('w') as output:
                    for line in test.stdout:
                        output.write(line); output.flush()
                        match = re.fullmatch(r'VNC_TRACE_ATTACH_PID=(\d+)\n', line)
                        if match: ready.put(int(match[1]))
            worker = threading.Thread(target=reader, daemon=True)
            worker.start()
            notifier = capture = None
            try:
                pid = ready.get(timeout=10)
                notification = 'com.peblon.remora.trace-test.'+uuid.uuid4().hex
                notifier = subprocess.Popen(['/usr/bin/notifyutil', '-1', notification], stdout=log, stderr=subprocess.STDOUT)
                capture = subprocess.Popen(command + ['--attach', str(pid), '--notify-tracing-started', notification], stdout=log, stderr=subprocess.STDOUT)
                assert notifier.wait(timeout=10) == 0, 'Tracing-start notification failed'
                test.stdin.write('\n'); test.stdin.flush(); test.stdin.close()
                assert capture.wait(timeout=20) == 0, 'Attached recording failed'
                assert test.wait(timeout=10) == 0, 'Public fixture process failed'
                worker.join(timeout=2)
            finally:
                for process in (capture, notifier, test):
                    if process is not None and process.poll() is None:
                        process.terminate(); process.wait(timeout=5)
        else:
            command += ['--target-stdout', str(out/'test.log')]
            for key, value in environment.items(): command += ['--env', key+'='+value]
            capture = subprocess.run(command + ['--launch', '--'] + arguments, stdout=log, stderr=subprocess.STDOUT, timeout=25)
    assert capture.returncode == 0, f'xctrace exit {capture.returncode}'
    output = (out/'test.log').read_text()
    assert re.search(r'Test run with 1 test.*passed', output), 'Public session fixture did not pass'
    if attached: assert 'VNC_TRACE_ATTACHED=1' in output, 'Recording did not enable after connection'
    expected = {key: int(value) for key, value in re.findall(r'(first|second|logical)=(\d+)', output)}
    with (out/'export.log').open('w') as log:
        exported = subprocess.run(['xcrun', 'xctrace', 'export', '--input', str(out/'capture.trace'), '--xpath', '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost-arg"]', '--output', str(out/'arguments.xml')], stdout=log, stderr=subprocess.STDOUT, timeout=20)
    assert exported.returncode == 0, f'export exit {exported.returncode}'
    events = rows(out/'arguments.xml')
    (out/'numeric-events.json').write_text(json.dumps(events, indent=2)+'\n')
    verify(events, expected, attached)
    print(json.dumps({'pass': True, 'attached_after_connect': attached, 'events': len(events), 'updates': 3 if attached else 4, 'pixel_callbacks': 2, 'requests': 2 if attached else 5, 'inputs': 3}))

if __name__ == '__main__':
    try:
        main()
    except (AssertionError, subprocess.TimeoutExpired, queue.Empty) as error:
        print(json.dumps({'pass': False, 'error': str(error)}))
        sys.exit(1)
