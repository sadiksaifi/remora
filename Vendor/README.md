# FreeRDP engine

From the checkout root, run `./Vendor/build-engine.sh` on an arm64 Mac with full Xcode selected and CMake on `PATH`. The script downloads and verifies its own sources. It builds OpenSSL 3.6.5 and FreeRDP 3.32.2 as Release static libraries for macOS 26.0 and later, then produces `Vendor/build/FreeRDP.xcframework` with one `macos-arm64` slice. WinPR, FreeRDP core, client common, and client channels are included in the merged archive. The installed WinPR and FreeRDP public headers, including generated headers, are in the slice's `Headers` directory.

Clean builds took 28-33 seconds on a 12-core Apple M4 Pro with cached source tarballs and produced an 18 MiB XCFramework. Allow extra time for the initial downloads. Completed stages are skipped on subsequent runs. `./Vendor/build-engine.sh --clean` rebuilds every stage while retaining verified sources in `Vendor/src`. A changed script, CMake version, Xcode version, or SDK also rebuilds every stage. Logs are in `Vendor/build/logs`.

The pins and SHA-256 values are in the script. OpenSSL 3.6.5 was the latest stable 3.x version on the [OpenSSL download page](https://openssl-library.org/source/) when checked on October 17, 2026. Both checksums match the official release assets: [OpenSSL](https://github.com/openssl/openssl/releases/tag/openssl-3.6.5) and [FreeRDP](https://github.com/FreeRDP/FreeRDP/releases/tag/3.32.2). The script clears inherited build flags, disables pkg-config discovery, excludes Homebrew prefixes from CMake searches, and supplies absolute paths to its own OpenSSL headers and archives. OpenSSL providers are built into the archive.

A SwiftPM C bridge can consume the artifact with these target declarations (paths are relative to `Package.swift`):

```swift
.binaryTarget(name: "FreeRDP", path: "../../Vendor/build/FreeRDP.xcframework"),
.target(
    name: "CFreeRDPBridge",
    dependencies: ["FreeRDP"],
    linkerSettings: [
        .linkedFramework("Foundation"),
        .linkedFramework("CoreFoundation"),
        .linkedFramework("IOKit"),
        .linkedFramework("Carbon"),
        .linkedFramework("CoreServices"),
    ]
),
```

SwiftPM adds the XCFramework's selected `Headers` directory to the C target's include search path. Use `#include <freerdp/freerdp.h>` and `#include <freerdp/client.h>`. No custom header search path or FreeRDP module map is needed. Set the package's minimum platform to `.macOS("26.0")` and build for arm64.

The five frameworks above are the complete explicit consumer link settings. The toolchain supplies `libSystem` and the Objective-C runtime; no separate `ssl`, `crypto`, `m`, `dl`, `pthread`, or other library setting is needed on macOS. Verification used a SwiftPM executable that allocated and freed a FreeRDP instance, printed `FreeRDP 3.32.2`, resolved the built-in drdynvc, rdpgfx, disp, and cliprdr channels, and called the keyboard and power APIs. A separate link loaded every object in the archive with the same frameworks. `otool -L` showed only system dependencies.

FFmpeg is deferred to a separate stage identified in the script. This build has no H.264 decoder, audio backends, USB redirection, printing backend, smartcard support, Kerberos, or AAD. In FreeRDP 3.32.2, the channel switches are `WITH_CHANNELS` and `WITH_CLIENT_CHANNELS`, the Apple audio switch is `WITH_MACAUDIO`, FUSE is `WITH_FUSE`, and WinPR tools are `WITH_WINPR_TOOLS`. JSON is disabled with `WITH_JSON_DISABLED=ON`. CMake 4 compatibility uses `CMAKE_POLICY_VERSION_MINIMUM=3.5` without source patches.
