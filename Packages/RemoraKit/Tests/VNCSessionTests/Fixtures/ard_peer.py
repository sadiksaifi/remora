"""Independent synthetic ARD loopback test peer.

RFB type 30 framing: rfbproto/rfbproto, Diffie-Hellman Authentication.
DH test group: RFC 2409 section 6.2. AES: system CommonCrypto, NIST KAT.
No Remora imports, saved settings, credentials, or OpenSSL calls.
"""
import ctypes
import hashlib
import json
import os
import struct
import sys

PRIME_HEX = (
    'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1'
    '29024E088A67CC74020BBEA63B139B22514A08798E3404DD'
    'EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245'
    'E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED'
    'EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381'
    'FFFFFFFFFFFFFFFF'
)
P = int(PRIME_HEX, 16)
G = 2
SIZE = 128
USERNAME = b'fixture-user'
PASSWORD = b'fixture-password'
OFFERS = [30, 33, 36, 2, 35]
SERVER_EXPONENT = int.from_bytes(hashlib.sha256(b'ARD synthetic server exponent').digest(), 'big')


def synthetic_zrle(dimension, compressor=None):
    """Independent legal raw-tile ZRLE stream; no captured desktop content."""
    import random
    import zlib
    randomizer = random.Random(314159)
    tiles = bytearray()
    for ty in range(0, dimension, 64):
        for tx in range(0, dimension, 64):
            tiles.append(0)
            tiles.extend(randomizer.randbytes(min(64, dimension-tx) * min(64, dimension-ty) * 3))
    compressor = compressor or zlib.compressobj()
    return compressor.compress(tiles) + compressor.flush(zlib.Z_SYNC_FLUSH)


def fixed(value):
    return value.to_bytes(SIZE, 'big')


def aes_ecb(key, data, decrypt=False):
    if len(key) != 16 or len(data) % 16:
        raise ValueError('AES input size')
    library = ctypes.CDLL('/usr/lib/system/libcommonCrypto.dylib')
    crypt = library.CCCrypt
    crypt.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
                      ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                      ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                      ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    crypt.restype = ctypes.c_int32
    key_buffer = ctypes.create_string_buffer(key)
    input_buffer = ctypes.create_string_buffer(data)
    output_buffer = ctypes.create_string_buffer(len(data) + 16)
    moved = ctypes.c_size_t()
    # kCCEncrypt=0 / kCCDecrypt=1; kCCAlgorithmAES=0; kCCOptionECBMode=2.
    status = crypt(int(decrypt), 0, 2, key_buffer, len(key), None,
                   input_buffer, len(data), output_buffer, len(output_buffer), ctypes.byref(moved))
    if status != 0 or moved.value != len(data):
        raise ValueError('CommonCrypto status/length')
    return output_buffer.raw[:moved.value]


def known_answer_check():
    key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
    plaintext = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
    ciphertext = bytes.fromhex('3ad77bb40d7a3660a89ecaf32466ef97')
    if aes_ecb(key, plaintext) != ciphertext or aes_ecb(key, ciphertext, True) != plaintext:
        raise ValueError('NIST AES ECB known-answer mismatch')
    if P.bit_length() != 1024 or len(bytes.fromhex(PRIME_HEX)) != SIZE:
        raise ValueError('RFC group size mismatch')


def mvs_bits(*parts):
    # Owned vectors from noVNC-ARD ard/tests/test.mvs.js, d6992936, MPL-2.0.
    bits = ''.join(c for part in parts for c in part if c in '01')
    bits += '0' * (-len(bits) % 8)
    return bytes(int(bits[i:i+8], 2) for i in range(0, len(bits), 8))


