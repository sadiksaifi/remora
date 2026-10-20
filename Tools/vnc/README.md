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

The fixture starts fullscreen at 1280x800 with a German keyboard layout. Its text entry, two clipboard buttons, and pointer surface contain only generated test content. The pointer surface animates a marker every half second and uses a crosshair cursor. The fixture records key transitions, text changes, pointer movement, button transitions, wheel events, and requested clipboard contents in its private `events.jsonl`.

The fullscreen layout keeps the text entry at desktop coordinate (500,75), the copy button at (500,120), the read-client-clipboard button at (500,170), and the pointer surface at (500,400). These coordinates remain stable through the documented resize tests. Run one input test at a time so events can be attributed to that test.

```sh
python3 Tools/vnc/target.py events > .snap/vnc-fixture-events.jsonl
python3 Tools/vnc/target.py resize --size 1024x768
python3 Tools/vnc/target.py resize --size 1280x800
```

The `resize` command changes only the dedicated headless output. It tests a server-originated geometry change. A client resize test must request a different geometry through Remora and observe both the server output and received frame dimensions.

## Verify Remora

The SwiftPM executable in `Tools/vnc/Smoke` reads the private target file and uses the actual `VNCSession`, `MetalDesktop`, `SessionCapture`, and `AppleCaptureMedia` implementations. It uses the supplied certificate-pin directory and does not use saved application connections or Keychain.

On an Apple silicon Mac with Xcode and CMake installed, build the engine archives once from the repository root:

```sh
./Vendor/build-engine.sh
```

Start the Linux target as described above, then run:

```sh
swift run --package-path Tools/vnc/Smoke VNCSmoke \
  .snap/vnc-target.json .snap/vnc-smoke-pins accept .snap/vnc-accept.png
```

The executable takes `TARGET_JSON PIN_DIRECTORY MODE [OUTPUT]`. Its modes are `accept`, `reject`, `wrong-password`, `prompt-cancel`, `disconnect`, `input`, `pointer`, `clipboard`, `cursor`, `resize`, `hidden`, and `recording`. Every mode except `reject` accepts fixture certificate challenges into the supplied pin directory. A successful run prints `PASS MODE`. A failed expectation exits with an error. Input acknowledgements still require the independent fixture observations below. Logs can contain synthetic clipboard text; redirect them into private scratch files when retaining evidence.

Run `accept` twice with the same pin directory to verify pin persistence. Run `reject` with a fresh pin directory to exercise a new trust decision. The `resize` mode requests 1100x720 and checks wayvnc's asynchronous forwarding path: actual dimensions, retained resize capability, and the server-reported origin. Restore the target to 1280x800 after the test. An optional output path writes a PNG, except in `recording` mode, which requires an unused MOV output path:

```sh
swift run --package-path Tools/vnc/Smoke VNCSmoke \
  .snap/vnc-target.json .snap/vnc-smoke-pins recording .snap/vnc-recording.mov
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,duration,nb_frames \
  -of json .snap/vnc-recording.mov
ffmpeg -v error -i .snap/vnc-recording.mov -map 0:v:0 \
  -f framemd5 .snap/vnc-recording-framemd5.txt
```

The media commands require FFmpeg. They verify decoding and pixel changes independently of the capture writer. Output files are never overwritten.

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

The following observations came from the native backend, rather than a reference client:

