#!/usr/bin/env python3
"""Run over SSH stdin. Creates only a private scratch compositor and server."""
import glob
import json
import os
import pathlib
import secrets
import subprocess
import tempfile
import time

os.umask(0o077)
root = pathlib.Path(tempfile.mkdtemp(prefix="remora-vnc-"))
(root / "runtime").mkdir()
(root / "config").mkdir()
(root / "config" / "autostart").write_text("")
(root / "config" / "shutdown").write_text("")
(root / "config" / "rc.xml").write_text("<labwc_config><core><decoration>server</decoration></core><keyboard><default/></keyboard><mouse><default/></mouse></labwc_config>\n")
env = dict(os.environ, XDG_RUNTIME_DIR=str(root / "runtime"),
           XDG_CONFIG_HOME=str(root / "config"), WLR_BACKENDS="headless",
           WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="1",
           LABWC_UPDATE_ACTIVATION_ENV="0", REMORA_VNC_ROOT=str(root),
           GDK_BACKEND="wayland", XKB_DEFAULT_LAYOUT="de")
env.pop("DBUS_SESSION_BUS_ADDRESS", None)
env.pop("DISPLAY", None)
env.pop("WAYLAND_DISPLAY", None)
processes = {}


def launch(name, command):
    log = open(root / (name + ".log"), "w")
    process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                               stdout=log, stderr=log, start_new_session=True)
    processes[name] = process.pid
    (root / "pids.json").write_text(json.dumps(processes))
    return process


try:
    compositor = launch("labwc", ["labwc", "-C", str(root / "config")])
    for _ in range(100):
        sockets = [p for p in glob.glob(str(root / "runtime" / "wayland-*")) if not p.endswith(".lock")]
        if sockets:
            break
        if compositor.poll() is not None:
            raise RuntimeError("labwc exited; inspect scratch log " + str(root))
        time.sleep(0.1)
    else:
        raise RuntimeError("headless Wayland socket timeout: " + str(root))
    env["WAYLAND_DISPLAY"] = pathlib.Path(sockets[0]).name
    subprocess.run(["wlr-randr", "--output", "HEADLESS-1", "--custom-mode", "1280x800@60Hz"], env=env, check=True, capture_output=True)
    subprocess.run(["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "2",
                    "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
                    "-keyout", str(root / "key.pem"), "-out", str(root / "cert.pem")], check=True, capture_output=True)
    password = secrets.token_urlsafe(24)
    config = {"address": "127.0.0.1", "port": 15901, "enable_auth": "true",
              "username": "remora-test", "password": password,
              "certificate_file": str(root / "cert.pem"), "private_key_file": str(root / "key.pem"),
              "relax_encryption": "false", "allow_broken_crypto": "false", "xkb_layout": "de"}
    (root / "wayvnc.conf").write_text("".join(f"{k}={v}\n" for k, v in config.items()))
    server = launch("wayvnc", ["wayvnc", "-C", str(root / "wayvnc.conf"), "-S", str(root / "control.sock"), "-n", "Remora synthetic target", "-v"])
    for _ in range(100):
        if (root / "control.sock").exists():
            break
        if server.poll() is not None:
            raise RuntimeError("wayvnc exited; inspect scratch log " + str(root))
        time.sleep(0.1)
    else:
        raise RuntimeError("wayvnc control socket timeout")
    fixture = pathlib.Path(os.environ["REMORA_FIXTURE_SOURCE"])
    (root / "fixture.py").write_bytes(fixture.read_bytes())
    fixture_process = launch("fixture", ["python3", str(root / "fixture.py")])
    for _ in range(100):
        if (root / "events.jsonl").exists() and '"ready"' in (root / "events.jsonl").read_text():
            break
        if fixture_process.poll() is not None or server.poll() is not None:
            raise RuntimeError("test target exited; inspect scratch logs " + str(root))
        time.sleep(0.1)
    else:
        raise RuntimeError("GTK fixture readiness timeout: " + str(root))
    metadata = {"remote_root": str(root), "remote_port": 15901, "host": "127.0.0.1", "port": 15901,
                "certificate_hostname": "localhost", "username": "remora-test", "password": password,
                "security": "VeNCrypt X509Plain", "security_type": 19, "security_subtype": 262,
                "wayland_display": env["WAYLAND_DISPLAY"], "resolution": [1280, 800], "keyboard_layout": "de",
                "pids": processes, "certificate_pem": (root / "cert.pem").read_text()}
    (root / "target.json").write_text(json.dumps(metadata, indent=2))
    print(json.dumps(metadata))
except BaseException:
    for pid in reversed(list(processes.values())):
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
    raise
