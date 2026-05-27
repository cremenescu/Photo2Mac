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
    public static func render(original: NSImage,
                              sourceCI: CIImage? = nil,
                              stack: EditStack) -> NSImage {
        guard !stack.isNeutral else { return original }
        guard let ciIn = sourceCI ?? makeCIImage(from: original) else { return original }

        var ci = ciIn

        // Order: flip -> rotate -> crop -> adjustments
        // (geometry first so adjustments operate on the actually-displayed pixels)

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
        if let c = stack.crop, c.width > 0, c.height > 0 {
            let r = CGRect(
                x: c.x * ci.extent.width,
                y: c.y * ci.extent.height,
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

        guard let cg = sharedContext.createCGImage(ci, from: ci.extent) else { return original }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
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
