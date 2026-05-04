#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${KOXTOOLCHAIN:-}" ]]; then
    echo "KOXTOOLCHAIN is required and must point to a koxtoolchain checkout" >&2
    exit 1
fi

X_COMPILE="$KOXTOOLCHAIN/refs/x-compile.sh"
if [[ ! -f "$X_COMPILE" ]]; then
    echo "Cannot find $X_COMPILE" >&2
    exit 1
fi

# Prebuilt release usage only ships the helper script, not a full checkout.
# x-compile.sh still expects the koxtoolchain root to be available as _XTC_DIR.
export _XTC_DIR="$KOXTOOLCHAIN"
# Match the helper's expected default when the caller doesn't request
# the legacy libstdc++ ABI explicitly.
export LEGACY_GLIBCXX_ABI="${LEGACY_GLIBCXX_ABI:-0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SRC="$SCRIPT_DIR/imageprocessing.cpp"

if [[ "$#" -gt 0 ]]; then
    TARGETS=("$@")
else
    TARGETS=(kobov5 kindle kindle5 kindlepw2 kindlehf pocketbook)
fi

target_output_dir() {
    case "$1" in
        kobov5)
            printf '%s/libs/kobo/kobov5\n' "$PLUGIN_DIR"
            ;;
        kindle)
            printf '%s/libs/kindle/kindle-legacy\n' "$PLUGIN_DIR"
            ;;
        kindle5)
            printf '%s/libs/kindle/kindle\n' "$PLUGIN_DIR"
            ;;
        kindlehf|kindlepw2)
            printf '%s/libs/kindle/%s\n' "$PLUGIN_DIR" "$1"
            ;;
        pocketbook)
            printf '%s/libs/pocketbook/pocketbook\n' "$PLUGIN_DIR"
            ;;
        *)
            echo "Unsupported target: $1" >&2
            return 1
            ;;
    esac
}

for target in "${TARGETS[@]}"; do
    out_dir="$(target_output_dir "$target")"
    mkdir -p "$out_dir"

    (
        # shellcheck source=/dev/null
        source "$X_COMPILE" "$target" env bare
        cxx="${CXX:-${CROSS_PREFIX}g++}"
        "$cxx" \
            ${CPPFLAGS:-} \
            ${CXXFLAGS:-} \
            -std=c++11 \
            -fPIC \
            -shared \
            -I"$SCRIPT_DIR" \
            "$SRC" \
            ${LDFLAGS:-} \
            -o "$out_dir/libimageprocessing.so"
    )
done
