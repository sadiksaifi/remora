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
                    str(root/'tests/test_apple_session.c'), str(root/'apple-mvs/apple.c'), str(root/'apple-mvs/records.c'), str(root/'apple-mvs/mvs.c'),
                    str(root/'apple-mvs/srp.c'),
                    str(root/'build/vnc-package/libLibVNCClient.a'), str(root/'build/openssl-install/lib/libssl.a'),
                    str(root/'build/openssl-install/lib/libcrypto.a'), '-lz', '-o',exe], check=True,timeout=60)
    cases = [
        ('apple-retry-dropped', 3), ('apple-retry-empty', 3), ('apple-retry-quant', 3),
        ('apple-retry-raw', 4), ('apple-retry-controls', 3), ('apple-sequence', 3),
        ('apple-regions', 4, 'regions'), ('apple-region-uninitialized', 2, '0'),
        ('apple-demand', 4, 'demand'), ('apple-damage', 6), ('apple-no-baseline', 1, '0'),
        ('apple-large-records', 1, 'large'), ('apple-no-key', 0, '14'), ('apple-refuse', 0, '14'),
        ('apple-control-encryption', 1, '16'),
        *(('apple-invalid-'+case, 0, '15') for case in ('digest', 'length', 'body-length', 'sequence')),
        ('apple-clipboard', 3, 'clipboard'), ('apple-clipboard-limit', 1, 'large-clipboard'),
        ('apple-clipboard-early', 1, 'early-clipboard'), ('apple-clipboard-rich', 1, 'rich-clipboard'),
        *((case, 1, 'invalid-clipboard') for case in ('apple-clipboard-wire-limit', 'apple-clipboard-length',
                                                      'apple-clipboard-malformed')),
        ('apple-multi-invalid', 1), ('apple-session-select', 0), ('apple-reject', 0), ('apple-wrong-banner', 0),
        # A server that does not offer the SRP login gets no selection and no credentials.
        *(('apple-policy-reject', 0, '18', offers) for offers in ('ard-only', 'apple-ard', 'tls-ard', 'none-only')),
        # Unsupported SRP parameters end the login before the proof. A server without the verifier ends it after.
        *(('apple-srp-'+case, 0, '8') for case in ('group', 'generator', 'public-zero', 'public-modulus', 'iterations-zero', 'iterations-low',
                                                    'iterations-excessive', 'options', 'flag', 'trailing')),
        ('apple-impersonator-proof', 0, '19'), ('apple-impersonator-result', 0, '19'),
    ]
    # The last login runs against corecrypto's own SRP server arithmetic. srp_oracle.py describes it.
    runs = [(peer_source, *case) for case in cases] + [(root/'tests/srp_oracle.py', 'apple-sequence', 3)]
    for script, mode, frames, *checks in runs:
        offers = checks.pop() if len(checks) == 2 else 'apple-mixed'
        with subprocess.Popen(['/usr/bin/python3','-u',str(script),offers,mode],stdout=subprocess.PIPE,text=True) as peer:
            try:
                hello = json.loads(peer.stdout.readline())
                if 'oracle_unavailable' in hello:
                    print(json.dumps(dict(mode=mode, oracle_skipped=hello['oracle_unavailable'])))
                    continue
                port = hello['loopback_port']
                env = dict(os.environ, ASAN_OPTIONS='abort_on_error=1', UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
                subprocess.run([exe, str(port), str(frames), *checks], check=True, timeout=12, env=env)
                report = json.loads(peer.communicate(timeout=2)[0])
                assert 'error_class' not in report, (mode,report)
                if mode == 'apple-policy-reject': assert report['selector_received'] is False, report
                if mode.startswith('apple-srp-'): assert report['closed_before_proof'] is True, report
                if mode.startswith('apple-impersonator-'):
                    assert report['proof_verified'] is False and report['closed_after_proof'] is True, report
                if mode == 'apple-reject': assert report['closed_without_input'] is True, report
                if frames: assert report['credentials_valid'] is True and report['selected_security_id'] == 36, report
                if mode in ('apple-sequence','apple-no-baseline') or mode.startswith('apple-retry-'):
                    assert report['subscribed_before_baseline'] is True, report
                    assert report['subscriptions'] == [[0,1,0,0,0,16,8]], report
                if mode.startswith('apple-retry-'):
                    assert report['requests_after_initial'] == (2 if mode == 'apple-retry-dropped' else 1), report
                if mode=='apple-demand':
                    assert report['subscriptions'] == [[0,1,0,0,0,16,8],[0,1,0xffffffff,0,0,16,8],[0,1,0,0,0,16,8]], report
                    assert report['requests_after_initial'] == 1, report
                print(json.dumps(dict(mode=mode,frames=frames,sanitizers_pass=True,peer=script.name)))
            finally:
                if peer.poll() is None: peer.terminate(); peer.wait(timeout=2)
