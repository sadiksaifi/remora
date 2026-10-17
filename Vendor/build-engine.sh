#!/bin/bash
# Build the arm64 macOS engine without host-installed dependency libraries.
set -euo pipefail

# CMake may itself come from Homebrew. Resolve that build tool before discarding
# the caller's environment, including compiler, linker, pkg-config and SDK flags.
if [[ ${REMORA_ENGINE_ENV:-} != isolated ]]; then
    cmake_bin=$(command -v cmake) || { echo "Install CMake first." >&2; exit 1; }
    exec /usr/bin/env -i \
        HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
        DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}" \
        REMORA_ENGINE_ENV=isolated REMORA_CMAKE="$cmake_bin" \
        /bin/bash "$0" "$@"
fi

die() { echo "Error: $*" >&2; exit 1; }
on_exit() {
    local status=$?
    if [[ $status != 0 && -n ${stage_log:-} ]]; then
        tail -n 60 "$stage_log" >&2
        echo "Build failed; see $stage_log" >&2
    fi
}
trap on_exit EXIT
case ${1:-} in
    '') [[ $# == 0 ]] || die "Usage: $0 [--clean]" ;;
    --clean) [[ $# == 1 ]] || die "Usage: $0 [--clean]" ;;
    *) die "Usage: $0 [--clean]" ;;
esac
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die "Requires an arm64 Mac."

VENDOR=$(cd "$(dirname "$0")" && pwd -P)
readonly VENDOR
readonly SOURCES="$VENDOR/src"
readonly BUILD="$VENDOR/build"
readonly OPENSSL_VERSION=3.6.5
readonly FREERDP_VERSION=3.32.2
# Official release assets and their published .sha256 files:
# https://github.com/openssl/openssl/releases/tag/openssl-3.6.5
# https://github.com/FreeRDP/FreeRDP/releases/tag/3.32.2
readonly OPENSSL_SHA256=a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98
readonly FREERDP_SHA256=e95a505c0057e4d06a3b120477c421028769deba4db9c639ef3465d050f0955c
readonly OPENSSL_PREFIX="$BUILD/openssl-install"
readonly FREERDP_PREFIX="$BUILD/freerdp-install"
readonly XCFRAMEWORK="$BUILD/FreeRDP.xcframework"
JOBS=$(sysctl -n hw.logicalcpu)
readonly JOBS
readonly START=$SECONDS
export MACOSX_DEPLOYMENT_TARGET=26.0
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
CC=$(xcrun --find clang)
export SDKROOT CC
# No pkg-config search, even if an upstream finder invokes it directly.
export PKG_CONFIG=/usr/bin/false
export PKG_CONFIG_PATH=
export PKG_CONFIG_LIBDIR=/var/empty

xcodebuild -version >/dev/null
[[ -x $REMORA_CMAKE ]] || die "CMake is unavailable: $REMORA_CMAKE"

# A changed recipe or toolchain invalidates completed stages. Sources and their
# checked archives are immutable and can be reused even for --clean.
configuration=$({
    shasum -a 256 "$VENDOR/build-engine.sh"
    "$REMORA_CMAKE" --version
    xcodebuild -version
    xcrun --sdk macosx --show-sdk-version
    echo "$SDKROOT"
} | shasum -a 256 | awk '{print $1}')
if [[ ${1:-} == --clean || ! -f $BUILD/.configuration ]] || \
   [[ $(cat "$BUILD/.configuration") != "$configuration" ]]; then
    rm -rf "$BUILD"
fi
mkdir -p "$SOURCES" "$BUILD/logs"
echo "$configuration" > "$BUILD/.configuration"

stage() {
    local name=$1
    shift
    echo "Building $name (log: $BUILD/logs/$name.log)"
    stage_log="$BUILD/logs/$name.log"
    ("$@") >"$stage_log" 2>&1
    touch "$BUILD/.$name-complete"
    stage_log=
}

fetch_source() {
    local name=$1 checksum=$2 url=$3
    local archive="$SOURCES/$name.tar.gz"
    if [[ ! -f $archive ]]; then
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
            "$url" -o "$archive.partial"
        mv "$archive.partial" "$archive"
    fi
    local actual
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
    [[ $actual == "$checksum" ]] || die "Checksum mismatch: $archive (remove it to download again)"
    if [[ ! -f $SOURCES/$name/.remora-source-verified ]] || \
       [[ $(cat "$SOURCES/$name/.remora-source-verified") != "$checksum" ]]; then
        rm -rf "${SOURCES:?}/${name:?}"
        tar -xzf "$archive" -C "$SOURCES"
        echo "$checksum" > "$SOURCES/$name/.remora-source-verified"
    fi
}

build_openssl() {
    rm -rf "$BUILD/openssl" "$OPENSSL_PREFIX"
    mkdir -p "$BUILD/openssl"
    cd "$BUILD/openssl"
    # no-module embeds the legacy provider in libcrypto; no-dso prevents a
    # runtime dependency on provider modules elsewhere on the machine.
    perl "$SOURCES/openssl-$OPENSSL_VERSION/Configure" darwin64-arm64-cc \
        no-shared no-module no-dso no-tests \
        --prefix="$OPENSSL_PREFIX" --openssldir="$OPENSSL_PREFIX/ssl" --libdir=lib \
        -O3 -mmacosx-version-min=26.0
    make -j "$JOBS" build_libs
    make install_dev
}

# Future stage: build FFmpeg here into its own prefix with only the H.264
# decoder, VideoToolbox hwaccel and LGPL components. Then explicitly supply that
# prefix to FreeRDP and include its static archives in package_engine below.
# No FFmpeg source or dependency is downloaded by this recipe.

build_freerdp() {
    rm -rf "$BUILD/freerdp" "$FREERDP_PREFIX"
    "$REMORA_CMAKE" -S "$SOURCES/freerdp-$FREERDP_VERSION" -B "$BUILD/freerdp" \
        -G 'Unix Makefiles' \
        -DCMAKE_MAKE_PROGRAM=/usr/bin/make \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_OSX_SYSROOT="$SDKROOT" -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_INSTALL_PREFIX="$FREERDP_PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$OPENSSL_PREFIX" \
        '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local;/opt/local' \
        '-DCMAKE_SYSTEM_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local;/opt/local' \
        -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF \
        -DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF \
        -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
        -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_uriparser=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_Opus=ON -DCMAKE_DISABLE_FIND_PACKAGE_libsystemd=ON \
        -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DOPENSSL_INCLUDE_DIR="$OPENSSL_PREFIX/include" \
        -DOPENSSL_SSL_LIBRARY="$OPENSSL_PREFIX/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_PREFIX/lib/libcrypto.a" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DBUILD_TESTING_INTERNAL=OFF \
        -DBUILD_BENCHMARK=OFF -DBUILD_FUZZERS=OFF \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DCMAKE_VERBOSE_MAKEFILE=OFF \
        -DWITH_CLIENT_COMMON=ON -DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON \
        -DWITH_SIMD=ON -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON \
        -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_MAC=OFF \
        -DWITH_CLIENT_INTERFACE=OFF -DWITH_SERVER=OFF -DWITH_SERVER_INTERFACE=OFF \
        -DWITH_SERVER_CHANNELS=OFF -DWITH_SAMPLE=OFF -DWITH_PROXY=OFF -DWITH_SHADOW=OFF \
        -DWITH_SMARTCARD_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_SMARTCARD_INSPECT=OFF \
        -DWITH_PCSC=OFF -DWITH_PCSC_WINPR=OFF -DWITH_PKCS11=OFF -DCHANNEL_SMARTCARD=OFF \
        -DWITH_CUPS=OFF -DCHANNEL_URBDRC=OFF -DWITH_FUSE=OFF -DWITH_KRB5=OFF \
        -DWITH_WINPR_TOOLS=OFF -DWITH_MANPAGES=OFF -DWITH_URIPARSER=OFF \
        -DWITH_AAD=OFF -DWITH_JSON_DISABLED=ON -DWITH_VERBOSE_WINPR_ASSERT=OFF \
        -DWITH_FFMPEG=OFF -DWITH_VIDEO_FFMPEG=OFF -DWITH_DSP_FFMPEG=OFF \
        -DWITH_FFMPEG_HWACCEL=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF \
        -DWITH_MACAUDIO=OFF -DCHANNEL_AUDIN=OFF -DCHANNEL_RDPSND=OFF -DCHANNEL_TSMF=OFF \
        -DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF -DWITH_GSM=OFF -DWITH_LAME=OFF \
        -DWITH_FAAD2=OFF -DWITH_FAAC=OFF -DWITH_SOXR=OFF \
        -DWITH_AOM=OFF -DWITH_DAV1D=OFF -DWITH_YUV=OFF -DWITH_GFX_AV1=OFF \
        -DWITH_MBEDTLS=OFF -DWITH_LIBRESSL=OFF -DWITH_OPENCL=OFF \
        -DWITH_X11=OFF -DWITH_CAIRO=OFF -DWITH_JPEG=OFF \
        -DWITH_TIMEZONE_ICU=OFF -DWITH_LODEPNG=OFF -DWITH_SYSTEMD=OFF \
        -DWINPR_UTILS_IMAGE_PNG=OFF -DWINPR_UTILS_IMAGE_JPEG=OFF -DWINPR_UTILS_IMAGE_WEBP=OFF \
        -DWITH_SSO_MIB=OFF -DWITH_WEBVIEW_AAD_AUTH_HELPER=OFF -DWITH_QT_AAD_AUTH_HELPER=OFF \
        -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF
    # Fail before compilation if OpenSSL discovery ever escapes our prefix.
    local entry
    for entry in \
        "OPENSSL_INCLUDE_DIR:PATH=$OPENSSL_PREFIX/include" \
        "OPENSSL_SSL_LIBRARY:FILEPATH=$OPENSSL_PREFIX/lib/libssl.a" \
        "OPENSSL_CRYPTO_LIBRARY:FILEPATH=$OPENSSL_PREFIX/lib/libcrypto.a"; do
        grep -Fxq "$entry" "$BUILD/freerdp/CMakeCache.txt" || die "Unexpected OpenSSL cache entry: $entry"
    done
    "$REMORA_CMAKE" --build "$BUILD/freerdp" --parallel "$JOBS"
    "$REMORA_CMAKE" --install "$BUILD/freerdp"
}

package_engine() {
    rm -rf "$BUILD/package" "$XCFRAMEWORK"
    mkdir -p "$BUILD/package/Headers"
    # Flatten the versioned include roots so consumers use <freerdp/...> and
    # <winpr/...>. Copy the installed tree, including generated config headers.
    cp -R "$FREERDP_PREFIX/include/freerdp3/freerdp" "$BUILD/package/Headers/"
    cp -R "$FREERDP_PREFIX/include/winpr3/winpr" "$BUILD/package/Headers/"
    local archives=() archive
    while IFS= read -r -d '' archive; do
        [[ $(lipo -archs "$archive") == arm64 ]] || die "Unexpected architecture: $archive"
        archives+=("$archive")
    done < <(find "$OPENSSL_PREFIX/lib" "$FREERDP_PREFIX/lib" -type f -name '*.a' -print0)
    [[ ${#archives[@]} -ge 5 ]] || die "Expected OpenSSL, WinPR, FreeRDP and client archives."
    # Client channel OBJECT libraries are already embedded in libfreerdp-client3.a
    # by upstream CMake. Do not add the installed channel .o files a second time.
    /usr/bin/libtool -static -o "$BUILD/package/libFreeRDP.a" "${archives[@]}"
    xcodebuild -create-xcframework -library "$BUILD/package/libFreeRDP.a" \
        -headers "$BUILD/package/Headers" -output "$XCFRAMEWORK"
}

echo "Remora engine: FreeRDP $FREERDP_VERSION + OpenSSL $OPENSSL_VERSION, macos-arm64, minimum macOS 26.0"
fetch_source "openssl-$OPENSSL_VERSION" "$OPENSSL_SHA256" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
fetch_source "freerdp-$FREERDP_VERSION" "$FREERDP_SHA256" \
    "https://github.com/FreeRDP/FreeRDP/releases/download/$FREERDP_VERSION/freerdp-$FREERDP_VERSION.tar.gz"

if [[ -f $BUILD/.openssl-complete && -f $OPENSSL_PREFIX/lib/libcrypto.a && -f $OPENSSL_PREFIX/lib/libssl.a ]]; then
    echo 'Skipping completed OpenSSL stage.'
else
    rm -f "$BUILD/.freerdp-complete" "$BUILD/.package-complete"
    stage openssl build_openssl
fi
if [[ -f $BUILD/.freerdp-complete && -f $FREERDP_PREFIX/lib/libfreerdp3.a && \
      -f $FREERDP_PREFIX/lib/libfreerdp-client3.a && -f $FREERDP_PREFIX/lib/libwinpr3.a ]]; then
    echo 'Skipping completed FreeRDP stage.'
else
    rm -f "$BUILD/.package-complete"
    stage freerdp build_freerdp
fi
if [[ -f $BUILD/.package-complete && -f $XCFRAMEWORK/macos-arm64/libFreeRDP.a && \
      -f $XCFRAMEWORK/macos-arm64/Headers/freerdp/freerdp.h ]]; then
    echo 'Skipping completed XCFramework stage.'
else
    stage package package_engine
fi

echo "Output: $XCFRAMEWORK"
echo "Size: $(du -sh "$XCFRAMEWORK" | awk '{print $1}'); elapsed: $((SECONDS - START)) seconds"
echo "Static contents: OpenSSL $OPENSSL_VERSION, WinPR/FreeRDP/client common/client channels $FREERDP_VERSION"
echo 'Target: arm64-apple-macos26.0, Release. FFmpeg: deferred.'
echo "Logs: $BUILD/logs"