def apple_frames(outcome, exact, send, key, report, connection):
    import select
    import time
    began = time.monotonic()
    def marker(text): return ''.join(format(c, '08b') for c in text.encode('ascii'))
    header = mvs_bits('0', '101 1 0000', marker('m'))
    body = mvs_bits('0 0 0', '00', '00', '1110 010 1', '0 01 0', '1', marker('m'))
    full = bytes([0,15,25]) + (6+len(header)).to_bytes(3,'big') + header + body
    partial = bytes([1,14,19]) + mvs_bits('01','000000','1 0','1010','0','1010','00',marker('mvs'))
    cache = bytes([1,14,19]) + mvs_bits('00','11 0 0000000000000001',marker('mvs'))
    def update(payload, encoding=1011, rect=(0,0,16,8)):
        send(struct.pack('>BBHHHHHi',0,0,1,*rect,encoding) + (struct.pack('>I',len(payload)) if encoding==1011 else b'') + payload)
    report['keys'] = []; report['pointers'] = []; report['scrolls'] = []
    report['requests_after_initial'] = 0; report['subscriptions'] = []
    def client_message():
        kind = exact(1)[0]
        if kind == 9:
            fields = struct.unpack('>BHIHHHH',exact(15))
            report['subscriptions'].append(list(fields))
        elif kind == 0x10:
            flags = exact(1)[0]
            plain = aes_ecb(key,exact(16),True)
            if flags != 0 or plain[0] != 255 or any(plain[10:]): raise ValueError('encrypted event framing')
            down, symbol, timestamp = plain[1], int.from_bytes(plain[2:6],'big'), int.from_bytes(plain[6:10],'big')
            if down not in (0,1): raise ValueError('key direction')
            report['keys'].append([symbol,down,timestamp])
        elif kind == 5:
            mask,x,y = struct.unpack('>BHH',exact(5))
            report['pointers'].append([mask,x,y])
        elif kind == 0x17:
            b = exact(57)
            if b[:7] != bytes([0,0,54,0,1,0,11]): raise ValueError('scroll envelope')
            dx,dy = struct.unpack('>hh',b[7:11])
            fixedx,fixedy,_,pointx,pointy = struct.unpack('>iiiii',b[13:33])
            x,y = struct.unpack('>HH',b[53:57])
            report['scrolls'].append([dx,dy,fixedx,fixedy,pointx,pointy,x,y])
        elif kind == 3:
            request = struct.unpack('>BHHHH', exact(9))
            if request != (0,0,0,16,8): raise ValueError('full non-incremental request required')
            report['requests_after_initial'] += 1
        else: raise ValueError('unexpected Apple client message')
        return kind
    if outcome == 'apple-no-baseline':
        update(partial); return
    if outcome == 'apple-truncated':
        send(struct.pack('>BBHHHHHiI',0,0,1,0,0,16,8,1011,100)+b'\x00'); return
    if outcome.startswith('apple-retry-'):
        if outcome == 'apple-retry-empty': send(bytes(4))
        # These vectors have only DC coefficients; retain their known DC quantizers.
        elif outcome == 'apple-retry-quant': update(bytes([2])+bytes([16])*64+bytes([19])*64, rect=(0,0,0,0))
        elif outcome == 'apple-retry-raw': update(bytes([148,148,148,255])*64, 0, (0,0,8,8))
        elif outcome == 'apple-retry-controls': send(bytes([4,7,0x14,0,0,4,0,0,0,0,0x51,0,0]))
        # Drop the initial request, and in the dropped case also its first retry.
        retries = 2 if outcome == 'apple-retry-dropped' else 1
        for _ in range(64):
            if client_message()==3 and report['requests_after_initial']==retries: break
        else: raise ValueError('missing baseline retry')
        report['baseline_retry_ms'] = round((time.monotonic()-began)*1000)
        if outcome == 'apple-retry-hidden': time.sleep(0.1)
    update(full)
    # Subscription may follow already-admitted input. Read independently until it arrives.
    for _ in range(64):
        if client_message()==9: break
    else: raise ValueError('missing subscription')
    if report['subscriptions'][-1] != [0,1,0,0,0,16,8]: raise ValueError('subscription region')
    if outcome == 'apple-hidden-baseline':
        report['baseline_retry_ms'] = round((time.monotonic()-began)*1000)
        for _ in range(64):
            if client_message()==3: break
        else: raise ValueError('missing resume refresh')
    if outcome == 'apple-geometry':
        update(b'',-223,(0,0,32,8)); return
    if outcome == 'apple-bad-cache':
        invalid = bytes([1,14,19])+mvs_bits('11 0 1111110111100111',marker('mvs'))
        update(invalid); return
    if outcome == 'apple-multi-invalid':
        # A valid Raw rectangle followed by an invalid encoding must not publish a half frame.
        send(struct.pack('>BBH',0,0,2)+struct.pack('>HHHHi',0,0,16,8,0)+bytes(16*8*4)+struct.pack('>HHHHi',0,0,16,8,123456)); return
    if outcome == 'apple-control-encryption':
        update(b'',1103); return
    if outcome == 'apple-damage':
        # Quantization, skips and invalid match sources write no pixels.
        update(bytes([1,14,19])+mvs_bits('00 00',marker('mvs')))
        update(bytes([1,14,19])+mvs_bits('10 00',marker('mvs')))
        # A match baseline shares the first tile's DCT and copies it to the second.
        match_header = mvs_bits('0', '101 0', '001 0', marker('m'))
        match_body = mvs_bits('0 0 0','00','00','1110 010 1','0 01 0',marker('m'))
        update(bytes([0,15,25])+(6+len(match_header)).to_bytes(3,'big')+match_header+match_body)
        update(partial)
        update(bytes([1,14,19])+mvs_bits('00 10',marker('mvs')))
        def raw(rect, pixel): return struct.pack('>HHHHi',*rect,0)+bytes(pixel)*(rect[2]*rect[3])
        send(struct.pack('>BBH',0,0,2)+raw((1,1,2,2),(1,2,3,255))+raw((10,4,3,2),(4,5,6,255)))
        one_cache = bytes([1,14,19])+mvs_bits('11 0 0000000000000001',marker('mvs'))
        send(struct.pack('>BBH',0,0,2)+raw((1,2,2,2),(7,8,9,255))
             +struct.pack('>HHHHiI',8,0,8,8,1011,len(one_cache))+one_cache)
        update(bytes([2])+bytes([8])*128, rect=(0,0,0,0))
        # The decoder writes a tile before rejecting this marker. Never publish it.
        update(partial[:-1]+bytes([partial[-1]^0x80]))
        return
    # Known control messages and discarded clipboard may precede the next update.
    send(bytes([4,7,0x14,0,0,4,0,0,0,0,0x51,0,0]))
    send(bytes([3,0,0,0])+struct.pack('>I',5)+b'owned')
    send(bytes([0x1f,0,0,0])+struct.pack('>III',0,5,5)+b'owned')
    update(partial); update(cache)
    report['stage'] = 'apple_updates_sent'
    if outcome == 'apple-input':
        # The public test finishes with the final human release, after agent cancellation.
        for _ in range(100):
            client_message()
            if len(report['keys'])>=8 and len(report['scrolls'])>=2 and report['pointers'] and report['pointers'][-1][0]==0:
                break
        else: raise ValueError('input completion missing')
    elif outcome == 'apple-demand':
        for _ in range(12):
            client_message()
            if len(report['subscriptions'])>=3 and report['requests_after_initial']>=1: break
        else: raise ValueError('demand completion missing')
    elif outcome.startswith('apple-retry-') or outcome == 'apple-hidden-baseline':
        # A baseline must stop retries, including across more than one retry interval.
        if select.select([connection],[],[],1.2)[0]:
            client_message()
            raise ValueError('unexpected client message after baseline')


