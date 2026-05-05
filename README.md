# Image Processing KOPlugin

This plugin replaces KOReader's `RenderImage:scaleBlitBuffer()` image scaling
path with an AVIR/LANCIR based native implementation when `libimageprocessing.so` is
available. If the native library cannot be loaded, or a BlitBuffer type is not
supported, KOReader's default scaler is used.

https://github.com/user-attachments/assets/c4921f71-6b73-4625-974e-7b2d19dc973f

*Plugin preview*

<hr>

After cloning this repository, initialize the AVIR submodule:

```sh
git submodule update --init --recursive
```

The default algorithm is Lanczos 2. The algorithm can be changed from:

`Typesetting` > `Image processing` > `Algorithm`

Image processing is globally enabled by default and can be toggled from:

`Typesetting` > `Image processing` > `Enable`

The plugin also registers dispatcher actions, so it can be enabled, disabled,
or toggled from gestures, profiles, and other dispatcher-driven shortcuts.

Post-processing defaults are intentionally mild: `Sharpening: Low`,
`Text darkening: Low`, `Auto color correction: Off`, `Contrast: Normal`,
`Hue: Normal`, `Saturation: Normal`, and `Brightness: Normal`. They can be
changed from the same Image processing menu. Sharpening adds a light unsharp
pass after scaling; text darkening makes darker anti-aliased strokes a bit
denser while leaving near-white areas mostly unchanged.

`Sharpening`, `Text darkening`, and `Auto color correction` also provide a
`Custom` option with a KOReader spin control for precise strength values.

Color controls include automatic tonal range correction, contrast adjustment,
hue shift, saturation control, and brightness control. The automatic correction
is off by default because it can be too aggressive for clean black-and-white
manga pages, but it can help faded scans and color pages.

Page rendering is handled for `cbz`, `cbr`, `cbt`, `cb7`, `zip`, `rar`, `tar`,
`7z`, `pdf`, and `djvu` files.

## Android build

Install the Android NDK and run:

```sh
ANDROID_NDK_HOME=/path/to/android-ndk ./native/build-android.sh
```

The script builds:

- `libs/android/armeabi-v7a/libimageprocessing.so`
- `libs/android/arm64-v8a/libimageprocessing.so`

`ANDROID_API` can be set to override the default API level 21.

On Android, KOReader cannot reliably `dlopen()` plugin shared libraries
directly from external storage. This plugin copies the matching ABI build from
the plugin directory to KOReader's internal app files directory, then loads it
from there.

## Linux emulator build

For KOReader's Linux x86_64 emulator build:

```sh
./native/build-linux.sh
```

The script builds:

- `libs/linux/x86_64/libimageprocessing.so`

For easier emulator testing, it also creates a minimal plugin tree at:

- `build/imageprocessing.koplugin`

That test package contains only the files needed by KOReader:

- `README.md`
- root `*.lua` plugin files
- `resources/...` plugin assets
- `libs/linux/x86_64/libimageprocessing.so`

## Kobo, Kindle, and PocketBook build

This script uses KOReader's `koxtoolchain` and its `refs/x-compile.sh`
environment helper.

The GitHub Actions build and release artifacts follow the same rule: each
generated `imageprocessing.koplugin` archive contains only `README.md`, the
root Lua plugin files, `resources/...` plugin assets, and the target-specific
`libs/.../libimageprocessing.so` files.

### 1. Install koxtoolchain

Clone it somewhere on your machine:

```sh
cd ~
git clone --recursive https://github.com/koreader/koxtoolchain.git
```

If you already cloned it earlier, update it first:

```sh
cd ~/koxtoolchain
git pull
git submodule update --init --recursive
```

### 2. Build the toolchain target you need

Generate the matching toolchain before building this plugin.

For Kobo v5:

```sh
cd ~/koxtoolchain
./gen-tc.sh kobov5
```

For legacy Kindle:

```sh
cd ~/koxtoolchain
./gen-tc.sh kindle
```

For Kindle 5:

```sh
cd ~/koxtoolchain
./gen-tc.sh kindle5
```

For Kindle Paperwhite 2:

```sh
cd ~/koxtoolchain
./gen-tc.sh kindlepw2
```

For Kindle HF:

```sh
cd ~/koxtoolchain
./gen-tc.sh kindlehf
```

For PocketBook:

```sh
cd ~/koxtoolchain
./gen-tc.sh pocketbook
```

### 3. Build this plugin for the target

Change into the plugin directory:

```sh
cd /path/to/imageprocessing.koplugin
```

Build all supported koxtoolchain targets at once:

```sh
KOXTOOLCHAIN=$HOME/koxtoolchain ./native/build-koxtoolchain.sh
```

Or build only one explicit target.

For Kobo v5:

```sh
KOXTOOLCHAIN=$HOME/koxtoolchain ./native/build-koxtoolchain.sh kobov5
```

For legacy Kindle:

```sh
KOXTOOLCHAIN=$HOME/koxtoolchain ./native/build-koxtoolchain.sh kindle
```

For Kindle 5:

```sh
KOXTOOLCHAIN=$HOME/koxtoolchain ./native/build-koxtoolchain.sh kindle5
```

For Kindle Paperwhite 2:

```sh
KOXTOOLCHAIN=$HOME/koxtoolchain ./native/build-koxtoolchain.sh kindlepw2
```

For Kindle HF:

```sh
KOXTOOLCHAIN=$HOME/koxtoolchain ./native/build-koxtoolchain.sh kindlehf
```

For PocketBook:

```sh
KOXTOOLCHAIN=$HOME/koxtoolchain ./native/build-koxtoolchain.sh pocketbook
```

### 4. Expected output files

The script writes:

- `libs/kobo/kobov5/libimageprocessing.so`
- `libs/kindle/kindle-legacy/libimageprocessing.so`
- `libs/kindle/kindle/libimageprocessing.so`
- `libs/kindle/kindlepw2/libimageprocessing.so`
- `libs/kindle/kindlehf/libimageprocessing.so`
- `libs/pocketbook/pocketbook/libimageprocessing.so`

## Library

The native wrapper uses the AVIR/LANCIR sources as a git submodule:

https://github.com/avaneev/avir

AVIR is MIT licensed. Keep the upstream copyright and license text in the
vendored headers when redistributing.

## Disclosure

This plugin was developed by ChatGPT Codex.
