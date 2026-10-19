#!/usr/bin/env python3
"""Run against a configured, built KPipeWire 6.3.6 Makefiles build.

Usage: producer-recovery.py SOURCE BUILD
Uses its real producer, timer, FFmpeg filter/encoder/decoder and pending counters.
A disposable source copy omits PipeWire connection setup; the C++ fixture fixes
the unconnected source size and drives source arrivals and worker scheduling.
It never edits the supplied source/build.
"""
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

source, build = map(lambda p: Path(p).resolve(), sys.argv[1:])
fixture = Path(__file__).with_suffix('.cpp')
object_dir = build / 'src/CMakeFiles/KPipeWireRecord.dir'
flags = {}
for line in (object_dir / 'flags.make').read_text().splitlines():
    if ' = ' in line:
        key, value = line.split(' = ', 1)
        flags[key] = shlex.split(value)
compile_flags = sum((flags[key] for key in ('CXX_DEFINES', 'CXX_INCLUDES', 'CXX_FLAGS')), [])
with tempfile.TemporaryDirectory(prefix='producer-recovery-') as tmp:
    tmp = Path(tmp)
    text = (source / 'src/pipewireproduce.cpp').read_text()
    start = text.index('    m_stream.reset(new PipeWireSourceStream(nullptr));', text.index('void PipeWireProduce::initialize()'))
    end = text.index('    /**', start)
    text = text[:start] + text[end:]
    (tmp / 'producer.cpp').write_text(text)
    for name, file in [('producer', tmp / 'producer.cpp'), ('fixture', fixture)]:
        subprocess.run(['c++', *compile_flags, '-c', str(file), '-o', str(tmp / (name + '.o'))], check=True)
    link = shlex.split((object_dir / 'link.txt').read_text())
    result = []
    i = 0
    while i < len(link):
        arg = link[i]
        if arg == '-shared' or arg.startswith('-Wl,-soname,'):
            i += 1
            continue
        if arg == '-o':
            result += ['-o', str(tmp / 'probe')]
            i += 2
            continue
        if arg.endswith('/pipewireproduce.cpp.o'):
            arg = str(tmp / 'producer.o')
        result.append(arg)
        i += 1
    result.append(str(tmp / 'fixture.o'))
    subprocess.run(result, cwd=build / 'src', check=True)
    sys.exit(subprocess.run([str(tmp / 'probe')]).returncode)
