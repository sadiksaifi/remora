# Remora

A fast, native and simple remote desktop client for the Mac that speaks both RDP and VNC, built so your AI agents can drive it too.

## Highlights

- **Fast and sharp**: A Metal renderer and H.264 decoded by VideoToolbox keep the remote desktop sharp and responsive, at full Retina resolution on RDP.
- **Built for AI agents**: Agents connect, look, click and type through the `remora` CLI while you watch, and you can take over at any moment.
- **Screenshots and recordings**: Capture a screenshot or record HEVC video, even from a tab you are not looking at.
- **Secure VNC**: VeNCrypt with certificate TLS and no fallback to a weaker method, plus Apple Remote Desktop sign-in for Macs.
- **CLI**: `remora` can do almost everything the app can. Run `remora --help` to see it, and `remora skill install` to teach your agents.

## Install

Remora runs on Apple silicon Macs with macOS 26 or later. There is no release yet, so build it from source with Xcode, CMake and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
./Vendor/build-engine.sh   # builds the RDP and VNC engines once
xcodegen generate
open Remora.xcodeproj      # then run the Remora scheme
```

To install the CLI, click Install in Settings > Command Line. That links `remora` into `~/.local/bin`.

## License

Remora is open source under the [GNU GPL v3](LICENSE).
