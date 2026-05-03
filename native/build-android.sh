#!/usr/bin/env sh
set -eu

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "ANDROID_NDK_HOME is required" >&2
    exit 1
fi

API="${ANDROID_API:-21}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUT_DIR="$PLUGIN_DIR/libs/android"
SRC="$SCRIPT_DIR/imageprocessing.cpp"
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

build_one() {
    abi="$1"
    target="$2"
    arch_flags="$3"
    out="$OUT_DIR/$abi"
    mkdir -p "$out"
    "$TOOLCHAIN/${target}${API}-clang++" \
        -std=c++11 \
        -O3 \
        -fPIC \
        -shared \
        -static-libstdc++ \
        -funwind-tables \
        -fstack-protector \
        -no-canonical-prefixes \
        $arch_flags \
        -I"$SCRIPT_DIR" \
        "$SRC" \
        -o "$out/libimageprocessing.so"
}

build_one armeabi-v7a armv7a-linux-androideabi "-march=armv7-a -mfpu=vfpv3-d16 -mthumb"
build_one arm64-v8a aarch64-linux-android ""
