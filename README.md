# Remora

Remora is a remote desktop client for the Mac, with native RDP and VNC connections.

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

Then run the Remora scheme. [Vendor/README.md](Vendor/README.md) explains the engine build, and [docs/architecture.md](docs/architecture.md) explains how the app fits together.

## Command line

Click Install in Settings > Command Line. That links `remora` into `~/.local/bin`.

```sh
remora connection list
remora connect "My PC"
remora connection create --kind vnc --host desktop.local --name "VNC desktop"
remora screenshot --output desk.png
remora help agent
```

`remora help agent` is the guide for agents. When an agent is in control, the tab shows it, and you can take over at any moment.

AI agents should run `remora help agent` first. To install the guide as an agent skill, use Settings > Command Line or `remora skill install`. It also works with `npx skills add sadiksaifi/remora`.

VNC uses port 5900 by default. The verified target is wayvnc 0.10.2 with VeNCrypt X509Plain certificate TLS. Classic VNC, None, and ARD use an unencrypted desktop transport. RSA-AES and anonymous TLS are unsupported. See the [VNC backend notes](docs/architecture.md#vnc-backend) for security and feature limits. Older Remora versions cannot read connection files containing VNC records; export or back up connections before downgrading.

## License

GPL-3.0. See [LICENSE](LICENSE).
