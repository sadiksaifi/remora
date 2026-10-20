"""Literal-loopback RFB peer for public session scheduling/geometry tests.

One connection, ten-second total deadline, no external hosts or credentials.
The reader processes input independently of any paced framebuffer writer.
"""
import json
import selectors
import socket
import struct
import sys
import threading
import time

output_lock = threading.Lock()
def report(event, **fields):
    with output_lock:
        print(json.dumps(dict(event=event, **fields)), flush=True)

def serve():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'refresh'
    dimension = 256 if mode == 'paced-large' else 16
    target_width, target_height = (map(int, sys.argv[2:4]) if mode.startswith('size') else (dimension, dimension))
    width, height = (target_width, target_height) if mode == 'size' else (dimension, dimension)
    began = None
    intentional_close = threading.Event()
    deadline = time.monotonic() + 10
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(10)
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
            def update(full_frame=False):
                nonlocal pending
                if pending:
                    # Full requests receive the entire requested area. A changed
                    # first pixel can satisfy outstanding incremental requests.
                    w, h = (width, height) if full_frame else (1, 1)
                    pixels = bytes([1, 0, 0, 0]) * (w*h)
                    pixels = bytes([marker, 0, 0, 0]) + pixels[4:]
                    send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, w, h, 0) + pixels)
                    pending = False
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
                        elif command['action'] == 'start':
                            assert pending
                            pending = False
                            from ard_peer import synthetic_zrle
                            payload = synthetic_zrle(dimension)
                            began = time.monotonic()
                            send(struct.pack('>BBHHHHHiI', 0, 0, 1, 0, 0, dimension, dimension, 16, len(payload)))
                            def writer():
                                try:
                                    chunk = len(payload) if mode == 'unpaced' else (4 if dimension == 16 else 512)
                                    for offset in range(0, len(payload), chunk):
                                        send(payload[offset:offset+chunk])
                                        if offset == 0:
                                            report('body_started')
                                        if mode != 'unpaced':
                                            time.sleep(0.007 if dimension == 16 else 0.004)
                                    report('body_done', ms=round((time.monotonic()-began)*1000))
                                except Exception as error:
                                    if not intentional_close.is_set():
                                        report('error', code=type(error).__name__)
                            threading.Thread(target=writer, daemon=True).start()
                        elif command['action'] == 'stop':
                            return
                        continue
                    kind = exact(1)[0]
                    if kind == 0:
                        exact(19)
                    elif kind == 2:
                        header = exact(3)
                        exact(int.from_bytes(header[1:], 'big')*4)
                    elif kind == 3:
                        request = exact(9)
                        pending = True
                        if request[0]:
                            incremental += 1
                        else:
                            full += 1
                            if mode in ('refresh', 'size', 'size-resize'):
                                update(full_frame=True)
                        report('request', full=full, incremental=incremental)
                    elif kind == 4:
                        key_event = exact(7)
                        if key_event[0] and mode == 'refresh':
                            marker = 2
                            update()
                        report('key', down=key_event[0], symbol=int.from_bytes(key_event[3:], 'big'), ms=round((time.monotonic()-began)*1000) if began else 0)
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
