<h1 align="center">Remora</h1>

<p align="center">A native remote desktop client for the Mac. Your RDP and VNC sessions live as tabs in one window, and AI agents can drive them while you watch.</p>

## Highlights

- **One window, many computers**: Every remote computer opens as a tab in the same window.
  - Window managers such as AeroSpace, yabai and Rectangle see one window, not one per session.
  - Close the window, and your sessions keep running from the menu bar.
- **Fast and sharp**: The remote desktop looks like it belongs on your display.
  - A Metal renderer redraws only the parts of the screen that changed.
  - RDP streams H.264 (AVC444 and AVC420) decoded by VideoToolbox, and Progressive RemoteFX.
  - On RDP, Fit to Window sizes the remote desktop to your window at full Retina resolution.
- **Feels like your Mac**: Your keyboard and clipboard work the way you expect.
  - Command-Tab and Command-Space go to the remote computer when you capture the keyboard.
  - Command acts as Windows or Super, Option as Alt, and Control as Control.
  - Copy on one side, and paste on the other.
- **Built for AI agents**: The `remora` CLI lets an agent connect, look, click and type on a remote computer.
  - An animated cursor shows where the agent is going before it clicks.
  - The tab shows when an agent is in control. Take Over pauses it, and Stop Agent Control ends it.
  - After you hand control back, the agent must take a fresh screenshot before it acts again.
  - `remora skill install` installs the agent guide for Claude Code, Codex, Cursor and other agents.
- **Screenshots and recordings**: Save or copy a screenshot, or record the remote desktop to HEVC video.
  - Both work on tabs you are not looking at.
  - Show Key Presses draws what you type, on screen and in recordings.
- **Secure VNC**: VeNCrypt with certificate TLS 1.2 or newer, and no silent fallback to a weaker method.
  - Apple Remote Desktop sign-in connects to Macs.
- **Accessibility**: VoiceOver reaches every control, and the remote desktop reports its size and position.
- **CLI**: `remora` can do almost everything the app can. Run `remora --help` to see what it offers.

## Install

Remora runs on Apple silicon Macs with macOS 26 or later. There is no release yet, so build it from source with Xcode, CMake and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
./Vendor/build-engine.sh   # builds the RDP and VNC engines once
xcodegen generate
open Remora.xcodeproj
```

Then run the Remora scheme. [Vendor/README.md](Vendor/README.md) explains the engine build.

To install the CLI, click Install in Settings > Command Line. That links `remora` into `~/.local/bin`.

## Architecture

- **Remora app**: AppKit for the window and the remote desktop, SwiftUI for sheets and Settings, and Metal for drawing.
- **Engines**: FreeRDP 3 for RDP and LibVNCClient for VNC, built as static libraries behind one Swift session interface.
- **CLI**: `remora` talks to the app over a Unix domain socket that only your account can open. It launches Remora in the background when it is not running.

## More

- **Unencrypted VNC**: Classic VNC, None and Apple Remote Desktop sign-in leave the desktop traffic unencrypted. Prefer a server that offers VeNCrypt, such as wayvnc.
- **Downgrading**: Older Remora versions cannot read a connection file that contains VNC connections. Back up your connections first.

## License

Remora is open source under the [GNU GPL v3](LICENSE).
