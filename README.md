# Remora

Remora is a remote desktop client for the Mac.

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
./Vendor/build-engine.sh   # builds FreeRDP, OpenSSL and FFmpeg once
xcodegen generate
open Remora.xcodeproj
```

Then run the Remora scheme. [Vendor/README.md](Vendor/README.md) explains the engine build, and [docs/architecture.md](docs/architecture.md) explains how the app fits together.

## Command line

Click Install in Settings > Command Line. That links `remora` into `~/.local/bin`.

```sh
remora connection list
remora connect "My PC"
remora screenshot --output desk.png
remora help agent
```

`remora help agent` is the guide for agents. When an agent is in control, the tab shows it, and you can take over at any moment.

AI agents should run `remora help agent` first. To install the guide as an agent skill, use Settings > Command Line or `remora skill install`. It also works with `npx skills add sadiksaifi/remora`.

## License

GPL-3.0. See [LICENSE](LICENSE).
