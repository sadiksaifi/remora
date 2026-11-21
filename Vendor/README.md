# Engines

## RDP engine

From the checkout root, run `./Vendor/build-engine.sh` on an arm64 Mac with full Xcode selected and CMake on `PATH`. The script downloads and verifies its own sources. It builds OpenSSL 3.6.5, FFmpeg 9.0.2, and FreeRDP 3.33.1 as Release static libraries for macOS 26.0 and later, then produces `Vendor/build/FreeRDP.xcframework` with one `macos-arm64` slice. OpenSSL, FFmpeg avutil/swscale, WinPR, FreeRDP core, client common, and client channels are included in the merged archive. The installed WinPR and FreeRDP public headers, including generated headers, are in the slice's `Headers` directory.

A clean build with cached source tarballs took 48 seconds and produced a 21 MiB XCFramework. Allow extra time for the initial downloads. Completed stages are skipped on subsequent runs. `./Vendor/build-engine.sh --clean` rebuilds every stage while retaining verified sources in `Vendor/src`. A changed script, CMake version, Xcode version, or SDK also rebuilds every stage. Logs are in `Vendor/build/logs`.

The pins and SHA-256 values are in the script. OpenSSL 3.6.5 was the latest stable 3.x version on the [OpenSSL download page](https://openssl-library.org/source/) when checked on October 17, 2026. The OpenSSL and FreeRDP checksums match the official release assets: [OpenSSL](https://github.com/openssl/openssl/releases/tag/openssl-3.6.5) and [FreeRDP](https://github.com/FreeRDP/FreeRDP/releases/tag/3.33.1). The script clears inherited build flags, disables pkg-config discovery, excludes Homebrew prefixes from CMake searches, and supplies absolute paths to its own OpenSSL and FFmpeg headers and archives. It checks those paths in the FreeRDP CMake cache before compilation. OpenSSL providers are built into the archive.

FreeRDP decodes H.264 with its own VideoToolbox backend, `libfreerdp/codec/h264_videotoolbox.m`, enabled by `WITH_APPLE_VIDEOTOOLBOX=ON`. It passes no decoder specification, so Apple selects the hardware or software decoder. FreeRDP 3.33.1 ignores `H264_CONTEXT_OPTION_HW_ACCEL` and `FreeRDP_SoftwareGdi` for this backend, so the consumer sets neither. AVC444 reconstruction sits above the H.264 backend and uses the same decoder. OpenH264 and the FFmpeg H.264 backend are disabled with `WITH_OPENH264=OFF` and `WITH_VIDEO_FFMPEG=OFF`.

Each FreeRDP stage copies the verified source and applies `patches/freerdp-*.patch` to the copy, and the patches are part of the build fingerprint. `freerdp-h264-single-thread.patch` makes the H.264 YUV conversion run on the decoding thread. Upstream splits each updated region into 512x512 tiles, queues them on WinPR's thread pool, and waits for the pool to drain before it returns. With a Windows 11 AVC444v2 session at 1920x1080 in full-screen motion, that queuing and waiting cost more than the conversion: Remora's CPU use fell from 41.8 to 24.0 percent of one core at the same 31 frames per second. A GNOME AVC420 session fell from 37.2 to 32.1 percent. The cost is latency on large frames. On an M4 Pro, converting a full 3840x2160 AVC444v2 frame takes 7.73 ms on the decoding thread against 4.95 ms on the pool. `freerdp-h264-decoder-log.patch` raises the message that names the hardware or software decoder from debug to info, so Remora's default logs keep it.

FFmpeg supplies only swscale, which `freerdp_image_scale` uses when a server maps a surface to a scaled output. Without swscale or cairo, FreeRDP fails those mappings. FFmpeg 9.0.2 was the latest stable release on the [FFmpeg download page](https://ffmpeg.org/download.html) when checked on October 17, 2026. The SHA-256 of the [gzip archive](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.gz) is `84960df915059e8754fef2cd7c9afeb614062b1b5458ec471eecee619ee04e98`. The archive was verified against its [release signature](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.gz.asc), using the [ffmpeg.org public key](https://ffmpeg.org/ffmpeg-devel.asc), fingerprint `FCF986EA15E6E293A5644F10B4322F04D67658D8`. Subsequent builds verify the pinned SHA-256.

The FFmpeg configure flags are:

```text
--prefix=<build>/ffmpeg-install --cc=<Xcode clang>
--arch=arm64 --target-os=darwin --sysroot=<macOS SDK>
--extra-cflags='-O3 -mmacosx-version-min=26.0'
--extra-ldflags='-mmacosx-version-min=26.0'
--disable-everything --disable-autodetect
--disable-shared --enable-static --enable-pic --disable-debug
--disable-programs --disable-doc --disable-network
--disable-avdevice --disable-avfilter --disable-avformat --disable-swresample
--disable-avcodec --enable-avutil --enable-swscale
```

This is an LGPL build with no GPL or nonfree components. FreeRDP enables `WITH_SWSCALE=ON` and `WITH_SWSCALE_LOADING=OFF`, and disables `WITH_FFMPEG`, `WITH_VIDEO_FFMPEG`, and `WITH_DSP_FFMPEG`. The `AVUTIL` and `SWSCALE` include and library cache entries point only at the script's FFmpeg prefix. `CMAKE_PREFIX_PATH` includes both private dependency prefixes. The video redirection channel is disabled with `CHANNEL_VIDEO=OFF`.

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
        .linkedFramework("VideoToolbox"),
        .linkedFramework("CoreMedia"),
        .linkedFramework("CoreVideo"),
    ]
),
```

SwiftPM adds the XCFramework's selected `Headers` directory to the C target's include search path. Use `#include <freerdp/freerdp.h>` and `#include <freerdp/client.h>`. No custom header search path or FreeRDP module map is needed. Set the package's minimum platform to `.macOS("26.0")` and build for arm64.

