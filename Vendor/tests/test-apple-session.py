"""Owned literal-loopback peers driving the real, sanitized native Apple adapter."""
import json
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = root / 'src/libvncserver-98aaee0560baa0332339b2ef464ea96ed9b9b28c'
peer_source = root.parent / 'Packages/RemoraKit/Tests/VNCSessionTests/Fixtures/ard_peer.py'
with tempfile.TemporaryDirectory(prefix='remora-apple-sanitizers-') as temporary:
    exe = str(pathlib.Path(temporary) / 'session')
    subprocess.run(['/usr/bin/clang', '-std=c17', '-g', '-O1',
                    '-fsanitize=address,undefined,integer,nullability', '-fno-sanitize-recover=all',
                    '-fno-omit-frame-pointer', '-Wno-deprecated-declarations',
                    '-I'+str(source/'include'), '-I'+str(root/'build/vnc/include'),
                    '-I'+str(root/'build/openssl-install/include'), '-I'+str(source/'src/common'),
                    str(root/'tests/test_apple_session.c'), str(root/'apple-mvs/apple.c'), str(root/'apple-mvs/mvs.c'),
                    str(root/'build/vnc-package/libLibVNCClient.a'), str(root/'build/openssl-install/lib/libssl.a'),
                    str(root/'build/openssl-install/lib/libcrypto.a'), '-lz', '-o',exe], check=True,timeout=60)
    for mode, frames in [('apple-retry-dropped',3),('apple-retry-empty',3),('apple-retry-quant',3),
                         ('apple-retry-raw',4),('apple-retry-controls',3),
                         ('apple-sequence',3),('apple-demand',4),('apple-damage',6),('apple-no-baseline',0),('apple-bad-cache',1),
                         ('apple-multi-invalid',1),('apple-session-select',0),('apple-reject',0),('apple-wrong-banner',0)]:
        with subprocess.Popen(['/usr/bin/python3','-u',str(peer_source),'ard-only',mode],stdout=subprocess.PIPE,text=True) as peer:
            try:
                port = json.loads(peer.stdout.readline())['loopback_port']
                env = dict(os.environ, ASAN_OPTIONS='abort_on_error=1', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
                subprocess.run([exe,str(port),str(frames)]+(['demand'] if mode=='apple-demand' else []),check=True,timeout=12,env=env)
                report = json.loads(peer.communicate(timeout=2)[0])
                assert 'error_class' not in report, (mode,report)
                if mode in ('apple-sequence','apple-no-baseline') or mode.startswith('apple-retry-'):
                    assert report['subscribed_before_baseline'] is True, report
                    assert report['subscriptions'] == [[0,1,0,0,0,16,8]], report
                if mode.startswith('apple-retry-'):
                    assert report['requests_after_initial'] == (2 if mode == 'apple-retry-dropped' else 1), report
                if mode=='apple-demand':
                    assert report['subscriptions'] == [[0,1,0,0,0,16,8],[0,1,0xffffffff,0,0,16,8],[0,1,0,0,0,16,8]], report
                    assert report['requests_after_initial'] == 1, report
                print(json.dumps(dict(mode=mode,frames=frames,sanitizers_pass=True)))
            finally:
                if peer.poll() is None: peer.terminate(); peer.wait(timeout=2)
