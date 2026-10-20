# FreeRDP engine

From the checkout root, run `./Vendor/build-engine.sh` on an arm64 Mac with full Xcode selected and CMake on `PATH`. The script downloads and verifies its own sources. It builds OpenSSL 3.6.5, FFmpeg 9.0.2, and FreeRDP 3.32.2 as Release static libraries for macOS 26.0 and later, then produces `Vendor/build/FreeRDP.xcframework` with one `macos-arm64` slice. OpenSSL, FFmpeg avcodec/avutil/swscale, WinPR, FreeRDP core, client common, and client channels are included in the merged archive. The installed WinPR and FreeRDP public headers, including generated headers, are in the slice's `Headers` directory.

A clean build with cached source tarballs took 59 seconds and produced a 23 MiB XCFramework. Allow extra time for the initial downloads. Completed stages are skipped on subsequent runs. `./Vendor/build-engine.sh --clean` rebuilds every stage while retaining verified sources in `Vendor/src`. A changed script, CMake version, Xcode version, or SDK also rebuilds every stage. Logs are in `Vendor/build/logs`.

The pins and SHA-256 values are in the script. OpenSSL 3.6.5 was the latest stable 3.x version on the [OpenSSL download page](https://openssl-library.org/source/) when checked on October 17, 2026. The OpenSSL and FreeRDP checksums match the official release assets: [OpenSSL](https://github.com/openssl/openssl/releases/tag/openssl-3.6.5) and [FreeRDP](https://github.com/FreeRDP/FreeRDP/releases/tag/3.32.2). The script clears inherited build flags, disables pkg-config discovery, excludes Homebrew prefixes from CMake searches, and supplies absolute paths to its own OpenSSL and FFmpeg headers and archives. It checks those paths in the FreeRDP CMake cache before compilation. OpenSSL providers are built into the archive.

FFmpeg 9.0.2 was the latest stable release on the [FFmpeg download page](https://ffmpeg.org/download.html) when checked on October 17, 2026. The SHA-256 of the [gzip archive](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.gz) is `84960df915059e8754fef2cd7c9afeb614062b1b5458ec471eecee619ee04e98`. The archive was verified against its [release signature](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.gz.asc), using the [ffmpeg.org public key](https://ffmpeg.org/ffmpeg-devel.asc), fingerprint `FCF986EA15E6E293A5644F10B4322F04D67658D8`. Subsequent builds verify the pinned SHA-256.

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
--enable-avcodec --enable-avutil --enable-swscale
--enable-decoder=h264 --enable-parser=h264
--enable-hwaccel=h264_videotoolbox --enable-videotoolbox
```

This is an LGPL build with no GPL or nonfree components. FreeRDP 3.32.2 calls `av_parser_init(AV_CODEC_ID_H264)` during decoder initialization, so the parser is required. Its `h264_ffmpeg.c` uses swscale to convert hardware frames to YUV420P after transferring them to CPU memory. AVC444 reconstruction sits above the H.264 backend and uses the same decoder.

FreeRDP enables `WITH_FFMPEG=ON`, `WITH_VIDEO_FFMPEG=ON`, `WITH_FFMPEG_HWACCEL=ON`, `WITH_SWSCALE=ON`, and `WITH_SWSCALE_LOADING=OFF`. Despite its name, `WITH_VIDEO_FFMPEG` gates the H.264 backend itself. The separate video redirection channel is disabled with `CHANNEL_VIDEO=OFF`; audio DSP remains disabled with `WITH_DSP_FFMPEG=OFF`. `FFMPEG_INCLUDE_DIRS`, `FFMPEG_LIBRARIES`, and the per-component `AVCODEC`, `AVUTIL`, and `SWSCALE` include/library cache entries point only at the script's FFmpeg prefix. `CMAKE_PREFIX_PATH` includes both private dependency prefixes.

Hardware decoding also requires the consumer to set `H264_CONTEXT_OPTION_HW_ACCEL` to `TRUE` on the H.264 context. FreeRDP's GDI graphics path requests this when `FreeRDP_SoftwareGdi` is false. The backend selects VideoToolbox on Apple and falls back to software if hardware-device initialization fails. Enabling the build option alone does not activate hardware decoding on every context.

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

Verification used `./Vendor/build-engine.sh --clean`, followed by a cached run that skipped all completed stages. A throwaway Swift 6 SwiftPM executable linked the copied XCFramework, created `h264_context_new(FALSE)`, and reported the `libavcodec` subsystem. A real 320x240 Annex B H.264 stream decoded through `avc420_decompress` with both software and VideoToolbox. FreeRDP logged its hardware-frame transfer and swscale conversion. Direct libavcodec inspection found the VideoToolbox H.264 configuration, decoded a `videotoolbox_vld` frame, and transferred it to CPU memory as NV12. Setting `FREERDP_HWCTX_TYPE=vaapi` exercised hardware-device initialization failure and successful software fallback. A separate link loaded every object in the merged archive with the same eight frameworks. `otool -L` on both executables showed only system libraries and frameworks.

A 64x48 test frame decoded in software but was rejected by VideoToolbox. FreeRDP 3.32.2 does not retry every hardware decode failure in software; the verified fallback above covers hardware-device initialization failure. Hardware support remains dependent on stream properties and the host.

This build has no audio backends, video redirection channel, USB redirection, printing backend, smartcard support, Kerberos, or AAD. In FreeRDP 3.32.2, the channel switches are `WITH_CHANNELS` and `WITH_CLIENT_CHANNELS`, the Apple audio switch is `WITH_MACAUDIO`, FUSE is `WITH_FUSE`, and WinPR tools are `WITH_WINPR_TOOLS`. JSON is disabled with `WITH_JSON_DISABLED=ON`. CMake 4 compatibility uses `CMAKE_POLICY_VERSION_MINIMUM=3.5` without source patches.

## VNC engine

`build-engine.sh` also runs `build-vnc.sh`. The latter can run independently after the RDP engine exists. It downloads LibVNCClient from reviewed upstream commit [`98aaee0560baa0332339b2ef464ea96ed9b9b28c`](https://github.com/LibVNC/libvncserver/commit/98aaee0560baa0332339b2ef464ea96ed9b9b28c), whose project version remains 0.9.15, and libjpeg-turbo 3.1.3. Their immutable source archive SHA-256 pins are in the script. The output is `Vendor/build/LibVNCClient.xcframework`, containing only LibVNCClient and libjpeg. OpenSSL symbols resolve from the single existing FreeRDP engine archive. Compression uses the macOS SDK's zlib. The client bridge links `z`; no Homebrew runtime libraries are needed.

`patches/libvncclient-tls-policy.patch` is applied to verified pristine sources on each rebuild. It selects security after reading the complete offer, disallows anonymous/plaintext VeNCrypt fallback, checks pins independently of CA success, applies decisions only to the leaf, verifies IP identities correctly, requires TLS 1.2 or newer, serializes TLS initialization, exposes parsed authentication and resize results, forwards empty cursor shapes to the registered callback, and isolates classic VNC DES providers in a private OpenSSL context so their cleanup cannot disable later TLS or affect FreeRDP. It does not implement RFB authentication or codecs in Remora. Source files and the patch remain available for reproducible corresponding-source builds. Exact reads use a monotonic deadline for the configured timeout. Fragment arrival and early readiness wakeups do not spend or renew that deadline. The polling slice and cancellation path remain bounded. Recipe, patch, engine configuration, or toolchain changes invalidate the VNC artifact.

Each native handshake writes one bounded summary through macOS unified logging, subsystem `dev.sadiksaifi.Remora`, category `VNC`. Read recent summaries locally with `log show --last 10m --info --predicate 'subsystem == "dev.sadiksaifi.Remora" AND category == "VNC" AND eventMessage BEGINSWITH "Handshake attempt="'`. The phase and failure numbers are defined beside `rfbRemoraDiagnostic` in the patched `rfb/rfbclient.h`. The summary retains the first native failure and last completed phase before cleanup. Offer lists contain at most the first 32 numeric IDs, with their full advertised counts; a larger count indicates truncation. Correlation uses a random attempt UUID. Summaries exclude endpoints, accounts, credentials, server text, cryptographic material, clipboard, input and desktop content. No stderr redirection or diagnostic export is needed.

A connected attempt can also write one `Runtime failure attempt=` summary in the same subsystem and category, before cleanup. To include both summaries, use `log show --last 10m --info --predicate 'subsystem == "dev.sadiksaifi.Remora" AND category == "VNC" AND (eventMessage BEGINSWITH "Handshake attempt=" OR eventMessage BEGINSWITH "Runtime failure attempt=")'`. The runtime stage, operation and failure numbers are defined beside `rfbRemoraRuntimeDiagnostic` in the patched header. Existing I/O/EOF/timeout failure numbers retain their handshake meanings; runtime parser failures start at 11. Message and rectangle index -1 mean no header is available; encoding -2147483649 means the rectangle encoding has not been read. The record retains the first failure, numeric message/rectangle context, framebuffer dimensions and a saturating count of delivered backend framebuffer callbacks. This count does not establish presentation. Context resets before the next message, and the successful handshake record remains frozen. Runtime summaries have the same content exclusions as handshake summaries. No decoder payloads or raw upstream logs are captured.

Recording-only numeric performance events are documented in [VNC tracing](vnc-tracing.md). They use the SDK DynamicTracing category and require an explicit bounded recording.

LibVNCClient source files are GPL-2.0-or-later. Remora distributes the combined app under GPL-3.0-or-later. `licenses/LibVNCClient-GPL-2.0.txt` includes the upstream license. libjpeg-turbo notices and the IJG terms are in `licenses/`; the app copies that directory into its resources. The IJG code is based in part on the work of the Independent JPEG Group. The Unicode keysym table in `CVNCBridge/keysym.c` is public-domain code from [libxkbcommon 1.11.0](https://github.com/xkbcommon/libxkbcommon/blob/xkbcommon-1.11.0/src/keysym-utf.c), attributed in the source to Markus G. Kuhn and Richard Verhoeven.

The first supported live path is wayvnc with certificate TLS and X509Plain. See [VNC backend notes](../docs/architecture.md#vnc-backend) for exact security policy, verified modes, and remaining interoperability limits.