- **TLS and pixels:** negotiated `VeNCrypt X509Plain`. The first acceptance produced a new-certificate challenge, connected at 1280x800, and delivered 661 dirty-rectangle callbacks. `AppleCaptureMedia` produced an 86,906-byte PNG that was visually inspected. Callback counts are not frame-rate measurements.
- **Certificate decisions:** a fresh rejected certificate never reached connected. A second accepted connection reused the saved pin without another challenge. A separate test directory seeded with a 32-byte zero fingerprint produced `TRUST changed`; rejection disconnected, and acceptance received pixels. This tested a mismatched stored pin, not live certificate rotation. Logs: `.snap/vnc-test-{accept,persist,reject,changed-reject,changed-accept}.log`.
- **Authentication and cancellation:** an incorrect password ended with `Authentication failed.` without connecting. A missing password produced a `usernamePassword` challenge; cancellation disconnected. Cancellation during connection completed in approximately 7 ms. Logs: `.snap/vnc-test-{wrong-password,prompt-cancel,disconnect}.log`.
- **Keyboard and ownership:** fresh GTK events recorded appended text `Remora äöüß €A`, including Euro keyval 8364 and explicit key-up events. Holding agent Shift while pressing and releasing human Shift preserved uppercase `A`. Finishing the agent request produced the final Shift-up with modifier state zero and `INPUT_RELEASE true`. Logs and synthetic capture: `.snap/vnc-test-input.log`, `.snap/vnc-test-native-events.jsonl`, and `.snap/vnc-test-input.png`.
- **Pointer and wheel:** fresh remote events recorded left-button down/up on the pointer surface, vertical delta 1.5, and horizontal delta 1.5. Cursor callbacks reported a 24x24 image and a hotspot change from (3,1) to crosshair (11,11). Logs: `.snap/vnc-test-pointer.log` and `.snap/vnc-test-pointer-events.jsonl`.
- **UTF-8 clipboard:** the fixture received exactly `Remora UTF8 äöüß € 界` from the native client. The native client then received exactly `Remora clipboard: Grüße 日本語 🐟` from the fixture. Logs: `.snap/vnc-test-clipboard.log` and `.snap/vnc-test-clipboard-events.jsonl`.
- **Geometry:** a server-originated change delivered 1024x768 with `REQUESTED false` and the matching Metal desktop size. A client request was forwarded asynchronously by wayvnc. The final-artifact retest is described below; earlier pending-request origin inference is not used.
- **Hidden refresh:** display-update disabling changed callback counts from 657 to 661 while in-flight work drained. Re-enabling updates advanced the count to 1185. This established current-frame resumption, not reduced wire traffic. Log: `.snap/vnc-test-hidden.log`.
- **Video:** the existing `SessionCapture` and `AppleCaptureMedia` pipeline finalized `.snap/vnc-native-recording.mov`. `ffprobe` identified HEVC, 1280x800, and duration 2.183333 seconds. `ffmpeg` decoded three frames with three distinct pixel hashes. Container metadata reported four frames. Logs: `.snap/vnc-test-recording.log`, `.snap/vnc-test-recording-metadata.json`, and `.snap/vnc-test-recording-framemd5.txt`.

The retained SwiftPM verifier was then rebuilt against the final patched engine. Acceptance passed with 535 dirty-rectangle callbacks at 1280x800. Incorrect-password rejection passed with the typed authentication failure. A private target-file copy with only `host` changed to `localhost` exercised DNS resolution and a new certificate-pin decision, then received 749 callbacks at 1280x800. Logs: `.snap/vnc-final-tools-{accept,wrong-password,localhost}-v3.log`.

The final client-resize run passed with 1,453 callbacks, the actual 1100x720 Metal desktop, `REQUESTED false`, and resize capability retained throughout the request. Its exact wire sequence was:

```text
ExtendedDesktopSize origin=1 result=4 screens=1 size=1100x720
ExtendedDesktopSize origin=0 result=0 screens=1 size=1280x800
ExtendedDesktopSize origin=0 result=0 screens=1 size=1100x720
```