def serve_once(offer_mode, outcome, port):
    # Imported only for the explicitly requested listener subcommand. This
    # helper has no remote host argument, DNS call, connect call, or retry loop.
    import socket
    import time
    known_answer_check()
    report = {'synthetic_only': True, 'attempts': 0, 'stage': 'listen', 'credentials_valid': False}
    deadline = time.monotonic() + 10
    offers = {
        'apple-mixed': OFFERS,
        'ard-only': [30],
        'apple-ard': [33,30],
        'unknown-ard': [30, 250],
        'apple-vnc': [33, 35, 36, 2],
        'apple-none': [33, 35, 36, 1],
        'tls-ard': [30, 19],
        'none-only': [1],
        'apple-only': [33],
    }[offer_mode]
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(('127.0.0.1', port))
            listener.listen(1)
            listener.settimeout(max(0.001, deadline - time.monotonic()))
            print(json.dumps({'loopback_port': listener.getsockname()[1]}), flush=True)
            connection, _ = listener.accept()
            report['attempts'] = 1
            with connection:
                if outcome in ('fragmented-small', 'fragmented-large'):
                    connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                def exact(count):
                    data = bytearray()
                    while len(data) < count:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise TimeoutError('fixture deadline')
                        connection.settimeout(remaining)
                        part = connection.recv(count - len(data))
                        if not part:
                            raise EOFError('fixture field incomplete')
                        data.extend(part)
                    return bytes(data)
                def send(data):
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError('fixture deadline')
                    connection.settimeout(remaining)
                    connection.sendall(data)
                report['stage'] = 'version'
                send(b'RFB 003.008\n' if outcome=='apple-wrong-banner' else b'RFB 003.889\n')
                if outcome=='apple-wrong-banner':
                    try: exact(1)
                    except EOFError:
                        report['wrong_banner_rejected'] = True; return report
                    raise ValueError('unexpected reply to non-889 banner')
                apple = outcome.startswith('apple-')
                reply = exact(12)
                report['version_889'] = reply == b'RFB 003.889\n'
                if reply != (b'RFB 003.889\n' if apple else b'RFB 003.008\n'):
                    raise ValueError('unexpected dialect reply')
                report['stage'] = 'security_selection'
                send(bytes([len(offers)] + offers))
                if outcome in ('expect-policy-reject', 'apple-policy-reject'):
                    try:
                        exact(1)
                    except EOFError:
                        report['stage'] = 'policy_rejected_before_selection'
                        report['selector_received'] = False
                        return report
                    raise ValueError('unexpected selector after mixed offer')
                selection = exact(1)[0]
                report['selected_security_id'] = selection
                if outcome == 'apple-profile-reject':
                    try: exact(1)
                    except EOFError:
                        report['profile_rejected'] = True; return report
                    raise ValueError('profile used unsupported authentication')
                if selection != 30:
                    raise ValueError('fixture implements only ARD 30')
                if outcome == 'close-after-selection':
                    report['stage'] = 'intentional_close_after_selection'
                    return report
                if outcome == 'crypto-failure':
                    report['stage'] = 'synthetic_invalid_dh_sent'
                    # 256-bit declared modulus is below OpenSSL's 512-bit minimum.
                    # It intentionally fails local key generation before credentials.
                    small_modulus = (2 ** 255 - 19).to_bytes(32, 'big')
                    send(struct.pack('>HH', G, 32) + small_modulus + (4).to_bytes(32, 'big'))
                    try:
                        exact(1)
                    except EOFError:
                        report['client_closed'] = True
                        return report
                    raise ValueError('unexpected response after invalid DH group')
                report['stage'] = 'ard_challenge_response'
                server_public = pow(G, SERVER_EXPONENT, P)
                send(struct.pack('>HH', G, SIZE) + fixed(P) + fixed(server_public))
                if outcome == 'close-after-challenge':
                    report['stage'] = 'intentional_close_after_challenge'
                    return report
                ciphertext, client_public = exact(128), int.from_bytes(exact(SIZE), 'big')
                if not 1 < client_public < P - 1:
                    raise ValueError('invalid client public value')
                shared = fixed(pow(client_public, SERVER_EXPONENT, P))
                plaintext = aes_ecb(hashlib.md5(shared).digest(), ciphertext, True)
                fields = [plaintext[:64], plaintext[64:]]
                valid = all(b'\x00' in field for field in fields)
                valid = valid and fields[0].split(b'\x00', 1)[0] == USERNAME and fields[1].split(b'\x00', 1)[0] == PASSWORD
                report['credentials_valid'] = bool(valid)
                report['stage'] = 'security_result'
                if not valid or outcome in ('reject','apple-reject'):
                    reason = b'synthetic fixture rejection'
                    send(struct.pack('>II', 1, len(reason)) + reason)
                    if outcome=='apple-reject':
                        try: exact(1)
                        except EOFError: report['closed_without_input'] = True
                        else: raise ValueError('client data after failed authentication')
                    report['security_result'] = 1
                    return report
                send(struct.pack('>I', 0))
                report['security_result'] = 0
                report['stage'] = 'client_init'
                report['client_init'] = exact(1)[0]
                if report['client_init'] != (0x81 if apple else 1):
                    raise ValueError('ordinary shared ClientInit required')
                if outcome == 'server-init-eof':
                    report['stage'] = 'intentional_server_init_eof'
                    return report
                name = (bytes(2)+struct.pack('>I',4 if outcome=='apple-session-select' else 0)+bytes(16) if apple and outcome!='apple-no-extension' else b'') + b'synthetic-ard-peer'
                dimension = 256 if outcome == 'fragmented-large' else 16
                height = 8 if apple and outcome != 'apple-success' else dimension
                send(struct.pack('>HHBBBBHHHBBBBBBI', dimension, height, 32, 24, 0, 1,
                                 255, 255, 255, 16, 8, 0, 0, 0, 0, len(name)) + name)
                if outcome in ('apple-no-extension','apple-session-select'):
                    try: exact(1)
                    except EOFError:
                        report['unsupported_init_rejected']=True; return report
                    raise ValueError('profile continued after unsupported ServerInit')
                report['stage'] = 'framebuffer_request'
                for _ in range(8):
                    kind = exact(1)[0]
                    if kind == 10 and apple:
                        if exact(3) != bytes([0, 0, 1]): raise ValueError('control SetMode required')
                        report['control_mode'] = True
                    elif kind == 0:
                        exact(19)
                    elif kind == 2:
                        header = exact(3)
                        count = int.from_bytes(header[1:], 'big')
                        if count > 512:
                            raise ValueError('encoding count bound')
                        exact(count * 4)
                    elif kind == 3:
                        request = exact(9)
                        if apple and (not report.get('control_mode') or request != struct.pack('>BHHHH',0,0,0,dimension,height)):
                            raise ValueError('initial full request must follow SetMode')
                        if apple and outcome != 'apple-success':
                            apple_frames(outcome,exact,send,hashlib.md5(shared).digest(),report,connection)
                        elif outcome in ('fragmented-small', 'fragmented-large'):
                            compressed = synthetic_zrle(dimension)
                            report['compressed_bytes'] = len(compressed)
                            send(struct.pack('>BBHHHHHiI', 0, 0, 1, 0, 0, dimension, dimension, 16, len(compressed)))
                            chunk = 4 if dimension == 16 else 512
                            began = time.monotonic()
                            report['sent_bytes'] = 0
                            try:
                                for offset in range(0, len(compressed), chunk):
                                    send(compressed[offset:offset+chunk])
                                    report['sent_bytes'] += len(compressed[offset:offset+chunk])
                                    time.sleep(0.005)
                            finally:
                                report['delivery_ms'] = round((time.monotonic() - began) * 1000)
                            if exact(1) != bytes([3]):
                                raise ValueError('incremental request required')
                            exact(9)
                        elif outcome == 'runtime-message':
                            send(bytes([199]))
                        elif outcome == 'runtime-encoding':
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 16, 16, 123456))
                        elif outcome == 'runtime-bounds':
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 12, 0, 16, 16, 0))
                        elif outcome == 'runtime-partial':
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 16, 16, 0) + bytes(7))
                        elif outcome == 'runtime-decoder':
                            # Tight control 12 is reserved, not a valid subencoding.
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 16, 16, 7) + bytes([0xc0]))
                        else:
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 16, 16, 0) + bytes(16 * 16 * 4))
                            if outcome == 'apple-success':
                                if exact(1) != bytes([9]): raise ValueError('subscription required')
                                report['subscription'] = list(struct.unpack('>BHIHHHH',exact(15)))
                            if outcome == 'runtime-success':
                                if exact(1) != bytes([3]):
                                    raise ValueError('incremental request required')
                                exact(9)
                        report['stage'] = 'synthetic_frame_sent'
                        return report
                    else:
                        raise ValueError('unexpected message before framebuffer request')
                raise ValueError('message count bound')
    except Exception as exc:
        report['error_class'] = type(exc).__name__
        return report


if __name__ == '__main__':
    result = serve_once(sys.argv[1], sys.argv[2], 0)
    print(json.dumps(result), flush=True)
    if 'error_class' in result:
        raise SystemExit(1)
