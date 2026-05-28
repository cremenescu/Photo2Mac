# Photo2Mac

A native macOS image editor — simple, fast, **non-destructive**.

> [In Romanian / In romana](README.ro.md)

## Links

- Landing page: <https://cremenescu.ro/en/photo2mac/> (Romanian: <https://cremenescu.ro/ro/photo2mac/>)
- Latest release `.dmg`: <https://github.com/cremenescu/Photo2Mac/releases/latest>
- Issue tracker: <https://github.com/cremenescu/Photo2Mac/issues>

## Status

In development — `v0.1.0-alpha` (phase 1: single-image editor).

The pixels of the original file are never touched until you Save. Every
adjustment (crop, rotate, flip, brightness, contrast, saturation,
exposure) lives on an `EditStack` that is rendered live by Core Image
and persisted into the XMP metadata of the saved file. Re-opening the
same file in Photo2Mac restores the stack so you can keep editing.

## Features in the alpha

- **Non-destructive editing** with a live Core Image pipeline (Metal-
  backed).
- **Crop** with 8 handles (corners + edges) and an aspect-ratio picker
  (Original, 1:1, 4:3, 3:2, 16:9, ..., Free).
- **Rotate** with ±90° presets, a 0.01° slider and a precise angle field;
  **Flip** H / V.
- **Tune** with brightness / contrast / saturation / exposure sliders
  and a live histogram (Luminance / RGB / R / G / B).
- **Edits list** popover in the toolbar, with per-row revert.
- **Save** (Cmd+S) overwrites the open file with rendered pixels +
  embedded XMP `EditStack`; **Save As** (Cmd+Shift+S) prompts for a
  destination.
- **Invisible autosave** in `~/Library/Application Support/Photo2Mac/`
  so unsaved edits survive a tab close.
- **Welcome screen** with recent files, **Metadata viewer** (EXIF +
  Photo2Mac XMP status).
- **Bilingual UI** (English default + Romanian), switchable in
  Settings.
- **Custom About panel + Help window** (Cmd+?).

Formats: JPEG, PNG, HEIC, TIFF (RAW is on the roadmap).

## Roadmap (phase 2+)

- Vector annotations (text / arrow / rectangle / blur).
- Batch processor.
- Library / organize / browse mode.
- Screenshot + markup capture.
- RAW support.

## Build

```bash
xcodegen generate
xcodebuild -project Photo2Mac.xcodeproj -scheme Photo2Mac \
    -configuration Debug -derivedDataPath .build-xcode build
cp -R .build-xcode/Build/Products/Debug/Photo2Mac.app /Applications/
```

Requires macOS 14+, Xcode 16+, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install
xcodegen`).

To produce a self-contained `.dmg`:

```bash
./build/package.sh v0.1.0-alpha
```

## Installation (from a release `.dmg`)

The `.dmg` is **ad-hoc signed** (no Apple Developer ID yet), so Gatekeeper
will refuse to launch it on the first try. After dragging the app into
`/Applications`:

```bash
xattr -dr com.apple.quarantine /Applications/Photo2Mac.app
```

Then double-click as usual.

## License

[GPL-2.0-or-later](LICENSE). Source files carry an
`SPDX-License-Identifier: GPL-2.0-or-later` header.

Copyright (c) 2026 Razvan Cremenescu.

See [NOTICE](NOTICE) for third-party attributions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Security issues go to
[SECURITY.md](SECURITY.md).
