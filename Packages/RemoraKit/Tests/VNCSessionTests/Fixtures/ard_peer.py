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
import zlib

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


def aes(key, data, decrypt=False, iv=None):
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
    status = crypt(int(decrypt), 0, 2 if iv is None else 0, key_buffer, len(key), iv,
                   input_buffer, len(data), output_buffer, len(output_buffer), ctypes.byref(moved))
    if status != 0 or moved.value != len(data):
        raise ValueError('CommonCrypto status/length')
    return output_buffer.raw[:moved.value]


def known_answer_check():
    key = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
    plaintext = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
    ciphertext = bytes.fromhex('3ad77bb40d7a3660a89ecaf32466ef97')
    if aes(key, plaintext) != ciphertext or aes(key, ciphertext, True) != plaintext:
        raise ValueError('NIST AES ECB known-answer mismatch')
    if P.bit_length() != 1024 or len(bytes.fromhex(PRIME_HEX)) != SIZE:
        raise ValueError('RFC group size mismatch')


class AppleRecords:
    """Independent CommonCrypto CBC stream, with deliberately nonzero filler."""
    def __init__(self, exact, send):
        self.raw_read, self.raw_send = exact, send
        self.key, self.iv = os.urandom(16), os.urandom(16)
        self.rx_iv = self.tx_iv = self.iv
        self.rx_seq = self.tx_seq = 0
        self.pending = bytearray()

    def record(self, body, fault=None):
        prefix = struct.pack('>H', len(body) + (16 if fault == 'body-length' else 0)) + body
        prefix += bytes([0xa5]) * (-(len(prefix) + 20) % 16)
        digest = hashlib.sha1(struct.pack('>I', self.tx_seq + (fault == 'sequence')) + prefix).digest()
        cipher = aes(self.key, prefix + (bytes(20) if fault == 'digest' else digest), iv=self.tx_iv)
        self.tx_seq += 1
        self.tx_iv = cipher[-16:]
        return struct.pack('>H', len(cipher)) + cipher

    def send(self, body):
        # Split messages at an interior byte and coalesce the resulting records.
        parts = [body[:3]] + [body[i:i+65498] for i in range(3, len(body), 65498)]
        self.raw_send(b''.join(self.record(part) for part in parts if part))

    def exact(self, size):
        while len(self.pending) < size:
            length, = struct.unpack('>H', self.raw_read(2))
            if length < 32 or length % 16: raise ValueError('invalid client record length')
            cipher = self.raw_read(length)
            plain = aes(self.key, cipher, True, self.rx_iv)
            self.rx_iv = cipher[-16:]
            count, = struct.unpack('>H', plain[:2])
            if length != (count + 37) // 16 * 16: raise ValueError('invalid client body length')
            digest = hashlib.sha1(struct.pack('>I', self.rx_seq) + plain[:-20]).digest()
            if digest != plain[-20:]: raise ValueError('invalid client digest')
            if any(plain[2+count:-20]): raise ValueError('client filler was not zero')
            self.rx_seq += 1
            self.pending.extend(plain[2:2+count])
        result = bytes(self.pending[:size])
        del self.pending[:size]
        return result


def mvs_bits(*parts):
    # Owned vectors from noVNC-ARD ard/tests/test.mvs.js, d6992936, MPL-2.0.
    bits = ''.join(c for part in parts for c in part if c in '01')
    bits += '0' * (-len(bits) % 8)
    return bytes(int(bits[i:i+8], 2) for i in range(0, len(bits), 8))


def display_info(width, height, selected=1, displays=None):
    if displays is None:
        displays = [(1, 0, 0, width, height, True)]
    body = struct.pack('>HHHHHIIH', 1, width, height, width, height, selected, 0, len(displays))
    for ident, x, y, w, h, main in displays:
        body += struct.pack('>ddIhhhhhhhhI', 1, 1, ident, y, x, y+h, x+w, 0, 0, h, w, int(main))+bytes(16)
    return struct.pack('>H', len(body))+body