The eight frameworks above are the explicit consumer link settings. The toolchain supplies `libSystem` and the Objective-C runtime. No separate `ssl`, `crypto`, `m`, `dl`, `pthread`, `iconv`, `z`, or `bz2` library setting is needed. AudioToolbox, Security, and QuartzCore are not required as explicit link settings for this configuration.

Verification used `./Vendor/build-engine.sh --clean`, followed by a cached run that skipped all completed stages. The merged archive contains `h264_videotoolbox.m.o`, no avcodec symbols, and swscale objects referenced by FreeRDP's `color.c` and `video.c`. The RemoraKit tests passed against it. Live sessions decoded H.264 through VideoToolbox from Windows 11 with AVC444v2 and from GNOME on Debian 13 with AVC420, both at 1920x1080 during full-screen motion.

This build has no audio backends, video redirection channel, USB redirection, printing backend, smartcard support, Kerberos, or AAD. In FreeRDP 3.33.1, the channel switches are `WITH_CHANNELS` and `WITH_CLIENT_CHANNELS`, the Apple audio switch is `WITH_MACAUDIO`, FUSE is `WITH_FUSE`, and WinPR tools are `WITH_WINPR_TOOLS`. JSON is disabled with `WITH_JSON_DISABLED=ON`. CMake 4 compatibility uses `CMAKE_POLICY_VERSION_MINIMUM=3.5` without source patches.

## VNC engine

