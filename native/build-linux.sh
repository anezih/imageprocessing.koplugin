#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PLUGIN_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OUT_DIR="$PLUGIN_DIR/libs/linux/x86_64"
BUILD_DIR="$PLUGIN_DIR/build/imageprocessing.koplugin"
BUILD_OUT_DIR="$BUILD_DIR/libs/linux/x86_64"
SRC="$SCRIPT_DIR/imageprocessing.cpp"
CXX="${CXX:-g++}"

mkdir -p "$OUT_DIR"
"$CXX" \
    -std=c++11 \
    -O3 \
    -fPIC \
    -shared \
    -I"$SCRIPT_DIR" \
    "$SRC" \
    -o "$OUT_DIR/libimageprocessing.so"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_OUT_DIR"
cp "$PLUGIN_DIR"/README.md "$BUILD_DIR"/
cp "$PLUGIN_DIR"/*.lua "$BUILD_DIR"/
cp -R "$PLUGIN_DIR"/resources "$BUILD_DIR"/
cp "$OUT_DIR/libimageprocessing.so" "$BUILD_OUT_DIR/libimageprocessing.so"