def display_frames(outcome, exact, send, report):
    import time
    apple = outcome.startswith('apple-')
    displays = [(7, -16, 0, 16, 8, False), (42, 0, 0, 16, 8, True)]
    report['display_selections'] = []
    report['display_inputs'] = []
    def info(selected, entries=displays):
        w = 32 if selected == 0xffffffff else 16
        body = display_info(w, 8, selected, entries)
        # Exercise both legal carriers. The selected geometry need not have DesktopSize.
        if apple: send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, w, 8, 1105)+body)
        else: send(bytes([0x51])+body)
    def raw(x, w, pixel, width=16):
        send(struct.pack('>BBHHHHHi', 0, 0, 1, x, 0, w, 8, 0)+bytes(pixel)*(w*8))
    def message():
        kind = exact(1)[0]
        if kind == 10:
            exact(3); return ('mode',)
        if kind == 2:
            h=exact(3); exact(int.from_bytes(h[1:], 'big')*4); return ('encodings',)
        if kind == 0:
            exact(19); return ('format',)
        if kind == 3:
            incremental,x,y,w,h = struct.unpack('>BHHHH',exact(9))
            return ('request', incremental, w, h)
        if kind == 9:
            exact(15); return ('subscribe',)
        if kind == 0x0d:
            combine,pad,ident = struct.unpack('>BHI',exact(7))
            if combine or pad: raise ValueError('combined display request')
            report['display_selections'].append(ident)
            return ('select',ident)
        if kind == 4:
            down,_,symbol=struct.unpack('>BHI',exact(7))
            report['display_inputs'].append([255,down,symbol]); return ('input',)
        if kind == 5:
            report['display_inputs'].append(list(exact(5))); return ('input',)
        raise ValueError('unexpected display client record '+str(kind))
    def wait(kind, value=None):
        for _ in range(200):
            m=message()
            if m[0]==kind and (value is None or m[1]==value): return m
        raise ValueError('missing display record '+kind)
    info(0xffffffff)
    wait('select',42)
    # In-flight old combined pixels are valid protocol but must never reach FrameSink.
    raw(0,32,(238,238,238,255),32)
    info(42)
    wait('request',0)
    raw(0,8,(1,2,3,255))
    time.sleep(0.08)
    raw(8,8,(1,2,3,255))
    wait('select',7)
    report['inputs_before_second_selection'] = len(report['display_inputs'])
    # Same framebuffer dimensions do not identify the display; metadata is the fence.
    raw(0,16,(239,239,239,255))
    info(7)
    wait('request',0)
    raw(0,8,(4,5,6,255))
    if 'timeout' in outcome:
        wait('select',42)
        info(42)
        wait('request',0)
        raw(0,16,(7,8,9,255))
        time.sleep(0.15)
        report['stage']='display_timeout_retried'
        return
    time.sleep(0.08)
    raw(8,8,(4,5,6,255))
    # The selected display disappears. Backend must choose the remaining main display.
    time.sleep(0.08)
    info(0xffffffff, [(42, 0, 0, 16, 8, True)])
    wait('select',42)
    info(42, [(42, 0, 0, 16, 8, True)])
    wait('request',0)
    raw(0,16,(7,8,9,255))
    time.sleep(0.15)
    report['stage'] = 'display_switches_complete'


def packed_flavor(uti, data, tags=()):
    def counted(value): return struct.pack('>I', len(value)) + value
    return (counted(uti) + struct.pack('>II', 0, len(tags))
            + b''.join(counted(key) + counted(value) for key, value in tags) + counted(data))


TEXT_UTI = b'public.utf8-plain-text'


