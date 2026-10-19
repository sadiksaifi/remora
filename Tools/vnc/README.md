# Live VNC verification

Use a dedicated headless labwc compositor and wayvnc server to test Remora without opening the user's desktop. The target uses the normal wayvnc authentication configuration: VeNCrypt X509Plain, a self-signed TLS certificate, a synthetic username/password, and no insecure authentication relaxation. The remote server and local SSH tunnel bind to loopback port 15901.

The scripts require SSH key authentication, Python 3, labwc, wayvnc, wlr-randr, OpenSSL, and Python GTK 3 bindings on the Linux target. They do not install packages. They do not change the user's compositor configuration, systemd environment, desktop session, or files. Use an existing checkout; no branch or worktree is needed.

## Start the target

From the repository root:

```sh
python3 Tools/vnc/target.py start --ssh USER@HOST
python3 Tools/vnc/target.py status
```

`start` creates a private `/tmp/remora-vnc-*` directory on the target. It contains an isolated Wayland runtime directory, labwc configuration, a two-day self-signed certificate and private key, wayvnc credentials, process IDs, a GTK fixture, and logs. Only the three processes created by the script run in this environment: labwc, wayvnc, and the fixture. The compositor uses the headless backend and pixman renderer. It cannot update the user's systemd or D-Bus activation environment.

The local `.snap/vnc-target.json` file contains the loopback endpoint, credentials, certificate hostname, certificate SHA256 fingerprint, certificate path, remote scratch path, process IDs, and SSH tunnel control socket. Its permissions are 0600. The certificate has `CN=localhost` and SAN entries for `localhost` and `127.0.0.1`. Do not print or commit the state file, certificate, key, screenshots, recordings, or logs containing content. A second start refuses to overwrite existing state.

If tunnel setup fails after remote provisioning, the state file still identifies the remote processes. Stop that target before starting another one.

## Observe the fixture

The fixture starts at 1280x800 with a German keyboard layout. Its text entry, two clipboard buttons, and pointer surface contain only generated test content. The pointer surface animates a marker every half second and uses a crosshair cursor. The fixture records key transitions, text changes, pointer movement, button transitions, wheel events, and requested clipboard contents in its private `events.jsonl`.

At 1280x800 the text entry includes desktop coordinate (500,180), the copy button includes (500,215), the read-client-clipboard button includes (500,265), and the pointer surface includes (500,400). Recheck coordinates after resizing. Run one input test at a time so events can be attributed to that test.

```sh
python3 Tools/vnc/target.py events > .snap/vnc-fixture-events.jsonl
python3 Tools/vnc/target.py resize --size 1024x768
python3 Tools/vnc/target.py resize --size 1280x800
```

The `resize` command changes only the dedicated headless output. It tests a server-originated geometry change. A client resize test must request a different geometry through Remora and observe both the server output and received frame dimensions.

## Verify Remora

Use an isolated certificate store and a development executable. Keep the installed app, saved connections, and Keychain untouched. The backend smoke executable is maintained by the backend engineer; it reads the private target file and uses the actual `VNCSession`, `MetalDesktop`, and `AppleCaptureMedia` implementations. It does not use saved application connections or Keychain.

Record a separate result for each observable behavior:

- New certificate: reject without reaching connected; accept and receive a frame.
- Saved certificate: reconnect through the same isolated pin directory without another trust prompt.
- Changed fingerprint: report the previous and received fingerprints, then exercise rejection and acceptance. State explicitly whether the test rotated the live certificate or seeded a mismatched test pin.
- Incorrect password: fail authentication without a connected state. Cancel both credential prompting and an in-progress connection.
- Keyboard: inspect fresh fixture events and resulting text for `Remora äöüß €`. Check that each pressed key is released. Hold a modifier from one input source while releasing another source; the modifier must remain active until its owner releases it.
- Pointer and wheel: inspect remote motion, button-down, button-up, and both scroll axes on the pointer surface. A successful send alone does not prove remote delivery.
- Clipboard: read client text using the fixture button, then copy fixture text and observe Remora's remote clipboard result. Preserve UTF-8 characters in both directions.
- Cursor: observe actual cursor image dimensions and hotspot or visible cursor changes, rather than assuming capability from the server.
- Geometry: verify server and client resize independently, including the resulting frame size.
- Hidden refresh: disable frame demand, wait, re-enable it, and verify that a current frame arrives.
- Capture: inspect a PNG from the synthetic desktop. For recording, verify a finalized playable movie with changing frames.

Third-party client checks establish target readiness. They do not establish Remora behavior. An input send acknowledgement, a capability flag, and a rendered frame are different observations. Keep unsupported and unverified features explicit in the evidence.

## Verified run on 2026-10-20

The target was a Raspberry Pi Compute Module 4 running Debian 13.7, labwc 0.20.2, and wayvnc 0.10.2. The native client used the real Remora `VNCSession` with LibVNCClient and OpenSSL 3.6.5. Credentials and certificate pins were supplied through scratch files and an isolated pin directory. The installed application, saved connections, and Keychain were untouched.