`build-engine.sh` also runs `build-vnc.sh`. The latter can run independently after the RDP engine exists. It downloads LibVNCClient from reviewed upstream commit [`98aaee0560baa0332339b2ef464ea96ed9b9b28c`](https://github.com/LibVNC/libvncserver/commit/98aaee0560baa0332339b2ef464ea96ed9b9b28c), whose project version remains 0.9.15, and libjpeg-turbo 3.1.3. Their immutable source archive SHA-256 pins are in the script. The output is `Vendor/build/LibVNCClient.xcframework`, containing only LibVNCClient and libjpeg. OpenSSL symbols resolve from the single existing FreeRDP engine archive. Compression uses the macOS SDK's zlib. The client bridge links `z`; no Homebrew runtime libraries are needed.

`patches/libvncclient-tls-policy.patch` is applied to verified pristine sources on each rebuild. It selects security after reading the complete offer, disallows anonymous/plaintext VeNCrypt fallback, checks pins independently of CA success, applies decisions only to the leaf, verifies IP identities correctly, requires TLS 1.2 or newer, serializes TLS initialization, exposes parsed authentication and resize results, forwards empty cursor shapes to the registered callback, and isolates classic VNC DES providers in a private OpenSSL context so their cleanup cannot disable later TLS or affect FreeRDP. It does not implement RFB authentication or codecs in Remora. Source files and the patch remain available for reproducible corresponding-source builds. Exact reads use a monotonic deadline for the configured timeout. Fragment arrival and early readiness wakeups do not spend or renew that deadline. The polling slice and cancellation path remain bounded. Recipe, patch, engine configuration, or toolchain changes invalidate the VNC artifact.

Each native handshake writes one bounded summary through macOS unified logging, subsystem `com.peblon.remora`, category `VNC`. Read recent summaries locally with `log show --last 10m --info --predicate 'subsystem == "com.peblon.remora" AND category == "VNC" AND eventMessage BEGINSWITH "Handshake attempt="'`. The phase and failure numbers are defined beside `rfbRemoraDiagnostic` in the patched `rfb/rfbclient.h`. The summary retains the first native failure and last completed phase before cleanup. Offer lists contain at most the first 32 numeric IDs, with their full advertised counts; a larger count indicates truncation. Correlation uses a random attempt UUID. An Apple-mode session that recovers from a withheld ServerInit runs two native handshakes. Their summaries share the attempt UUID, and the first has `native_error=11`. Summaries exclude endpoints, accounts, credentials, server text, cryptographic material, clipboard, input and desktop content. No stderr redirection or diagnostic export is needed.

A connected attempt can also write one `Runtime failure attempt=` summary in the same subsystem and category, before cleanup. To include both summaries, use `log show --last 10m --info --predicate 'subsystem == "com.peblon.remora" AND category == "VNC" AND (eventMessage BEGINSWITH "Handshake attempt=" OR eventMessage BEGINSWITH "Runtime failure attempt=")'`. The runtime stage, operation and failure numbers are defined beside `rfbRemoraRuntimeDiagnostic` in the patched header. Existing I/O/EOF/timeout failure numbers retain their handshake meanings; runtime parser failures start at 11. Message and rectangle index -1 mean no header is available; encoding -2147483649 means the rectangle encoding has not been read. The record retains the first failure, numeric message/rectangle context, framebuffer dimensions and a saturating count of delivered backend framebuffer callbacks. This count does not establish presentation. Context resets before the next message, and the successful handshake record remains frozen. Runtime summaries have the same content exclusions as handshake summaries. No decoder payloads or raw upstream logs are captured.

Recording-only numeric performance events are documented in [VNC tracing](vnc-tracing.md). They use the SDK DynamicTracing category and require an explicit bounded recording.

LibVNCClient source files are GPL-2.0-or-later. Remora distributes the combined app under GPL-3.0-or-later. `licenses/LibVNCClient-GPL-2.0.txt` includes the upstream license. libjpeg-turbo notices and the IJG terms are in `licenses/`; the app copies that directory into its resources. The licenses of the Swift packages in the app, Sparkle, KeychainAccess and Swift Argument Parser, are there too, copied unchanged from each package's source. The IJG code is based in part on the work of the Independent JPEG Group. The Unicode keysym table in `CVNCBridge/keysym.c` is public-domain code from [libxkbcommon 1.11.0](https://github.com/xkbcommon/libxkbcommon/blob/xkbcommon-1.11.0/src/keysym-utf.c), attributed in the source to Markus G. Kuhn and Richard Verhoeven.

The first supported live path is wayvnc 0.10.2 with VeNCrypt X509Plain certificate TLS. `patches/libvncclient-tls-policy.patch` holds the security policy.

The opt-in experimental Apple 003.889 profile is built into the same Release engine. Its bounded parser, MPL-2.0 decoder provenance, key-event handling and unverified fidelity limits are documented in [Apple MVS](apple-mvs/README.md). `patches/libvncclient-apple.patch` is applied after the TLS policy patch; both patches and the decoder source participate in the build fingerprint. Standard VNC remains the default. Mac servers may use Apple display metadata and lossless ZRLE/Raw without changing authentication or dialect. Generic reported multi-display layouts without a supported selection protocol fail explicitly; ordinary single-framebuffer servers remain supported.