def apple_clipboard(outcome, client_message, send, report):
    def reply(archive, sync=False, declared=None):
        send(bytes.fromhex('14 00 00 04 00 01 00 02'))
        while client_message() != 0x0b: pass
        request = report['clipboard_requests'][-1]
        if archive is None:
            plain, compressed, payload = declared
            send(struct.pack('>BBBBIII', 0x1f, 0, 0, 0, request, plain, compressed) + payload)
            return
        compressor = zlib.compressobj()
        payload = compressor.compress(archive) + compressor.flush(zlib.Z_SYNC_FLUSH if sync else zlib.Z_FINISH)
        plain = len(archive) if declared is None else declared
        send(struct.pack('>BBBBIII', 0x1f, 0, 0, 0, request, plain, len(payload)) + payload)

    def text_item(data): return struct.pack('>I', 1) + packed_flavor(TEXT_UTI, data)

    if outcome == 'apple-clipboard-limit':
        # Archives over the local limit, such as a copied image, are drained and the session goes on.
        large = 8 * 1024 * 1024 + 1
        reply(None, declared=(1, large, bytes(large)))
        reply(None, declared=(large, 16, bytes(16)))
        reply(text_item(b'after a large image'))
    elif outcome == 'apple-clipboard-wire-limit':
        reply(None, declared=(1, 100 * 1024 * 1024 + 1, b''))
    elif outcome == 'apple-clipboard-length':
        archive = text_item(b'longer than declared')
        reply(archive, declared=len(archive) - 1)
    elif outcome == 'apple-clipboard-malformed':
        # A complete text item followed by a flavor with a truncated UTI.
        reply(text_item(b'do not publish') + struct.pack('>II', 1, 100) + b'x')
    else:
        rich = packed_flavor(b'public.rtf', hashlib.shake_256(b'fixture').digest(1_100_000),
                             [(b'public.mime-type', b'text/rtf')])
        reply(struct.pack('>I', 2) + rich + packed_flavor(TEXT_UTI, 'from Mac ✓\0'.encode()), sync=True)
        while len(report['clipboard_uploads']) < 2: client_message()
        reply(text_item(b'\xff'))
        reply(struct.pack('>I', 1) + packed_flavor(b'public.png', b'image bytes'))
        reply(text_item(b'x' * (1024 * 1024 + 1)))


