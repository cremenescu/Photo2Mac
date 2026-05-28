# Photo2Mac

Editor de imagini nativ pentru macOS — simplu si eficient.

Scop: editare per-imagine (crop, rotate, resize, ajustari, anotari), batch processing, organizare si screenshot/markup rapid, intr-o singura aplicatie usoara.

## Status

In dezvoltare — v0.1.0-alpha (faza 1: editor 1 imagine).

## Caracteristici planificate

- **Nedistructiv complet**: stack de operatii editabil oricand, salvat in XMP-ul imaginii (asemenea Snapseed). Originalul recuperabil prin `File > Revert To` (versiuni native macOS).
- **Formate**: JPEG, PNG, HEIC, TIFF, WebP, AVIF (RAW in faza ulterioara).
- **Editor**: crop, rotate, flip, resize, ajustari Core Image (brightness/contrast/saturation/exposure), anotari vector (text, sageti, dreptunghiuri, blur).
- **Batch**: fereastra separata pentru aplicare pipeline pe N fisiere.
- **Organizare** si **screenshot rapid**: in faze ulterioare.

## Build

```bash
xcodegen generate
xcodebuild -project Photo2Mac.xcodeproj -scheme Photo2Mac \
    -configuration Debug -derivedDataPath .build-xcode build
cp -R .build-xcode/Build/Products/Debug/Photo2Mac.app /Applications/
```

Cerinte: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Licenta

GPL-2.0-or-later. Vezi [LICENSE](LICENSE).

Copyright (c) 2026 Razvan Cremenescu.
