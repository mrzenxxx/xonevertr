# xonevertr

**English** · [Русский](README.ru.md)

A native macOS app for lossless FLAC → WAV conversion. Drop files or folders,
convert your queue, and reveal the results in Finder.

Built with SwiftUI and a streaming FLAC decoder written in Swift. No Python,
Homebrew, ffmpeg, or network connection is needed to run the app.

## Features

- Batch conversion with recursive folder import and drag and drop.
- Original sample rate and 16/24-bit depth, mono or stereo.
- Plain PCM WAV headers, including for 24-bit audio; ID3 tags and cover art.
- CRC8/CRC16 frame checks and STREAMINFO MD5 verification when available.
- Progress, cancellation, retry, and Finder shortcuts.
- Atomic output publishing without overwriting existing files or changing originals.
- Native light/dark appearance and keyboard shortcuts.

## Install

Requires **macOS 14 or later**. The current local installer is for Apple Silicon.

Build an installer using the instructions below, or download an artifact from a
successful [macOS workflow run](https://github.com/mrzenxxx/xonevertr/actions/workflows/macos.yml)
when available. Open the `.pkg` and follow the standard macOS Installer steps.
The app is installed at `/Applications/xonevertr.app`; launch it from Applications
or Spotlight.

The app has a local ad-hoc signature. The installer is unsigned; these builds
are not Developer ID signed or notarized by Apple.

## Use

1. Drop FLAC files or folders into the window, or press **⌘O** to select them.
2. Press **Return** or click **Convert**. Press **Escape** to stop.
3. Click the folder button beside a completed track to reveal its WAV in Finder.

The app currently uses Russian interface labels.

By default, a folder named `Album` is converted into a sibling `Album WAV`
folder with the same subfolder structure. Choosing a shared output folder puts
all results in that folder. The output selection applies to subsequently added
files; each queued destination is displayed below its filename.

Name collisions receive suffixes such as `(2)` and `(3)`. If a destination
appears while conversion is running, the app reports an error instead of
replacing it.

## Build

Requires **Swift 6+** and Command Line Tools or Xcode on macOS:

```sh
git clone https://github.com/mrzenxxx/xonevertr.git
cd xonevertr
scripts/test.sh
scripts/build-installer.sh
open dist/xonevertr.app
```

Outputs in `dist/`:

- `xonevertr.app` — application bundle.
- `xonevertr-<version>-macos-<architecture>.pkg` — native installer.
- `xonevertr-macos-<architecture>.zip` — application archive.

The build targets the current Mac's architecture. To build only the app, run
`scripts/build-app.sh`. To package an existing build, run
`scripts/build-installer.sh --skip-build`.

## Limits and tests

Supports 16/24-bit mono and stereo FLAC. Other bit depths, multichannel audio,
and outputs exceeding the ordinary RIFF WAV size limit of approximately 4 GiB
are rejected. Compatibility with a specific CDJ also depends on its supported
sample rates and bit depths; physical CDJ hardware has not been tested.

The test suite checks exact PCM samples across multiple FLAC prediction and
stereo modes, WAV headers, Unicode tags, cover art, checksums, damaged files,
cancellation, output races, folder discovery, and filename collisions. Fixtures
are synthetic audio. ffmpeg is only needed to regenerate fixtures, not to build,
test, or run the app.

## License

[MIT](LICENSE) · Copyright © 2026 Archi Gene.
