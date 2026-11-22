"""Loopback peer whose SRP server arithmetic is the system's corecrypto.

AppleVNCServer computes security type 36 with corecrypto's ccsrp functions. This peer calls the same
exported functions of /usr/lib/system/libcorecrypto.dylib, with the same arguments, so the client under
test logs in against Apple's own arithmetic. ard_peer.py supplies everything else. Nothing is copied out
of corecrypto.

Usage: srp_oracle.py OFFERS OUTCOME. Where the library cannot be called, it prints the reason as
{"oracle_unavailable": ...} and exits.
"""
import ctypes
import hashlib
import json
import os
import pathlib
import struct
import sys
from ctypes import POINTER, byref, c_bool, c_char_p, c_int, c_size_t, c_void_p

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'Packages/RemoraKit/Tests/VNCSessionTests/Fixtures'))
import ard_peer

SIGNATURES = {
    'ccsha512_di': (c_void_p, []),
    'ccsrp_gp_rfc5054_4096': (c_void_p, []),
    'ccrng': (c_void_p, [POINTER(c_int)]),
    'ccsrp_ctx_init': (None, [c_void_p, c_void_p, c_void_p]),
    'ccsrp_generate_verifier': (c_int, [c_void_p, c_char_p, c_size_t, c_char_p, c_size_t, c_char_p, c_char_p]),
    'ccsrp_server_generate_public_key': (c_int, [c_void_p, c_void_p, c_char_p, c_char_p]),
    'ccsrp_server_compute_session': (c_int, [c_void_p, c_char_p, c_size_t, c_char_p, c_char_p]),
    'ccsrp_server_verify_session': (c_bool, [c_void_p, c_char_p, c_char_p]),
    'ccsrp_get_session_key': (c_void_p, [c_void_p, POINTER(c_size_t)]),
}


def load():
    library = ctypes.CDLL('/usr/lib/system/libcorecrypto.dylib')
    for name, (result, arguments) in SIGNATURES.items():
        function = getattr(library, name)
        function.restype, function.argtypes = result, arguments
    return library


def context(cc):
    # The context's layout is private. One for this group and hash is under 3 KiB, so 64 KiB holds it.
    memory = (ctypes.c_uint64 * 8192)()
    cc.ccsrp_ctx_init(memory, cc.ccsha512_di(), cc.ccsrp_gp_rfc5054_4096())
    return memory


def srp_login(cc):
    def login(outcome, exact, send, report):
        _, user, _, _ = ard_peer.srp_unpack('ssso', exact)
        # The salt length and iteration count that macOS 26.6.2 sent.
        salt, iterations = os.urandom(32), 19417
        stretched = hashlib.pbkdf2_hmac('sha512', ard_peer.PASSWORD, salt, iterations, 128)
        verifier, B, M2 = (ctypes.create_string_buffer(size) for size in (512, 512, 64))
        server, error, length = context(cc), c_int(), c_size_t()
        if cc.ccsrp_generate_verifier(context(cc), b'', len(stretched), stretched, len(salt), salt, verifier):
            raise ValueError('corecrypto verifier')
        if cc.ccsrp_server_generate_public_key(server, cc.ccrng(byref(error)), verifier, B):
            raise ValueError('corecrypto public key')
        challenge = bytes(1) + ard_peer.srp_pack('mmom', ard_peer.SRP_N, ard_peer.SRP_G, salt, int.from_bytes(B.raw, 'big'))
        send(ard_peer.srp_frame(challenge + struct.pack('>Q', iterations) + ard_peer.srp_pack('s', ard_peer.SRP_OPTIONS)))
        A, proof, _, _ = ard_peer.srp_unpack('moso', exact)
        if cc.ccsrp_server_compute_session(server, b'', len(salt), salt, ard_peer.srp_pad(A)):
            raise ValueError('corecrypto session')
        if len(proof) != 64 or not cc.ccsrp_server_verify_session(server, proof, M2):
            raise ValueError('corecrypto rejected the client proof')
        K = ctypes.string_at(cc.ccsrp_get_session_key(server, byref(length)), length.value)
        report['credentials_valid'] = user == ard_peer.USERNAME
        send(ard_peer.srp_frame(ard_peer.srp_pack('oos', M2.raw, os.urandom(16), b'') + bytes(4)))
        return hashlib.sha256(K).digest()[:16], A
    return login


if __name__ == '__main__':
    try:
        ard_peer.srp_login = srp_login(load())
    except (OSError, AttributeError) as reason:
        print(json.dumps({'oracle_unavailable': str(reason)}), flush=True)
        raise SystemExit(0)
    result = ard_peer.serve_once(sys.argv[1], sys.argv[2], 0)
    print(json.dumps(result), flush=True)
    if 'error_class' in result:
        raise SystemExit(1)
