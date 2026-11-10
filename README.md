# Remora

Remora is a remote desktop client for the Mac. It connects to Windows, Linux and Mac machines over RDP and VNC, and it is built from AppKit, SwiftUI and Metal so it behaves like the rest of your Mac.

## What it does

- Opens each remote computer as a tab in one window.
- Shares the clipboard and captures system shortcuts like Command-Tab when you want it to.
- Takes screenshots and records the remote desktop to video.
- Stays in the menu bar when you close the window, so your sessions keep running.
- Ships a `remora` command line tool that scripts and AI agents can use to drive a session while you watch.

## Requirements

- An Apple silicon Mac with macOS 26 or later.
- Xcode, CMake and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build it.

## Build

```sh
./Vendor/build-engine.sh   # builds the RDP and VNC engines once
xcodegen generate
open Remora.xcodeproj
```

Then run the Remora scheme. [Vendor/README.md](Vendor/README.md) explains the engine build.

## Command line

Click Install in Settings > Command Line. That links `remora` into `~/.local/bin`.

```sh
remora connection list
remora connect "My PC"
remora connection create --kind vnc --host desktop.local --name "VNC desktop"
remora screenshot --output desk.png
```

When an agent is in control, the tab shows it, and you can take over at any moment. Agents should run `remora help agent` first. To install that guide as an agent skill, use Settings > Command Line, `remora skill install`, or `npx skills add sadiksaifi/remora`.

## VNC

Classic VNC, None and Apple Remote Desktop authentication leave the desktop traffic unencrypted. Prefer a server that offers VeNCrypt with certificate TLS, such as wayvnc.

Older Remora versions cannot read a connection file that contains VNC connections. Back up your connections before you downgrade.

## License

GPL-3.0. See [LICENSE](LICENSE).