Run the backend engineer's scratch harness from the repository root when it is available:

```sh
.snap/vnc-smoke/.build/debug/VNCSmoke \
  .snap/vnc-target.json .snap/vnc-test-agent-pins accept \
  .snap/vnc-test-accept.png
```

The following observations came from the native backend, rather than a reference client:

- **TLS and pixels:** negotiated `VeNCrypt X509Plain`. The first acceptance produced a new-certificate challenge, connected at 1280x800, and delivered 661 dirty-rectangle callbacks. `AppleCaptureMedia` produced an 86,906-byte PNG that was visually inspected. Callback counts are not frame-rate measurements.
- **Certificate decisions:** a fresh rejected certificate never reached connected. A second accepted connection reused the saved pin without another challenge. A separate test directory seeded with a 32-byte zero fingerprint produced `TRUST changed`; rejection disconnected, and acceptance received pixels. This tested a mismatched stored pin, not live certificate rotation. Logs: `.snap/vnc-test-{accept,persist,reject,changed-reject,changed-accept}.log`.
- **Authentication and cancellation:** an incorrect password ended with `Authentication failed.` without connecting. A missing password produced a `usernamePassword` challenge; cancellation disconnected. Cancellation during connection completed in approximately 7 ms. Logs: `.snap/vnc-test-{wrong-password,prompt-cancel,disconnect}.log`.
- **Keyboard and ownership:** fresh GTK events recorded appended text `Remora äöüß €A`, including Euro keyval 8364 and explicit key-up events. Holding agent Shift while pressing and releasing human Shift preserved uppercase `A`. Finishing the agent request produced the final Shift-up with modifier state zero and `INPUT_RELEASE true`. Logs and synthetic capture: `.snap/vnc-test-input.log`, `.snap/vnc-test-native-events.jsonl`, and `.snap/vnc-test-input.png`.
- **Pointer and wheel:** fresh remote events recorded left-button down/up on the pointer surface, vertical delta 1.5, and horizontal delta 1.5. Cursor callbacks reported a 24x24 image and a hotspot change from (3,1) to crosshair (11,11). Logs: `.snap/vnc-test-pointer.log` and `.snap/vnc-test-pointer-events.jsonl`.
- **UTF-8 clipboard:** the fixture received exactly `Remora UTF8 äöüß € 界` from the native client. The native client then received exactly `Remora clipboard: Grüße 日本語 🐟` from the fixture. Logs: `.snap/vnc-test-clipboard.log` and `.snap/vnc-test-clipboard-events.jsonl`.
- **Geometry:** a server-originated change delivered 1024x768 with `REQUESTED false` and the matching Metal desktop size. A client request delivered 1100x720 and the matching Metal desktop size. The client-requested origin flag varied during output restoration and initial negotiation; that flag was not established as reliable by this run. Logs: `.snap/vnc-test-{server,client}-resize.log`. The target was restored to 1280x800.
- **Hidden refresh:** display-update disabling changed callback counts from 657 to 661 while in-flight work drained. Re-enabling updates advanced the count to 1185. This established current-frame resumption, not reduced wire traffic. Log: `.snap/vnc-test-hidden.log`.
- **Video:** the existing `SessionCapture` and `AppleCaptureMedia` pipeline finalized `.snap/vnc-native-recording.mov`. `ffprobe` identified HEVC, 1280x800, and duration 2.183333 seconds. `ffmpeg` decoded three frames with three distinct pixel hashes. Container metadata reported four frames. Logs: `.snap/vnc-test-recording.log`, `.snap/vnc-test-recording-metadata.json`, and `.snap/vnc-test-recording-framemd5.txt`.

Independent target checks also verified X509Plain with the Pi's installed Debian LibVNCClient 0.9.15 and GnuTLS, including repeated raw-only connections. A scratch Python protocol probe verified TLS certificate rejection and incorrect-password rejection, but had an unresolved subsequent-frame timeout. It was removed from the reusable tools and was not used to judge Remora.

This run did not establish full application UI or CLI behavior. Those checks require the UI owner's separately isolated development app with the real backend synchronized into it. Native smoke input used the backend's agent-input API, not the application CLI. The run also did not test live certificate rotation, sustained network-loss recovery, every encoding individually, audio, or VNC servers on Windows or macOS. No result here establishes support for other authentication modes or operating systems.

## Stop and clean up

Keep the target running while reviews need retesting. When retesting is complete:

```sh
python3 Tools/vnc/target.py stop
```

`stop` reads the tracked remote process IDs and checks each process's `REMORA_VNC_ROOT` environment marker before sending SIGTERM. It stops the SSH tunnel through its dedicated control socket. It does not terminate a login session or search for unrelated processes. Scratch remains available for evidence collection.

After confirming the tracked processes have exited, remove the exact remote scratch directory named by `remote_root` in the private state file. Remove the local state file, certificate path, tunnel socket if present, and unneeded `.snap/vnc-*` artifacts. Do not use a wildcard to remove remote directories. No installed package or existing user configuration needs restoration.
