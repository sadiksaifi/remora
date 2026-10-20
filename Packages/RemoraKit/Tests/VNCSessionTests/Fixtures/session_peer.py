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
            send(struct.pack('>HHBBBBHHHBBBBBBI', 16, 16, 32, 24, 0, 1,
                             255, 255, 255, 16, 8, 0, 0, 0, 0, 0))
            full = incremental = 0
            pending = False
            marker = 1
            def update():
                nonlocal pending
                if pending:
                    # A single changed pixel satisfies all pending requests.
                    send(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 1, 1, 0) + bytes([marker, 0, 0, 0]))
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
                            update()
                        report('request', full=full, incremental=incremental)
                    elif kind == 4:
                        key_event = exact(7)
                        if key_event[0]:
                            marker = 2
                            update()
                        report('key', down=key_event[0])
                    elif kind == 5:
                        exact(5)
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
