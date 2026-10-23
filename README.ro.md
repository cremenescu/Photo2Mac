# Photo2Mac

Editor de imagini nativ pentru macOS — simplu, rapid, **nedistructiv**.

> [In English](README.md)

## Linkuri

- Pagina proiectului: <https://cremenescu.ro/ro/photo2mac/> (engleza: <https://cremenescu.ro/en/photo2mac/>)
- Ultimul `.dmg`: <https://github.com/cremenescu/Photo2Mac/releases/latest>
- Probleme: <https://github.com/cremenescu/Photo2Mac/issues>
- Formatul XMP al stivei de editari: [`docs/XMP.md`](docs/XMP.md)

## Status

In dezvoltare — `v0.3.0-alpha` (faza 1: editor pentru o imagine).

Pixelii fisierului original nu se ating pana la salvare. Fiecare editare
(decupare, rotire, oglindire, luminozitate, contrast, saturatie, expunere,
redimensionare) e un pas intr-un `EditStack` randat live prin Core Image.

Ce face salvarea cu fisierul **alegi tu**, in Preferinte, pentru ca
raspunsurile cinstite difera:

| Mod | Cmd+S scrie | Alte aplicatii vad | Poti reveni mai tarziu? |
|-----|-------------|--------------------|-------------------------|
| **Salveaza ce vezi** (implicit) | imaginea editata | editarile tale | deschizi fisierul in Preview, Fisier ▸ Revino la (macOS pastreaza versiunea dinainte) |
| **Nu modifica originalul** | un fisier `.p2m` alaturi | originalul *needitat* | da, oricand |
| **Pastreaza originalul in fisier** | imaginea editata, cu originalul in interior | editarile tale | da, oricand (fisierul e de ~2× mai mare) |

Setarea decide cum se **scriu** fisierele; fiecare fisier tine minte cum a
fost scris, deci se **citeste** mereu asa cum a fost salvat. Schimbarea
modului nu strica nimic din ce e deja pe disc.

La salvare se pastreaza EXIF, GPS, copyright si profilul de culoare.

## Ce face versiunea alpha

- **Editare nedistructiva** cu pipeline Core Image live (pe Metal).
- **Decupare** cu 8 manere (colturi + laturi) si raport la alegere
  (Original, 1:1, 4:3, 3:2, 16:9, ..., Liber). Return aplica, Escape
  renunta. Decuparea ramane pe subiect daca rotesti dupa aceea.
- **Rotire** ±90°, slider de 0,01°, camp pentru unghi precis si rotire cu
  doua degete pe trackpad; **oglindire** orizontala / verticala a imaginii
  asa cum o vezi.
- **Ajustari** — luminozitate, contrast, saturatie, expunere — cu
  histograma live (Luminanta / RGB / R / G / B).
- **Redimensionare** in pixeli sau procent, cu proportiile pastrate, si
  latura lunga 1920 / 1200 / 800. E ultimul pas din stiva, deci o poti
  schimba sau scoate oricand.
- **Inainte / dupa**: tii apasat butonul din toolbar sau tasta `\`.
- **Lista editarilor** in toolbar, cu revert pe fiecare pas.
- **Salvare** (Cmd+S) intr-unul din cele trei moduri (tabelul de mai sus);
  **Salveaza ca** (Cmd+Shift+S) muta documentul pe fisierul nou;
  **Exporta** (Cmd+Shift+E) scrie o copie JPEG, PNG, HEIC sau TIFF, cu
  calitatea si latura maxima alese.
- **Modificarile nesalvate** apar ca un punct in tab; inchiderea tabului,
  a ferestrei sau a aplicatiei intreaba intai. Sunt si salvate automat in
  `~/Library/Application Support/Photo2Mac/` si propuse inapoi dupa un
  crash, cat timp fisierul nu s-a schimbat intre timp.
- **Navigare in dosar**: ← / → pe imagine, sau Cmd+[ / Cmd+], deschide
  imaginea anterioara / urmatoare din acelasi dosar.
- **Ecran de pornire** cu fisiere recente, **vizualizare metadate** (EXIF +
  starea XMP Photo2Mac).
- **Interfata bilingva** (engleza implicit + romana), din Preferinte.
- **Panou Despre + fereastra de ajutor** (Cmd+?).

Formate: deschide JPEG, PNG, HEIC, TIFF, WebP si AVIF; salveaza JPEG, PNG,
HEIC si TIFF (RAW urmeaza). Salvarea scrie 8 biti pe canal.

## Urmeaza (faza 2+)

- Anotari vector (text / sageata / dreptunghi / blur).
- Procesare in lot.
- Mod de organizare / rasfoire.
- Captura de ecran cu adnotare.
- RAW.

## Build

```bash
xcodegen generate
xcodebuild -project Photo2Mac.xcodeproj -scheme Photo2Mac \
    -configuration Debug -derivedDataPath .build-xcode build
cp -R .build-xcode/Build/Products/Debug/Photo2Mac.app /Applications/
```

Cerinte: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Instalare (din `.dmg`)

`.dmg`-ul e semnat cu Developer ID si notarizat de Apple. Il deschizi,
tragi Photo2Mac in `/Applications` si il pornesti normal.

## Licenta

[GPL-2.0-or-later](LICENSE). Fisierele sursa au antetul
`SPDX-License-Identifier: GPL-2.0-or-later`.

Copyright (c) 2026 Razvan Cremenescu.