def apple_frames(outcome, exact, send, report, connection):
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
    if outcome.startswith('apple-clipboard'):
        report['clipboard_requests'] = []
        report['clipboard_uploads'] = []

    def client_message():
        kind = exact(1)[0]
        if kind == 9:
            fields = struct.unpack('>BHIHHHH',exact(15))
            report['subscriptions'].append(list(fields))
        elif kind == 4:
            down, _, symbol = struct.unpack('>BHI', exact(7))
            report['keys'].append([symbol, down])
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
        elif kind == 0x0b and outcome.startswith('apple-clipboard'):
            flags, reserved, request = struct.unpack('>BHI', exact(7))
            if flags or reserved or request in report['clipboard_requests']:
                raise ValueError('full clipboard request with a fresh ID required')
            report['clipboard_requests'].append(request)
        elif kind == 0x1f and outcome == 'apple-clipboard':
            padding, flags, reserved, request, plain, compressed = struct.unpack('>BBBIII', exact(15))
            if padding or flags or reserved or request or not 0 < compressed <= 2 * 1024 * 1024:
                raise ValueError('clipboard upload header')
            inflater = zlib.decompressobj()
            archive = inflater.decompress(exact(compressed), 2 * 1024 * 1024)
            if len(archive) != plain or inflater.unused_data or inflater.unconsumed_tail:
                raise ValueError('clipboard upload length')
            index = len(report['clipboard_uploads'])
            wanted = 'from viewer 🦀'.encode() if index == 0 else b''
            expected = struct.pack('>I', 1) + packed_flavor(TEXT_UTI, wanted) if wanted else bytes(4)
            if archive != expected: raise ValueError('clipboard upload archive')
            report['clipboard_uploads'].append(wanted.decode())
        elif kind == 3:
            request = struct.unpack('>BHHHH', exact(9))
            if request != (0,0,0,16,8): raise ValueError('full non-incremental request required')
            report['requests_after_initial'] += 1
        else: raise ValueError('unexpected Apple client message')
        return kind
    # A valid server may wait for the automatic-update subscription before its
    # first frame, even after admitting the initial explicit full request.
    for _ in range(64):
        if client_message()==9: break
    else: raise ValueError('missing startup subscription')
    if report['subscriptions'][-1] != [0,1,0,0,0,16,8]: raise ValueError('subscription region')
    report['subscribed_before_baseline'] = True
    send(bytes([0x51])+display_info(16, 8))
    if outcome == 'apple-large-records':
        # Each direction carries one ordinary RFB message larger than a record.
        expected = b'x' * 70000
        envelope = struct.pack('>B3xI', 3, len(expected))
        send(envelope + expected)
        if [client_message(), client_message()] != [4, 4] or report['keys'] != [[0xffe7,1], [0xffe7,0]]:
            raise ValueError('encrypted key events')
        if exact(8) != bytes([6]) + envelope[1:] or exact(len(expected)) != expected:
            raise ValueError('large encrypted CutText')
        update(full)
        return
    if outcome in ('apple-regions', 'apple-region-uninitialized'):
        one_header = mvs_bits('0', '101 0', marker('m'))
        one_body = mvs_bits('0 0 0', '00', '00', '1110 010 1', '0 01 0', marker('m'))
        one_full = bytes([0,15,25])+(6+len(one_header)).to_bytes(3,'big')+one_header+one_body
        one_partial = bytes([1,14,19])+mvs_bits('01','000000','1 0','1010','0','1010',marker('mvs'))
        update(one_full, rect=(8,0,8,8))
        if outcome == 'apple-region-uninitialized':
            # The client skips a partial update over pixels it lacks and asks for the screen in full.
            update(one_partial, rect=(0,0,8,8))
            before = report['requests_after_initial']
            while report['requests_after_initial'] == before: client_message()
            update(one_full, rect=(0,0,8,8)); return
        update(one_partial, rect=(8,0,8,8))
        update(one_full, rect=(0,0,8,8))
        update(one_partial, rect=(0,0,8,8))
        return
    if outcome == 'apple-no-baseline':
        update(partial)
        before = report['requests_after_initial']
        while report['requests_after_initial'] == before: client_message()
        update(full); return
    if outcome == 'apple-truncated':
        send(struct.pack('>BBHHHHHiI',0,0,1,0,0,16,8,1011,100)+b'\x00'); return
    if outcome.startswith('apple-retry-'):
        if outcome == 'apple-retry-empty': send(bytes(4))
        # These vectors have only DC coefficients; retain their known DC quantizers.
        elif outcome == 'apple-retry-quant': update(bytes([2])+bytes([16])*64+bytes([19])*64, rect=(0,0,0,0))
        elif outcome == 'apple-retry-raw': update(bytes([148,148,148,255])*64, 0, (0,0,8,8))
        elif outcome == 'apple-retry-controls': send(bytes([4,7,0x14,0,0,4,0,0,0,0]))
        # Drop the initial request, and in the dropped case also its first retry.
        retries = 2 if outcome == 'apple-retry-dropped' else 1
        for _ in range(64):
            if client_message()==3 and report['requests_after_initial']==retries: break
        else: raise ValueError('missing baseline retry')
        report['baseline_retry_ms'] = round((time.monotonic()-began)*1000)
        if outcome == 'apple-retry-hidden': time.sleep(0.1)
    update(full)
    if outcome == 'apple-hidden-baseline':
        for _ in range(64):
            if client_message()==3: break
        else: raise ValueError('missing resume refresh')
        report['baseline_retry_ms'] = round((time.monotonic()-began)*1000)
    if outcome == 'apple-geometry':
        update(b'',-223,(0,0,32,8)); return
    if outcome == 'apple-multi-invalid':
        # A valid Raw rectangle followed by an invalid encoding must not publish a half frame.
        send(struct.pack('>BBH',0,0,2)+struct.pack('>HHHHi',0,0,16,8,0)+bytes(16*8*4)+struct.pack('>HHHHi',0,0,16,8,123456)); return
    if outcome == 'apple-control-encryption':
        update(struct.pack('>I', 2) + bytes(32), 1103, (0,0,0,0)); return
    if outcome == 'apple-clipboard-early': return
    if outcome.startswith('apple-clipboard'):
        apple_clipboard(outcome, client_message, send, report)
        if outcome == 'apple-clipboard':
            update(partial); update(cache)
        return
    if outcome == 'apple-damage':
        # Quantization, skips, invalid match sources and unwritten cache slots write no pixels.
        update(bytes([1,14,19])+mvs_bits('00 00',marker('mvs')))
        update(bytes([1,14,19])+mvs_bits('10 00',marker('mvs')))
        update(bytes([1,14,19])+mvs_bits('11 0 1111110111100111','00',marker('mvs')))
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
        # The decoder writes both tiles before rejecting this body marker. Never publish them.
        update(full[:-1]+bytes([full[-1]^0x80]))
        return
    # Known control messages and discarded legacy clipboard may precede the next update.
    send(bytes([4,7,0x14,0,0,4,0,0,0,0]))
    send(bytes([3,0,0,0])+struct.pack('>I',5)+b'owned')
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
        update(full)  # The redraw the resume asked for.
    elif outcome.startswith('apple-retry-') or outcome == 'apple-hidden-baseline':
        # A baseline must stop retries, including across more than one retry interval.
        if select.select([connection],[],[],1.2)[0]:
            client_message()
            raise ValueError('unexpected client message after baseline')


