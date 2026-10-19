#!/usr/bin/env python3
"""Provision and control the private live VNC fixture without displaying secrets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import ssl
import subprocess

HERE = Path(__file__).resolve().parent
DEFAULT_STATE = HERE.parents[1] / ".snap" / "vnc-target.json"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("action", choices=["start", "status", "resize", "events", "stop"])
parser.add_argument("--ssh", help="SSH destination; required only for start")
parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
parser.add_argument("--size", default="1024x768")
args = parser.parse_args()
os.umask(0o077)
args.state.parent.mkdir(parents=True, exist_ok=True)


def ssh(command, **kwargs):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", args.ssh, command], check=True, capture_output=True, **kwargs)


if args.action == "start":
    if not args.ssh:
        parser.error("start requires --ssh USER@HOST")
    if args.state.exists():
        raise SystemExit("State exists; stop that target before provisioning another")
    # Upload the nonsecret fixture to a unique temporary file, removed after launch.
    fixture = ssh("umask 077; mktemp /tmp/remora-vnc-fixture-XXXXXX", text=True).stdout.strip()
    ssh("cat > " + shlex.quote(fixture), input=(HERE / "fixture.py").read_bytes())
    try:
        result = ssh("REMORA_FIXTURE_SOURCE=" + shlex.quote(fixture) + " python3 -", input=(HERE / "remote_target.py").read_bytes())
    finally:
        ssh("rm -f -- " + shlex.quote(fixture))
    state = json.loads(result.stdout)
    state["ssh"] = args.ssh
    state["tunnel_socket"] = str(args.state.parent / "vnc-ssh.sock")
    pem = state.pop("certificate_pem")
    cert = args.state.parent / "vnc-cert.pem"
    cert.write_text(pem)
    cert.chmod(0o600)
    state["certificate_path"] = str(cert)
    state["certificate_sha256"] = hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()
    args.state.write_text(json.dumps(state, indent=2) + "\n")
    args.state.chmod(0o600)
    subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-M", "-S", state["tunnel_socket"], "-fNT",
                    "-L", "127.0.0.1:15901:127.0.0.1:15901", args.ssh], check=True, capture_output=True)
    print("Target ready; private endpoint and credentials: " + str(args.state))
else:
    state = json.loads(args.state.read_text())
    args.ssh = state["ssh"]
    root = shlex.quote(state["remote_root"])
    environment = "XDG_RUNTIME_DIR=" + shlex.quote(state["remote_root"] + "/runtime") + " WAYLAND_DISPLAY=" + shlex.quote(state["wayland_display"])
    if args.action == "status":
        result = ssh(environment + " wayvncctl -S " + root + "/control.sock output-list", text=True)
        print(result.stdout, end="")
    elif args.action == "resize":
        result = ssh(environment + " wlr-randr --output HEADLESS-1 --custom-mode " + shlex.quote(args.size + "@60Hz"), text=True)
        print("Requested server output: " + args.size)
    elif args.action == "events":
        print(ssh("cat " + root + "/events.jsonl", text=True).stdout, end="")
    elif args.action == "stop":
        # Only signal tracked processes still carrying this target's environment.
        code = "import pathlib\nroot=pathlib.Path(" + repr(state["remote_root"]) + ")\n" + """import json, os, signal, time
stopped = []
for pid in reversed(list(json.loads((root / 'pids.json').read_text()).values())):
    try:
        env = pathlib.Path(f'/proc/{pid}/environ').read_bytes()
        if b'REMORA_VNC_ROOT=' + str(root).encode() + b'\\0' in env:
            os.kill(pid, signal.SIGTERM)
            stopped.append(pid)
    except (FileNotFoundError, ProcessLookupError):
        pass
for _ in range(50):
    running = []
    for pid in stopped:
        try:
            if b'REMORA_VNC_ROOT=' + str(root).encode() + b'\\0' in pathlib.Path(f'/proc/{pid}/environ').read_bytes():
                running.append(pid)
        except FileNotFoundError:
            pass
    if not running:
        break
    time.sleep(.1)
else:
    raise RuntimeError('Tracked target processes have not exited: ' + str(running))
"""
        ssh("python3 -", input=code.encode())
        subprocess.run(["ssh", "-S", state["tunnel_socket"], "-O", "exit", args.ssh], capture_output=True)
        print("Tracked processes and tunnel stopped. Private scratch remains at " + state["remote_root"])
        print("Remove scratch and local private state after collecting required evidence.")
