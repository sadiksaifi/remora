#!/bin/bash
# LibVNCClient and JPEG share the existing engine's one OpenSSL archive at link time.
set -euo pipefail
if [[ ${REMORA_VNC_ENV:-} != isolated ]]; then
    cmake_bin=$(command -v cmake)
    exec /usr/bin/env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
        DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}" \
        REMORA_VNC_ENV=isolated REMORA_CMAKE="$cmake_bin" /bin/bash "$0" "$@"
fi
[[ $# == 0 && $(uname -m) == arm64 ]] || { echo 'Usage: build-vnc.sh (arm64 Mac)' >&2; exit 1; }
VENDOR=$(cd "$(dirname "$0")" && pwd -P)
BUILD="$VENDOR/build"
SOURCES="$VENDOR/src"
readonly VNC_COMMIT=98aaee0560baa0332339b2ef464ea96ed9b9b28c
readonly VNC_SHA=e4aba30e25cd7bcc743794ccaf4a9b7c3236d15945b9e8b8bb059b0ae1d2f1bb
readonly JPEG_VERSION=3.1.3
readonly JPEG_SHA=3a13a5ba767dc8264bc40b185e41368a80d5d5f945944d1dbaa4b2fb0099f4e5
[[ -f $BUILD/openssl-install/lib/libssl.a && -d $BUILD/FreeRDP.xcframework ]] || {
    echo 'Build the shared OpenSSL/FreeRDP engine first: ./Vendor/build-engine.sh' >&2; exit 1;
}
mkdir -p "$SOURCES" "$BUILD/logs"
fingerprint=$({ shasum -a 256 "$0" "$VENDOR/patches/"*.patch "$VENDOR/apple-mvs/"*.[ch] "$BUILD/.configuration"; xcodebuild -version; "$REMORA_CMAKE" --version; } | shasum -a 256 | awk '{print $1}')
if [[ -f $BUILD/.vnc-configuration && $(cat "$BUILD/.vnc-configuration") == "$fingerprint" && -d $BUILD/LibVNCClient.xcframework ]]; then
    echo 'Skipping completed LibVNCClient stage.'; exit 0
fi
fetch() {
    local name=$1 sha=$2 url=$3
    if [[ ! -f $SOURCES/$name.tar.gz ]]; then
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$url" -o "$SOURCES/$name.tar.gz.partial"
        mv "$SOURCES/$name.tar.gz.partial" "$SOURCES/$name.tar.gz"
    fi
    [[ $(shasum -a 256 "$SOURCES/$name.tar.gz" | awk '{print $1}') == "$sha" ]] || { echo "Checksum mismatch: $name" >&2; exit 1; }
    rm -rf "${SOURCES:?}/${name:?}"
    tar -xzf "$SOURCES/$name.tar.gz" -C "$SOURCES"
}
fetch "libvncserver-$VNC_COMMIT" "$VNC_SHA" "https://codeload.github.com/LibVNC/libvncserver/tar.gz/$VNC_COMMIT"
fetch "libjpeg-turbo-$JPEG_VERSION" "$JPEG_SHA" "https://codeload.github.com/libjpeg-turbo/libjpeg-turbo/tar.gz/refs/tags/$JPEG_VERSION"
patch -d "$SOURCES/libvncserver-$VNC_COMMIT" -p1 < "$VENDOR/patches/libvncclient-tls-policy.patch"
patch -d "$SOURCES/libvncserver-$VNC_COMMIT" -p1 < "$VENDOR/patches/libvncclient-apple.patch"
cp "$VENDOR/apple-mvs/"*.[ch] "$SOURCES/libvncserver-$VNC_COMMIT/src/libvncclient/"
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
CC=$(xcrun --find clang)
JOBS=$(sysctl -n hw.logicalcpu)
export MACOSX_DEPLOYMENT_TARGET=26.0 PKG_CONFIG=/usr/bin/false PKG_CONFIG_LIBDIR=/var/empty
common=(-G 'Unix Makefiles' -DCMAKE_MAKE_PROGRAM=/usr/bin/make -DCMAKE_C_COMPILER="$CC"
    -DCMAKE_OSX_SYSROOT="$SDKROOT" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF
    '-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local;/opt/local'
    '-DCMAKE_SYSTEM_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local;/opt/local'
    -DCMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF -DCMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF)
rm -rf "$BUILD/jpeg" "$BUILD/jpeg-install" "$BUILD/vnc" "$BUILD/vnc-install" "$BUILD/vnc-package" "$BUILD/LibVNCClient.xcframework"
# Keep the build outside an OR-list so errexit applies to each command.
set +e
(
    set -e
    "$REMORA_CMAKE" -S "$SOURCES/libjpeg-turbo-$JPEG_VERSION" -B "$BUILD/jpeg" "${common[@]}" \
        -DCMAKE_INSTALL_PREFIX="$BUILD/jpeg-install" -DCMAKE_INSTALL_LIBDIR=lib \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
    "$REMORA_CMAKE" --build "$BUILD/jpeg" --parallel "$JOBS"
    "$REMORA_CMAKE" --install "$BUILD/jpeg"
    "$REMORA_CMAKE" -S "$SOURCES/libvncserver-$VNC_COMMIT" -B "$BUILD/vnc" "${common[@]}" \
        -DCMAKE_INSTALL_PREFIX="$BUILD/vnc-install" -DCMAKE_INSTALL_LIBDIR=lib \
        -DWITH_LIBVNCSERVER=OFF -DWITH_LIBVNCCLIENT=ON -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF \
        -DWITH_OPENSSL=ON -DWITH_GNUTLS=OFF -DWITH_GCRYPT=OFF -DWITH_SASL=OFF \
        -DWITH_JPEG=ON -DWITH_ZLIB=ON -DWITH_LZO=OFF -DWITH_PNG=OFF -DWITH_XCB=OFF \
        -DWITH_SDL=OFF -DWITH_GTK=OFF -DWITH_QT=OFF -DWITH_LIBSSHTUNNEL=OFF \
        -DWITH_SYSTEMD=OFF -DWITH_FFMPEG=OFF -DWITH_TIGHTVNC_FILETRANSFER=OFF \
        -DOPENSSL_ROOT_DIR="$BUILD/openssl-install" -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DOPENSSL_INCLUDE_DIR="$BUILD/openssl-install/include" \
        -DOPENSSL_SSL_LIBRARY="$BUILD/openssl-install/lib/libssl.a" \
        -DOPENSSL_CRYPTO_LIBRARY="$BUILD/openssl-install/lib/libcrypto.a" \
        -DJPEG_INCLUDE_DIR="$BUILD/jpeg-install/include" -DJPEG_LIBRARY="$BUILD/jpeg-install/lib/libjpeg.a" \
        -DZLIB_INCLUDE_DIR="$SDKROOT/usr/include" -DZLIB_LIBRARY="$SDKROOT/usr/lib/libz.tbd"
    "$REMORA_CMAKE" --build "$BUILD/vnc" --parallel "$JOBS"
    "$REMORA_CMAKE" --install "$BUILD/vnc"
    mkdir -p "$BUILD/vnc-package/Headers"
    cp -R "$BUILD/vnc-install/include/rfb" "$BUILD/vnc-package/Headers/"
    /usr/bin/libtool -static -o "$BUILD/vnc-package/libLibVNCClient.a" "$BUILD/vnc-install/lib/libvncclient.a" "$BUILD/jpeg-install/lib/libjpeg.a"
    xcodebuild -create-xcframework -library "$BUILD/vnc-package/libLibVNCClient.a" -headers "$BUILD/vnc-package/Headers" -output "$BUILD/LibVNCClient.xcframework"
) > "$BUILD/logs/vnc.log" 2>&1
build_status=$?
set -e
if [[ $build_status != 0 ]]; then
    tail -n 65 "$BUILD/logs/vnc.log" >&2
    exit "$build_status"
fi
echo "$fingerprint" > "$BUILD/.vnc-configuration"
echo "Output: $BUILD/LibVNCClient.xcframework (LibVNCClient $VNC_COMMIT, JPEG $JPEG_VERSION; shared engine OpenSSL)"