def accepted(listener, report, deadline):
    """Yield each accepted connection in turn. Leaving the loop closes the last one."""
    import time
    while True:
        listener.settimeout(max(0.001, deadline - time.monotonic()))
        connection, _ = listener.accept()
        report['attempts'] += 1
        with connection:
            yield connection


def serve_once(offer_mode, outcome, port):
    # Imported only for the explicitly requested listener subcommand. This
    # helper has no remote host argument, DNS call, connect call, or retry loop.
    # Only an init-withheld outcome accepts a second connection, from the client.
    import socket
    import time
    known_answer_check()
    report = {'synthetic_only': True, 'attempts': 0, 'stage': 'listen', 'credentials_valid': False}
    # A withheld ServerInit holds the client for its ten-second read deadline.
    withheld = outcome.endswith(('init-withheld', 'init-withheld-once'))
    withheld_public = None
    stalled = outcome.startswith('apple-init-stalled-')
    deadline = time.monotonic() + (16 if withheld or stalled or 'display-timeout' in outcome or outcome == 'apple-retry-hidden' else 10)
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
            print(json.dumps({'loopback_port': listener.getsockname()[1]}), flush=True)
            for connection in accepted(listener, report, deadline):
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
                send(b'RFB 003.008\n' if outcome=='apple-wrong-banner' or outcome.startswith(('runtime-', 'fragmented-')) else b'RFB 003.889\n')
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
                if withheld_public is not None:
                    report['fresh_exchange'] = client_public != withheld_public
                shared = fixed(pow(client_public, SERVER_EXPONENT, P))
                plaintext = aes(hashlib.md5(shared).digest(), ciphertext, True)
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
                name = (bytes(2)+struct.pack('>I',4 if outcome=='apple-session-select' else 0)+bytes(16) if apple and outcome!='apple-no-extension' else b'') + b'synthetic-ard-peer'
                dimension = 256 if outcome == 'fragmented-large' else 16
                height = 8 if apple and outcome != 'apple-success' else dimension
                server_init = struct.pack('>HHBBBBHHHBBBBBBI', dimension, height, 32, 24, 0, 1,
                                          255, 255, 255, 16, 8, 0, 0, 0, 0, len(name))
                prefetched = int(outcome.rsplit('-',1)[1]) if outcome.startswith('apple-init-stalled-prefetched-') else 0
                # One peer write makes the success result and early header prefix
                # available to the client's greedy AuthResult socket read together.
                send(struct.pack('>I', 0) + server_init[:prefetched])
                report['security_result'] = 0
                report['stage'] = 'client_init'
                report['client_init'] = exact(1)[0]
                if report['client_init'] != (0x81 if apple else 1):
                    raise ValueError('ordinary shared ClientInit required')
                if outcome == 'server-init-eof':
                    report['stage'] = 'intentional_server_init_eof'
                    return report
                if stalled:
                    if outcome == 'apple-init-stalled-partial': send(server_init[:1])
                    if outcome == 'apple-init-stalled-name': send(server_init + name[:1])
                    report['stage'] = 'server_init_prefix_stalled'
                    report['prefetched_prefix_sent'] = prefetched
                    try: exact(1)
                    except EOFError: report['closed_without_input'] = True
                    else: raise ValueError('client input after incomplete ServerInit')
                    listener.settimeout(0.5)
                    try: extra, _ = listener.accept()
                    except socket.timeout:
                        report['second_connection'] = False; return report
                    report['second_connection'] = True
                    report['attempts'] += 1
                    extra.close()
                    raise ValueError('client retried a partial ServerInit')
                if withheld and report['attempts'] == 1:
                    # Authenticated, ClientInit read, and no ServerInit. The client
                    # must close this connection without sending anything more.
                    report['stage'] = 'server_init_withheld'
                    report['withheld_client_init'] = report['client_init']
                    withheld_public = client_public
                    try: exact(1)
                    except EOFError: report['withheld_closed_without_input'] = True
                    else: raise ValueError('client data after withheld ServerInit')
                    if outcome.endswith('-once'):
                        listener.settimeout(0.5)
                        try: extra, _ = listener.accept()
                        except socket.timeout:
                            report['second_connection'] = False; return report
                        extra.close()
                        raise ValueError('unexpected second connection')
                    continue
                send(server_init + name)
                if outcome in ('apple-no-extension','apple-session-select'):
                    try: exact(1)
                    except EOFError:
                        report['unsupported_init_rejected']=True; return report
                    raise ValueError('profile continued after unsupported ServerInit')
                records = None
                report['stage'] = 'framebuffer_request'
                for _ in range(10):
                    kind = exact(1)[0]
                    if apple and records is None and kind not in (0x21, 10, 0x15, 0x12):
                        raise ValueError('clear application write before encryption')
                    elif kind == 0x21 and apple:
                        wanted = (struct.pack('>BHH7I', 0, 62, 1, 2, 6, 1, 0, 26, 6, 2)
                                  + bytes.fromhex('b0 00 0c 03 90 00 00 00 00 00 40') + bytes(21))
                        if exact(65) != wanted: raise ValueError('ViewerInfo framing')
                        report['viewer_info'] = True
                    elif kind == 10 and apple:
                        if exact(3) != bytes([0, 0, 1]): raise ValueError('control SetMode required')
                        report['control_mode'] = True
                    elif kind == 0x15 and apple:
                        if not report.get('viewer_info') or not report.get('control_mode') or exact(7) != bytes.fromhex('00 00 01 00 00 00 00'):
                            raise ValueError('AutoPasteboard must follow ViewerInfo and SetMode')
                        report['pasteboard_monitoring'] = True
                    elif kind == 0x12 and apple:
                        if not report.get('control_mode'): raise ValueError('SetMode required')
                        if exact(11) != bytes.fromhex('00 0001 0001 0001 00000001'): raise ValueError('SetEncryption proposal')
                        if exact(8) != bytes.fromhex('1200 0002 0001 0000'): raise ValueError('SetEncryption activation')
                        records = AppleRecords(exact, send)
                        key_rect = struct.pack('>BBHHHHHiI', 0, 0, 1, 0, 0, 0, 0, 1103, 1)
                        key_rect += aes(hashlib.md5(shared).digest(), records.key + records.iv)
                        if outcome == 'apple-no-key':
                            try: exact(1)
                            except EOFError: return report
                            raise ValueError('client sent clear application data')
                        if outcome == 'apple-refuse':
                            # The server ignores the proposal and sends a clear pixel rectangle.
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 1, 1, 0) + bytes(4))
                            return report
                        # Prefetch a record header alongside the key. Split its ciphertext across TCP reads.
                        first = records.record(bytes([7, 7]))
                        # A pasteboard change before the key must still be fetched after activation.
                        change = 2 if outcome == 'apple-clipboard-early' else 0
                        send(bytes([2, 0x14, 0, 0, 4, 0, 1 if change else 0, 0, change]) + key_rect + first[:5])
                        time.sleep(0.015)
                        send(first[5:])
                        exact, send = records.exact, records.send
                        if outcome.startswith('apple-invalid-'):
                            fault = outcome[len('apple-invalid-'):]
                            frame = struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 16, 8, 0) + bytes(512)
                            records.raw_send(bytes.fromhex('0021') if fault == 'length' else records.record(frame, fault))
                            connection.shutdown(socket.SHUT_WR)
                            while connection.recv(4096): pass
                            return report
                    elif kind == 0x0b and outcome == 'apple-clipboard-early':
                        request = struct.unpack('>BHI', exact(7))[2]
                        archive = struct.pack('>I', 1) + packed_flavor(TEXT_UTI, b'changed during setup')
                        payload = zlib.compress(archive)
                        send(struct.pack('>BBBBIII', 0x1f, 0, 0, 0, request, len(archive), len(payload)) + payload)
                        report['early_clipboard_fetched'] = True
                    elif kind == 0:
                        exact(19)
                    elif kind == 2:
                        header = exact(3)
                        count = int.from_bytes(header[1:], 'big')
                        if count > 512:
                            raise ValueError('encoding count bound')
                        encodings = struct.unpack('>' + 'i'*count, exact(count * 4))
                        if apple and not {1011, 1103}.issubset(encodings): raise ValueError('Apple encodings missing')
                    elif kind == 3:
                        request = exact(9)
                        if apple and (not report.get('control_mode') or request != struct.pack('>BHHHH',0,0,0,dimension,height)):
                            raise ValueError('initial full request must follow SetMode')
                        if outcome.startswith('apple-clipboard') and not report.get('pasteboard_monitoring'):
                            raise ValueError('pasteboard monitoring required during startup')
                        if outcome in ('apple-displays','standard-displays','apple-display-timeout','standard-display-timeout'):
                            display_frames(outcome,exact,send,report); return report
                        if not apple and outcome == 'success':
                            send(bytes([0x51])+display_info(16,16))
                        if apple and outcome != 'apple-success':
                            apple_frames(outcome,exact,send,report,connection)
                            # Deliver every queued frame before closing, including when
                            # the native driver has sent input that this case ignores.
                            connection.shutdown(socket.SHUT_WR)
                            while connection.recv(4096): pass
                        elif outcome in ('fragmented-small', 'fragmented-large'):
                            compressed = synthetic_zrle(dimension)
                            report['compressed_bytes'] = len(compressed)
                            send(struct.pack('>BBHHHHHiI', 0, 0, 1, 0, 0, dimension, dimension, 16, len(compressed)))
                            # 160 balanced writes leave the client well over the 100 readiness waits that the old
                            # retry count allowed, even when a reader pause merges some of them. A fixed count, not a
                            # fixed size, keeps the delivery inside the client's 10 s read deadline where each short
                            # sleep takes far longer than 5 ms.
                            writes = 160
                            began = time.monotonic()
                            report['sent_bytes'] = 0
                            try:
                                for index in range(writes):
                                    part = compressed[len(compressed)*index//writes:len(compressed)*(index+1)//writes]
                                    send(part)
                                    report['sent_bytes'] += len(part)
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
                            if outcome == 'apple-success':
                                if exact(1) != bytes([9]): raise ValueError('subscription required')
                                report['subscription'] = list(struct.unpack('>BHIHHHH',exact(15)))
                                if report['subscription'] != [0,1,0,0,0,16,16]: raise ValueError('subscription region')
                                report['subscribed_before_baseline'] = True
                                send(bytes([0x51])+display_info(16, 16))
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 16, 16, 0) + bytes(16 * 16 * 4))
                            if outcome == 'runtime-success':
                                while True:
                                    kind=exact(1)[0]
                                    if kind==3: exact(9); break
                                    if kind==9: exact(15)
                                    elif kind==10: exact(3)
                                    elif kind==0: exact(19)
                                    elif kind==2:
                                        head=exact(3); exact(int.from_bytes(head[1:],'big')*4)
                                    else: raise ValueError('incremental request required')
                        report['stage'] = 'synthetic_frame_sent'
                        if outcome in ('success','apple-success'):
                            connection.shutdown(socket.SHUT_WR)
                            while connection.recv(4096): pass
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
