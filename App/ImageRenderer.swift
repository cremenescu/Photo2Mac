// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// Pure renderer: original NSImage + EditStack -> displayable NSImage.
/// No state besides a shared CIContext. Safe to call on background threads.
public enum ImageRenderer {

    public static let sharedContext: CIContext = {
        // GPU-backed when available.
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev)
        }
        return CIContext(options: nil)
    }()

    /// Render the original image through the stack and return a new NSImage.
    /// `sourceCI` lets callers avoid re-converting NSImage->CIImage on every render
    /// (slider live preview hammers this path).
    ///
    /// The result is always sized in pixels (1 point = 1 pixel), like the
    /// originals `OpenImage` holds, so the canvas does not jump in size between
    /// a neutral stack and the first edit of a 300 dpi file.
    public static func render(original: NSImage,
                              sourceCI: CIImage? = nil,
                              stack: EditStack) -> NSImage {
        guard !stack.isNeutral else { return original }
        guard let ciIn = sourceCI ?? makeCIImage(from: original) else { return original }
        let ci = pipeline(ciIn, stack: stack)
        guard let cg = makeCGImage(ci, sourceSpace: ciIn.colorSpace) else { return original }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// The whole stack as a Core Image graph, without rendering it.
    /// Order: flip -> rotate -> crop -> adjustments -> resize (geometry first so
    /// adjustments operate on the actually-displayed pixels, resize last so it
    /// resamples the final result once).
    public static func pipeline(_ ciIn: CIImage, stack: EditStack) -> CIImage {
        var ci = ciIn
        let sourceSize = ciIn.extent.size

        if stack.flipHorizontal {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                   .transformed(by: CGAffineTransform(translationX: ci.extent.width, y: 0))
        }
        if stack.flipVertical {
            ci = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                   .transformed(by: CGAffineTransform(translationX: 0, y: ci.extent.height))
        }
        if abs(stack.rotateDegrees) > 0.0001 {
            let rad = -CGFloat(stack.rotateDegrees) * .pi / 180.0  // CG is CCW, UI is CW
            let rotated = ci.transformed(by: CGAffineTransform(rotationAngle: rad))
            // Translate back to origin (0,0) for clean extent.
            let dx = -rotated.extent.origin.x
            let dy = -rotated.extent.origin.y
            ci = rotated.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        }
        if let c = EditGeometry.effectiveCrop(for: stack, sourceSize: sourceSize),
           c.width > 0, c.height > 0 {
            // CropRect.y is measured from the TOP of the image: it is produced
            // by CropEditState against the canvas NSView, which is flipped
            // (ImageCanvasView: isFlipped = true). A CIImage built from a
            // CGImage has its origin at the BOTTOM, so y must be flipped here
            // or every off-centre crop keeps the mirrored band.
            let r = CGRect(
                x: c.x * ci.extent.width,
                y: (1.0 - c.y - c.height) * ci.extent.height,
                width: c.width * ci.extent.width,
                height: c.height * ci.extent.height
            )
            ci = ci.cropped(to: r)
                   .transformed(by: CGAffineTransform(translationX: -r.origin.x, y: -r.origin.y))
        }

        let adj = stack.adjustments
        if !adj.isNeutral {
            ci = applyAdjustments(adj, to: ci)
        }

        if let spec = stack.resize {
            ci = resize(ci, to: EditGeometry.resizedSize(spec, from: ci.extent.size))
        }
        return ci
    }

    /// Lanczos resample to exactly `target` pixels.
    static func resize(_ image: CIImage, to target: CGSize) -> CIImage {
        let src = image.extent
        guard src.width > 0, src.height > 0,
              abs(src.width - target.width) > 0.5 || abs(src.height - target.height) > 0.5
        else { return image }
        let sy = target.height / src.height
        let sx = target.width / src.width
        let f = CIFilter.lanczosScaleTransform()
        // Clamp first: without it the kernel samples transparent pixels past
        // the edge and every border comes out darker than the image.
        f.inputImage = image.clampedToExtent()
        f.scale = Float(sy)
        f.aspectRatio = Float(sx / sy)
        guard let out = f.outputImage else { return image }
        return out.cropped(to: CGRect(origin: .zero, size: target))
    }

    /// Render `ci` into a CGImage in the source's colour space when that is an
    /// RGB space, else in sRGB.
    ///
    /// Rendering into the SOURCE's space matters: without it createCGImage
    /// falls back to DeviceRGB and a Display P3 or Adobe RGB photo loses its
    /// gamut on the first edit — measured: P3 [254,0,0] came out [233,51,35].
    /// But a grayscale (or CMYK) space cannot back an RGBA8 bitmap: Core Image
    /// returns nil, and the old fallback then handed back the untouched
    /// original, so every edit of a grayscale photo was silently ignored.
    static func makeCGImage(_ ci: CIImage, sourceSpace: CGColorSpace?) -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = (sourceSpace?.model == .rgb) ? sourceSpace! : srgb
        if let cg = sharedContext.createCGImage(ci, from: ci.extent,
                                                format: .RGBA8, colorSpace: space) {
            return cg
        }
        guard space !== srgb else { return nil }
        return sharedContext.createCGImage(ci, from: ci.extent,
                                           format: .RGBA8, colorSpace: srgb)
    }

    /// The image as pixels: an NSImage whose size in points equals its size in
    /// pixels, with EXIF orientation already applied (NSImage does that).
    ///
    /// NSImage sizes a 300 dpi photo in points — 4000 px wide becomes 960 pt —
    /// while everything Photo2Mac renders is sized in pixels. Mixing the two
    /// made the canvas jump on the first edit and the info panel report the
    /// wrong dimensions.
    public static func pixelSized(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let px = NSSize(width: cg.width, height: cg.height)
        if image.size == px { return image }
        return NSImage(cgImage: cg, size: px)
    }

    /// Apply adjustments to CIImage and return new CIImage.
    /// Exposed for unit tests so they can exercise the pipeline cheaply.
    public static func applyAdjustments(_ a: Adjustments, to image: CIImage) -> CIImage {
        var out = image

        // CIColorControls: brightness [-1,1] additive, contrast [0,inf] mult, saturation [0,2]
        // Map UI's -1...1 to subtle ranges.
        let needsColorControls = a.brightness != 0 || a.contrast != 0 || a.saturation != 0
        if needsColorControls {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.brightness = Float(a.brightness * 0.5)        // -0.5 ... 0.5
            f.contrast = Float(1.0 + a.contrast * 0.5)      // 0.5 ... 1.5
            f.saturation = Float(1.0 + a.saturation)        // 0 ... 2
            if let o = f.outputImage { out = o }
        }

        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = out
            f.ev = Float(a.exposure)
            if let o = f.outputImage { out = o }
        }

        return out
    }

    /// Convert NSImage to CIImage going through the best CGImage we can produce.
    public static func makeCIImage(from image: NSImage) -> CIImage? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CIImage(cgImage: cg)
        }
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let cg = rep.cgImage {
            return CIImage(cgImage: cg)
        }
        return nil
    }
}
