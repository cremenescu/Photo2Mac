# Photo2Mac XMP edit stack

Photo2Mac is non-destructive: every adjustment lives on an `EditStack`
which is rendered live by Core Image. When you Save, Photo2Mac writes
the rendered pixels **and** embeds the EditStack as XMP metadata
inside the image. Re-opening the file in Photo2Mac restores the stack
so you can keep editing. Other apps just see the rendered pixels.

This document describes the on-disk format so external tools can
read, inspect or even synthesize a Photo2Mac edit stack.

## Namespace

| | |
|--|--|
| **URI**    | `http://ns.photo2mac.cremenescu.ro/1.0/` |
| **Prefix** | `p2m` |

| Property | Type | Meaning |
|----------|------|---------|
| `p2m:editStack`    | string (UTF-8 JSON) | the `EditStack` — see the schema below |
| `p2m:saveMode`     | string | how this file was written: `flattened` or `embeddedOriginal` |
| `p2m:originalImage`| string (base64) | the untouched original file, present only when `saveMode` is `embeddedOriginal` |
| `p2m:originalType` | string (UTI)    | format of those original bytes, e.g. `public.jpeg` |

`p2m:editStack` is a single string holding a JSON-encoded `EditStack`. Storing
JSON inside an XMP string keeps the format trivially portable: any tool that
can read XMP can pull the recipe out, no schema awareness required.

## How a file must be read

**Crucially: `p2m:editStack` alone does not tell you whether the edits are
already in the pixels.** `p2m:saveMode` does. Photo2Mac lets the user choose
what Cmd+S does, so:

| Situation | Pixels on disk | What to do with the stack |
|-----------|----------------|---------------------------|
| `.p2m` sidecar exists next to the file | the untouched original | apply it |
| `saveMode` = `embeddedOriginal` | already edited | decode `p2m:originalImage` and apply the stack to *that* |
| `saveMode` = `flattened` | already edited | **do not apply** — it is a record of what was done |
| `editStack` present, no `saveMode` | already edited | **do not apply** (see below) |
| nothing | original | nothing to do |

The last row is the compatibility rule for files written by Photo2Mac
v0.1.0 – v0.2.1. Those versions baked the edits into the pixels *and* wrote a
stack with no mode marker, so re-applying it double-applied every edit and
compounded on each save. Absent a marker, assume the pixels are final.

## The sidecar (`SaveMode.sidecar`)

In sidecar mode the image file is never modified; the recipe lives beside it as
`<filename>.<ext>.p2m`, a JSON document:

```json
{
  "version": 1,
  "stack": { "...": "an EditStack, same schema as below" },
  "sourceSize": 482913,
  "sourceModified": 774829200.0
}
```

`sourceSize` is checked on read: a sidecar left behind next to a file that has
since been replaced is ignored rather than applied to the wrong pixels.

## Container formats

Photo2Mac uses Apple's `ImageIO` (`CGImageDestination` +
`CGImageMetadata`) to embed XMP at save time. The same `p2m:editStack`
property is written into:

| Format | Container         | UTI                          |
|--------|-------------------|------------------------------|
| JPEG   | APP1 XMP segment  | `public.jpeg`                |
| PNG    | iTXt `XML:com.adobe.xmp` chunk | `public.png`    |
| HEIC   | XMP property in the meta box   | `public.heic`   |
| TIFF   | TIFF tag 700 (XMP)             | `public.tiff`   |

## EditStack JSON schema

`EditStack` is a Swift `Codable` struct ([`App/EditStack.swift`][stack-src]).
Default-encoded JSON looks like this:

```json
{
  "rotateDegrees": 0,
  "flipHorizontal": false,
  "flipVertical": false,
  "adjustments": {
    "brightness": 0.0,
    "contrast":   0.0,
    "saturation": 0.0,
    "exposure":   0.0
  },
  "crop": null
}
```

### Fields

| Field             | Type    | Range         | Notes |
|-------------------|---------|---------------|-------|
| `rotateDegrees`   | number  | any           | Clockwise rotation in degrees. `0.01` increments supported. |
| `flipHorizontal`  | bool    |               | Horizontal mirror. |
| `flipVertical`    | bool    |               | Vertical mirror. |
| `crop`            | object &#124; null | see below | `null` = no crop. |
| `adjustments`     | object  | see below     | All sliders default to 0 (neutral). |

### `crop` object — `CropRect`

A normalized rectangle (`0..1`) **over the geometry-transformed image**
(after flip + rotate, before adjustments). All four fields are required
when `crop` is non-null.

| Field    | Type   | Meaning |
|----------|--------|---------|
| `x`      | number | left edge, `0..1` |
| `y`      | number | top edge, `0..1` |
| `width`  | number | width, `0..1`  |
| `height` | number | height, `0..1` |

