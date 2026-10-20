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
        'unknown-ard': [30, 250],
        'apple-vnc': [33, 35, 36, 2],
        'apple-none': [33, 35, 36, 1],
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
                send(b'RFB 003.889\n')
                if exact(12) != b'RFB 003.008\n':
                    raise ValueError('ordinary RFB 3.8 reply required')
                report['stage'] = 'security_selection'
                send(bytes([len(offers)] + offers))
                if outcome == 'expect-policy-reject':
                    try:
                        exact(1)
                    except EOFError:
                        report['stage'] = 'policy_rejected_before_selection'
                        report['selector_received'] = False
                        return report
                    raise ValueError('unexpected selector after mixed offer')
                selection = exact(1)[0]
                report['selected_security_id'] = selection
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
                if not valid or outcome == 'reject':
                    reason = b'synthetic fixture rejection'
                    send(struct.pack('>II', 1, len(reason)) + reason)
                    report['security_result'] = 1
                    return report
                send(struct.pack('>I', 0))
                report['security_result'] = 0
                report['stage'] = 'client_init'
                report['client_init'] = exact(1)[0]
                if report['client_init'] != 1:
                    raise ValueError('ordinary shared ClientInit required')
                if outcome == 'server-init-eof':
                    report['stage'] = 'intentional_server_init_eof'
                    return report
                name = b'synthetic-ard-peer'
                send(struct.pack('>HHBBBBHHHBBBBBBI', 16, 16, 32, 24, 0, 1,
                                 255, 255, 255, 16, 8, 0, 0, 0, 0, len(name)) + name)
                report['stage'] = 'framebuffer_request'
                for _ in range(8):
                    kind = exact(1)[0]
                    if kind == 0:
                        exact(19)
                    elif kind == 2:
                        header = exact(3)
                        count = int.from_bytes(header[1:], 'big')
                        if count > 512:
                            raise ValueError('encoding count bound')
                        exact(count * 4)
                    elif kind == 3:
                        exact(9)
                        if outcome == 'runtime-message':
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