Result 4 means "Request forwarded" and permits asynchronous completion. The later origin-zero update supplies the actual geometry; reporting `REQUESTED false` preserves that wire origin. The forwarded reply must not allocate the requested framebuffer early or remove resize capability. This behavior follows the [RFB ExtendedDesktopSize specification](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst#extendeddesktopsize-pseudo-encoding). The verifier checks actual dimensions and retained capability instead of requiring a synchronous success reply. Log: `.snap/vnc-final-tools-resize-v3.log`.

A server-originated resize was repeated against that final engine and delivered 1024x768, `REQUESTED false`, and 913 callbacks with the matching Metal desktop size. After restoring 1280x800, another input run produced fresh appended `Remora äöüß €A` text and a successful source release. Logs: `.snap/vnc-final-tools-server-resize.log`, `.snap/vnc-final-tools-input-after-resize.log`, and `.snap/vnc-final-tools-events-after-resize.jsonl`.

The fullscreen fixture also passed fresh text entry `Remora äöüß €A`, remote pointer down/up and both scroll axes, and bidirectional UTF-8 clipboard checks through the retained verifier. Logs: `.snap/vnc-fullscreen-{input,pointer,clipboard}.log` and `.snap/vnc-fullscreen-events.jsonl`. Fullscreen placement keeps the controls stable when the compositor resizes the output.

Independent target checks also verified X509Plain with the Pi's installed Debian LibVNCClient 0.9.15 and GnuTLS, including repeated raw-only connections. A scratch Python protocol probe verified TLS certificate rejection and incorrect-password rejection, but had an unresolved subsequent-frame timeout. It was removed from the reusable tools and was not used to judge Remora.

Supplemental native checks against TigerVNC 1.15.0 on Debian Linux verified classic VncAuth (security type 2 only), the password-only credentials challenge, successful authentication with pixels, and incorrect-password rejection. With the final policy-denial artifact, a separate wayvnc `-R` TLS target rejected resizing with wire origin 1/result 1, retained the actual 1280x800 desktop, and kept resize capability false despite the following origin-zero layout update (1,023 callbacks). The normal target still completed forwarded resizing to 1100x720 with capability true (1,447 callbacks), and reconnecting the refusal target began fresh capability negotiation. Evidence: `.snap/vnc-classic-{prompt,accept,wrong-password}.log` and `.snap/vnc-policy-{fixed-denial,normal-resize,fixed-reconnect}.log`. Private variant state and exact cleanup order are recorded in `.snap/vnc-variant-mutations.json`; stop variants before the primary target.

The actual application CLI was then verified through an isolated development app rebuilt at 02:37:05 with the final backend and vendor aggregate. It created a connection without a saved password, connected in the background, reused the existing certificate pin, and answered its username/password prompt through stdin with `remember=false`. CLI input produced exactly `CLI Grüße äöüß €`, confirmed in both a fresh 1280x800 PNG and the remote fixture log. Application recording finalized a 2.376667-second HEVC movie at 1280x800; FFmpeg decoded 136 frames with 124 distinct pixel hashes. Only the test session was closed. Existing connections, the installed app, and Keychain were untouched. JSON receipts, PNGs, movie, build/process evidence, and decode results remain private under `.snap/vnc-app-cli/`.

Visual credentials and trust-sheet interaction checks were separate from this CLI pass. The Linux run did not test live certificate rotation, sustained network-loss recovery, every encoding individually, audio, or VNC servers on Windows or macOS.

### macOS Screen Sharing

A later signed application build at `850f577` connected to a real Mac through the user's saved connection. It selected ARD security type 30 from `[30,33,36,2,35]`, authenticated with a 4096-bit exchange, and displayed the 3024x1964 desktop. The desktop remained live for about 164 seconds and delivered 233 framebuffer callbacks before the operator intentionally disconnected. Pointer clicks, Escape, Command-space, and typing into the remote launcher were visually verified. No spontaneous runtime failure occurred. The final EOF record has `cancelled=1` from the intentional disconnect.

This verification follows two fixes: accepting ARD alongside the known Apple security alternatives, and measuring exact-read timeouts with a monotonic deadline. Public regressions cover both fragmented read branches and a genuine ten-second stall. No codec change or timeout increase was needed.

The operator did not positively identify a new TextEdit document, so document editing was not tested. Mac clipboard, recording, resize behavior, network-loss recovery, and other Mac versions remain unverified. Private receipts and sanitized logs are under `.snap/vnc-macos-research/mac-read-timeout-live/`. The signed app remains installed; no saved connection was manually changed.

A signed `3011ac8` comparison verified the later display-demand and input-scheduling fixes. Ten input submissions had a median roundtrip of 93 ms, compared with 443 ms in the baseline. A comparable menu opening was visible by 856 ms, versus 2.34–2.75 seconds before. These are client-image observation bounds, not remote event or monitor timestamps. Some visible-window actions still had bounds approaching two seconds, and closing improvement was not established. The performance investigation remains open. Private measurements and their limits are under `.snap/vnc-macos-research/sluggishness-live-comparison/`.

Signed `5ad9c4e` also overlaps the next incremental request with transfer of an eligible single-rectangle ZRLE update. The live trace recorded 217 successful updates with exactly one early request each, no duplicate trailers, and no empty updates or runtime failures. Median callback spacing was 201 ms versus 310 ms in the earlier sequential sample. Scene activity differed, so these are callback measurements, not a controlled display-FPS comparison.

A focused visible check collected ten consecutive observations per action before inspecting them. The menu was fully open by 681 ms and fully closed by 475 ms, including automation overhead, with no multi-second persistence in this pair. There is no matched old-build human-input baseline or broad workload latency distribution. The updated signed app remains installed. Private trace and visible evidence are under `.snap/vnc-macos-research/early-request-live-ab/` and `.snap/vnc-macos-research/early-request-visible-batch/`.

## Stop and clean up

Keep the target running while reviews need retesting. When retesting is complete:

```sh
python3 Tools/vnc/target.py stop
```

`stop` reads the tracked remote process IDs and checks each process's `REMORA_VNC_ROOT` environment marker before sending SIGTERM. It stops the SSH tunnel through its dedicated control socket. It does not terminate a login session or search for unrelated processes. Scratch remains available for evidence collection.

After confirming the tracked processes have exited, remove the exact remote scratch directory named by `remote_root` in the private state file. Remove the local state file, certificate path, tunnel socket if present, and unneeded `.snap/vnc-*` artifacts. Do not use a wildcard to remove remote directories. No installed package or existing user configuration needs restoration.
