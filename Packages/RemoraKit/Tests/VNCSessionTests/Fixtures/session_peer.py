"""Literal-loopback RFB peer for public session scheduling/geometry tests.

One connection, a one-minute backstop deadline, no external hosts or credentials.
The reader processes input independently of any paced framebuffer writer.
A paced body goes out in a fixed number of writes, not writes of a fixed size. Where each short
sleep takes several times longer, as on a virtualized runner, the body then still arrives well
within the client's 10 s read deadline. In the paced-small and paced-large modes, the body stops
halfway until the test sends `finish`, so the frame stays incomplete however late the test's
input comes. A 5 s backstop, below the client's read deadline, then sends the rest anyway.
"""
import json
import selectors
import socket
import struct
import sys
import threading
import time

PACED_WRITES = 100
output_lock = threading.Lock()
def report(event, **fields):
    with output_lock:
        print(json.dumps(dict(event=event, **fields)), flush=True)

def serve():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'refresh'
    dimension = 256 if mode in ('paced-large', 'early-large') else 16
    target_width, target_height = (map(int, sys.argv[2:4]) if mode.startswith('size') else ((32, 16) if mode == 'perf' else (dimension, dimension)))
    width, height = (target_width, target_height) if mode == 'size' else (dimension, dimension)
    began = None
    intentional_close = threading.Event()
    body_finished = threading.Event()
    finish_body = threading.Event()
    deadline = time.monotonic() + 60
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(60)
        report('listen', port=listener.getsockname()[1])
        connection, _ = listener.accept()
        with connection:
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            def exact(count):
                data = bytearray()
                while len(data) < count:
                    connection.settimeout(max(0.001, deadline-time.monotonic()))
                    part = connection.recv(count-len(data))
                    if not part:
                        raise EOFError()
                    data.extend(part)
                return data
            def send(data):
                connection.settimeout(max(0.001, deadline-time.monotonic()))
                connection.sendall(data)
            send(b'RFB 003.008\n')
            assert exact(12) == b'RFB 003.008\n'
            send(bytes([1, 1]))
            assert exact(1) == bytes([1])
            send(bytes(4))
            assert exact(1) == bytes([1])
            send(struct.pack('>HHBBBBHHHBBBBBBI', width, height, 32, 24, 0, 1,
                             255, 255, 255, 16, 8, 0, 0, 0, 0, 0))
            full = incremental = 0
            pending = False
            marker = 1
            perf_started = False
            request_set = []
            preparation_index = 0
            response_lock = threading.Lock()
            if mode == 'prepare':
                import zlib
                from ard_peer import synthetic_zrle
                encoder = zlib.compressobj()
                prepared_payloads = [synthetic_zrle(16, encoder) for _ in range(3)]
            def prepared_response(index):
                started = time.monotonic()
                report('preparation', index=index, at_us=round(started*1e6))
                time.sleep(0.20)
                with response_lock:
                    try:
                        payload = prepared_payloads[index-1]
                        report('response_header', index=index, at_us=round(time.monotonic()*1e6))
                        send(struct.pack('>BBHHHHHiI', 0, 0, 1, 0, 0, 16, 16, 16, len(payload)))
                        for part in range(20):
                            if part == 19: report('response_body_end', index=index, at_us=round(time.monotonic()*1e6))
                            send(payload[len(payload)*part//20:len(payload)*(part+1)//20])
                            time.sleep(0.015)
                        report('response_done', index=index, at_us=round(time.monotonic()*1e6))
                    except Exception:
                        if not intentional_close.is_set(): report('error', code='preparation_writer')
            def update(full_frame=False):
                nonlocal pending
                if pending:
                    # Full requests receive the entire requested area. A changed
                    # first pixel can satisfy outstanding incremental requests.
                    w, h = (width, height) if full_frame else (1, 1)
                    pixels = bytes([1, 0, 0, 0]) * (w*h)
                    pixels = bytes([marker, 0, 0, 0]) + pixels[4:]
                    if mode == 'early-geometry' and w == dimension+1:
                        pixels = pixels[:-4] + bytes([7, 0, 0, 0])
                    send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, w, h, 0) + pixels)
                    if mode == 'refresh-separate':
                        request_set.remove(False) if full_frame else request_set.pop(0)
                    else:
                        request_set.clear()
                    pending = bool(request_set)
            selector = selectors.DefaultSelector()
            selector.register(connection, selectors.EVENT_READ, 'network')
            selector.register(sys.stdin, selectors.EVENT_READ, 'command')
            while time.monotonic() < deadline:
                for key, _ in selector.select(0.02):
                    if key.data == 'command':
                        line = sys.stdin.readline()
                        if not line:
                            return
                        command = json.loads(line)
                        if command['action'] == 'counts':
                            report('counts', full=full, incremental=incremental)
                        elif command['action'] == 'clipboard':
                            assert mode == 'clipboard'
                            import zlib
                            # Extended text sizes include exactly one protocol
                            # terminator. Embedded NULs remain text bytes.
                            for text in (b'hello\x00', b'\x00', 'hé\x00€'.encode('utf-8') + b'\x00'):
                                encoder = zlib.compressobj()
                                compressed = encoder.compress(struct.pack('>I', len(text)) + text)
                                compressed += encoder.flush(zlib.Z_SYNC_FLUSH)
                                payload = struct.pack('>I', 0x10000001) + compressed
                                send(struct.pack('>B3xi', 3, -len(payload)) + payload)
                            # Basic Latin-1 has only an explicit byte count.
                            text = b'\xe9\x00B\x00'
                            send(struct.pack('>B3xI', 3, len(text)) + text)
                            report('clipboard_sent', count=4)
                        elif command['action'] == 'invalid':
                            send(struct.pack('>BBHHHHHiI', 0, 0, 1, 0, 0, 16, 16, 16, 4) + bytes([255])*4)
                        elif command['action'] == 'damage':
                            marker = 3
                            update()
                        elif command['action'] == 'reset':
                            intentional_close.set()
                            connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))
                            connection.close()
                            report('reset')
                            return
                        elif command['action'] == 'close':
                            intentional_close.set()
                            connection.shutdown(socket.SHUT_WR)
                            report('closed')
                            return
                        elif command['action'] == 'resize':
                            assert pending
                            pending = False
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, target_width, target_height, -223))
                            width, height = target_width, target_height
                        elif command['action'] == 'perf':
                            assert mode == 'perf' and full+incremental == 3
                            import zlib
                            from ard_peer import synthetic_zrle
                            compressor = zlib.compressobj()
                            first = synthetic_zrle(16, compressor)
                            second = synthetic_zrle(16, compressor)
                            began = time.monotonic()
                            prefix = struct.pack('>BBHHHHHiI', 0, 0, 65535, 0, 0, 16, 16, 16, len(first))
                            tail = (struct.pack('>HHHHiI', 16, 0, 16, 16, 16, len(second)) + second +
                                    struct.pack('>HHHHi', 0, 0, 0, 0, -239) +
                                    struct.pack('>HHHHi', 0, 0, 0, 0, -224) + bytes(4))
                            report('expected', first=len(first), second=len(second), logical=4+16+len(first)+16+len(second)+24)
                            perf_started = True
                            def perf_writer():
                                try:
                                    send(prefix)
                                    step = -(-(len(first)-4) // PACED_WRITES)
                                    for offset in range(0, len(first)-4, step):
                                        send(first[offset:min(offset+step, len(first)-4)])
                                        if offset == 0: report('body_started')
                                        time.sleep(0.007)
                                    send(first[-4:] + tail)
                                    report('body_done', ms=round((time.monotonic()-began)*1000))
                                except Exception:
                                    if not intentional_close.is_set(): report('error', code='writer')
                            threading.Thread(target=perf_writer, daemon=True).start()
                        elif command['action'] == 'start':
                            assert pending
                            pending = False
                            request_set.clear()
                            from ard_peer import synthetic_zrle
                            payload = synthetic_zrle(dimension)
                            if mode.startswith('early-'):
                                import zlib
                                report('marker', value=zlib.decompressobj().decompress(payload)[1])
                            began = time.monotonic()
                            count = 65535 if mode == 'early-last' else (2 if mode in ('early-cursor', 'early-geometry') else 1)
                            prefix = struct.pack('>BBH', 0, 0, count)
                            if mode == 'early-cursor': prefix += struct.pack('>HHHHi', 0, 0, 0, 0, -239)
                            prefix += struct.pack('>HHHHiI', 0, 0, dimension, dimension, 16, len(payload))
                            if mode == 'early-empty':
                                body_finished.set()
                                send(bytes(4))
                                report('body_done', ms=0)
                                continue
                            send(prefix)
                            def writer():
                                try:
                                    chunk = len(payload) if mode == 'unpaced' else -(-len(payload) // PACED_WRITES)
                                    for offset in range(0, len(payload), chunk):
                                        if offset == chunk*(PACED_WRITES//2) and mode.startswith('paced-'):
                                            finish_body.wait(5)
                                        if offset+chunk >= len(payload): body_finished.set()
                                        send(payload[offset:offset+chunk])
                                        if offset == 0:
                                            report('body_started')
                                        if mode != 'unpaced':
                                            time.sleep(0.007)
                                    if mode == 'early-last': send(struct.pack('>HHHHi', 0, 0, 0, 0, -224))
                                    if mode == 'early-geometry':
                                        send(struct.pack('>HHHHi', 0, 0, dimension+1, dimension+1, -223))
                                    report('body_done', ms=round((time.monotonic()-began)*1000))
                                except Exception as error:
                                    if not intentional_close.is_set():
                                        report('error', code=type(error).__name__)
                            if mode == 'early-geometry': width = height = dimension+1
                            threading.Thread(target=writer, daemon=True).start()
                        elif command['action'] == 'finish':
                            finish_body.set()
                        elif command['action'] == 'stop':
                            return
                        continue
                    kind = exact(1)[0]
                    if kind == 0:
                        exact(19)
                    elif kind == 2:
                        header = exact(3)
                        exact(int.from_bytes(header[1:], 'big')*4)
                        if mode == 'clipboard':
                            # Text Caps with Request, Notify and Provide support.
                            caps = struct.pack('>II', 0x1b000001, 1048576)
                            send(struct.pack('>B3xi', 3, -len(caps)) + caps)
                    elif kind == 3:
                        request = exact(9)
                        pending = True
                        request_set.append(bool(request[0]))
                        if request[0]:
                            incremental += 1
                            if mode == 'prepare' and preparation_index < 3:
                                preparation_index += 1
                                threading.Thread(target=prepared_response, args=(preparation_index,), daemon=True).start()
                        else:
                            full += 1
                            if mode in ('refresh', 'refresh-separate', 'prepare', 'size', 'size-resize') or mode.startswith('early-'):
                                update(full_frame=True)
                        if mode == 'perf' and full+incremental == 1:
                            # Legal resize metadata causes a full request inside
                            # the parser plus its normal trailing incremental.
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 32, 16, -223))
                        if mode == 'perf' and perf_started and full+incremental == 5:
                            send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 16, 16, 0) + bytes(2))
                            intentional_close.set()
                            connection.shutdown(socket.SHUT_WR)
                        report('request', full=full, incremental=incremental, body_finished=body_finished.is_set(), ms=round((time.monotonic()-began)*1000) if began else 0, x=int.from_bytes(request[1:3], 'big'), y=int.from_bytes(request[3:5], 'big'), w=int.from_bytes(request[5:7], 'big'), h=int.from_bytes(request[7:9], 'big'))
                    elif kind == 4:
                        key_event = exact(7)
                        if key_event[0] and mode == 'refresh':
                            marker = 2
                            update()
                        report('key', down=key_event[0], symbol=int.from_bytes(key_event[3:], 'big'), body_finished=body_finished.is_set(), ms=round((time.monotonic()-began)*1000) if began else 0)
                    elif kind == 5:
                        pointer = exact(5)
                        report('pointer', x=int.from_bytes(pointer[1:3], 'big'), y=int.from_bytes(pointer[3:5], 'big'), mask=pointer[0])
                    else:
                        raise ValueError('unexpected client message')
    raise TimeoutError()

try:
    serve()
except EOFError:
    pass
except Exception as error:
    report('error', code=type(error).__name__)
    raise SystemExit(1)