Origin is **top-left** (CG convention after Photo2Mac normalizes the
rotated frame).

### `adjustments` object

| Field        | Range          | Mapping to Core Image |
|--------------|----------------|-----------------------|
| `brightness` | -1.0 .. 1.0    | linearly scaled to CI's [-0.5, 0.5] `inputBrightness` (`CIColorControls`) |
| `contrast`   | -1.0 .. 1.0    | mapped to [0.5, 1.5] `inputContrast` (`CIColorControls`) |
| `saturation` | -1.0 .. 1.0    | mapped to [0.0, 2.0] `inputSaturation` (`CIColorControls`) |
| `exposure`   | -3.0 .. 3.0 EV | passed as-is to `inputEV` (`CIExposureAdjust`) |

`0` is neutral for every field. The UI exposes the symmetric ranges
above; nothing in the on-disk format prevents larger values, but the
renderer clamps to what Core Image accepts.

## Render order

Operations are applied in a fixed order so the result is deterministic
regardless of the order in which sliders were touched:

```
flipHorizontal -> flipVertical -> rotate -> crop -> adjustments
```

Geometry first (so `crop` always operates on the rotated/flipped frame
the user actually sees), pixel adjustments last (so they apply only to
the cropped region).

## Standard XMP/EXIF tags also written

So that *any* metadata viewer — Preview, Metapho, Adobe Bridge,
`exiftool`, `mdls`, the macOS Get Info pane — shows that the file was
processed by Photo2Mac, three well-known tags are written alongside
`p2m:editStack`:

| Tag                    | Namespace | Example value |
|------------------------|-----------|---------------|
| `xmp:CreatorTool`      | `http://ns.adobe.com/xap/1.0/`  | `Photo2Mac 0.1.0` |
| `tiff:ImageDescription`| `http://ns.adobe.com/tiff/1.0/` | `Photo2Mac 0.1.0 — rotate -2.50°, crop 90%×80% at (5%, 10%), brightness +12, exposure +0.30 EV` |
| `dc:description`       | `http://purl.org/dc/elements/1.1/` | (same human summary) |

These three values are always **English** and locale-independent: the
file metadata is read by tools and people anywhere, regardless of the
language Photo2Mac's UI is set to.

The `p2m:editStack` JSON remains the authoritative source for re-opening;
the standard tags are summaries.

## Examples

### Neutral (no edits)

If you Save without making any edit, Photo2Mac still writes a stack so
the file is round-trippable:

```json
{
  "rotateDegrees": 0,
  "flipHorizontal": false,
  "flipVertical": false,
  "adjustments": {
    "brightness": 0, "contrast": 0, "saturation": 0, "exposure": 0
  },
  "crop": null
}
```

`tiff:ImageDescription` and `dc:description` show `Photo2Mac X.Y.Z — no edits`.

### Rotate + crop

Two-and-a-half degree counter-clockwise straighten, then crop to the
central 90% × 80%:

```json
{
  "rotateDegrees": -2.5,
  "flipHorizontal": false,
  "flipVertical": false,
  "adjustments": {
    "brightness": 0, "contrast": 0, "saturation": 0, "exposure": 0
  },
  "crop": { "x": 0.05, "y": 0.10, "width": 0.90, "height": 0.80 }
}
```

`tiff:ImageDescription`:

```
Photo2Mac 0.1.0 — rotate -2.50°, crop 90%×80% at (5%, 10%)
```

### Adjustments only

Brightness +12, contrast +5, exposure +0.30 EV:

```json
{
  "rotateDegrees": 0,
  "flipHorizontal": false,
  "flipVertical": false,
  "adjustments": {
    "brightness": 0.12,
    "contrast":   0.05,
    "saturation": 0,
    "exposure":   0.30
  },
  "crop": null
}
```

## Inspecting a Photo2Mac file from the command line

[`exiftool`][exiftool] is the easiest way:

```bash
# Show every XMP field, including the p2m one
exiftool -XMP:all -G photo.jpg

# Pull just the edit stack JSON
exiftool -XMP-p2m:editStack -b photo.jpg | jq

# Human-readable summary
exiftool -ImageDescription -CreatorTool photo.jpg
```

On macOS without `exiftool`, Apple's `mdls` / Preview's Inspector
(`⌘I`) will show the `xmp:CreatorTool` and `tiff:ImageDescription`
values; the `p2m:editStack` JSON requires a real XMP reader.

## Stability

The `1.0/` segment in the namespace URI is the schema version.
Breaking changes (renaming a field, repurposing a value) would land in
`http://ns.photo2mac.cremenescu.ro/2.0/` (or higher). Additive changes
(new optional fields) stay within `1.0/`; older Photo2Mac versions
that don't understand the new field will ignore it.

[stack-src]: ../App/EditStack.swift
[exiftool]: https://exiftool.org/
