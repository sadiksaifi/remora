# Remora

Remora is a native remote desktop client for Apple silicon Macs on macOS 26 or later. It opens RDP and VNC sessions as tabs in one window, and its `remora` command line tool lets scripts and AI agents drive a session while you watch.

To build it, install Xcode, CMake and [XcodeGen](https://github.com/yonaskolb/XcodeGen), run `./Vendor/build-engine.sh` and `xcodegen generate`, then run the Remora scheme in `Remora.xcodeproj`.

To install the CLI, click Install in Settings > Command Line. Agents should run `remora help agent` first.

GPL-3.0. See [LICENSE](LICENSE).
