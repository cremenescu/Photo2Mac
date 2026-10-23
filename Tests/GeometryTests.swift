// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Photo2Mac

/// Geometry that has to survive the user changing their mind: crops that must
/// follow the subject through later rotations, flips that must act on what is
/// on screen, resizing, and sources that are not plain 72 dpi sRGB.
final class GeometryTests: XCTestCase {

    // MARK: - Fixtures

    /// 64x32, quadrants as seen on screen: top-left red, top-right green,
    /// bottom-left blue, bottom-right yellow.
    private func quadrants() -> NSImage {
        let w = 64, h = 32
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Context origin is bottom-left: the visual top half is the high-y half.
        NSColor.blue.setFill();   NSRect(x: 0, y: 0, width: 32, height: 16).fill()
        NSColor.yellow.setFill(); NSRect(x: 32, y: 0, width: 32, height: 16).fill()
        NSColor.red.setFill();    NSRect(x: 0, y: 16, width: 32, height: 16).fill()
        NSColor.green.setFill();  NSRect(x: 32, y: 16, width: 32, height: 16).fill()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        return img
    }

    private struct Pixels {
        let w: Int, h: Int
        let data: [UInt8]
        /// (r, g, b) at column x, row y counted from the TOP.
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }
    }

    private func pixels(_ image: NSImage) throws -> Pixels {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(w: w, h: h, data: data)
    }

    private func isRed(_ p: (Int, Int, Int)) -> Bool { p.0 > 200 && p.1 < 60 && p.2 < 60 }
    private func isGreen(_ p: (Int, Int, Int)) -> Bool { p.0 < 60 && p.1 > 200 && p.2 < 60 }
    private func isBlue(_ p: (Int, Int, Int)) -> Bool { p.0 < 60 && p.1 < 60 && p.2 > 200 }
    private func isYellow(_ p: (Int, Int, Int)) -> Bool { p.0 > 200 && p.1 > 200 && p.2 < 60 }

    private func writeFile(_ cg: CGImage, type: UTType, dpi: Double? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2m-geom-\(UUID().uuidString)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "img")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let dpi {
            props[kCGImagePropertyDPIWidth] = dpi
            props[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: - Sources that are not 72 dpi RGB

    /// Regression: rendering a grayscale source into an RGBA8 bitmap in the
    /// SOURCE's colour space fails, and the renderer used to return the
    /// untouched original — every edit of a grayscale photo was ignored.
    func testGrayscaleSourceIsActuallyEdited() throws {
        let w = 64, h = 64
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let url = try writeFile(try XCTUnwrap(ctx.makeImage()), type: .png)

        let doc = OpenImage(url: url, image: try XCTUnwrap(NSImage(contentsOf: url)))
        var stack = EditStack()
        stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        stack.adjustments.brightness = 1
        let out = ImageRenderer.render(original: doc.originalImage,
                                       sourceCI: doc.sourceCIImage, stack: stack)
        let px = try pixels(out)
        XCTAssertEqual(px.w, 32, "crop ignored on a grayscale source")
        XCTAssertGreaterThan(px.at(0, 0).0, 128 + 40, "brightness ignored on a grayscale source")
    }

    /// A 300 dpi photo is sized in points by NSImage (64 px -> 15 pt). The
    /// document must hold it in pixels, or the canvas and the info panel are
    /// wrong until the first edit and then jump.
    func testHighDPISourceIsHeldInPixels() throws {
        let cg = try XCTUnwrap(quadrants().cgImage(forProposedRect: nil, context: nil, hints: nil))
        let url = try writeFile(cg, type: .png, dpi: 300)
        let loaded = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertLessThan(loaded.size.width, 64, "fixture should be point-sized by NSImage")

        let doc = OpenImage(url: url, image: loaded)
        XCTAssertEqual(doc.originalImage.size, NSSize(width: 64, height: 32))
        XCTAssertEqual(doc.displayImage.size, NSSize(width: 64, height: 32))
    }

    // MARK: - Crop follows the subject

    func testQuarterTurnAfterCropKeepsTheSameSubject() throws {
        let img = quadrants()
        var stack = EditStack()
        // Top-left quadrant: red.
        stack.setCrop(CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        stack.rotateQuarter(clockwise: true)

        let px = try pixels(ImageRenderer.render(original: img, stack: stack))
        XCTAssertEqual(px.w, 16)
        XCTAssertEqual(px.h, 32)
        XCTAssertTrue(isRed(px.at(8, 16)), "rotating after a crop changed what is cropped: \(px.at(8, 16))")

        stack.rotateQuarter(clockwise: false)
        stack.rotateQuarter(clockwise: false)
        let back = try pixels(ImageRenderer.render(original: img, stack: stack))
        XCTAssertTrue(isRed(back.at(8, 16)))
    }

    func testFineRotationAfterCropKeepsTheSameSubject() throws {
        let img = quadrants()
        var stack = EditStack()
        // Bottom-right quadrant: yellow. Small enough that a 10° turn cannot
        // push its centre into another quadrant if it follows the subject.
        stack.setCrop(CropRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3))
        stack.rotateDegrees = 10

        let px = try pixels(ImageRenderer.render(original: img, stack: stack))
        XCTAssertTrue(isYellow(px.at(px.w / 2, px.h / 2)), "got \(px.at(px.w / 2, px.h / 2))")
    }

    func testEffectiveCropIsIdentityAtTheBasisAngle() {
        var stack = EditStack()
        stack.rotateDegrees = 12
        stack.setCrop(CropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(EditGeometry.effectiveCrop(for: stack, sourceSize: CGSize(width: 640, height: 480)),
                       stack.crop)
    }

    // MARK: - Flips act on what is on screen

    func testDisplayFlipOfRotatedImageMirrorsLeftRight() throws {
        let img = quadrants()
        var stack = EditStack()
        stack.rotateQuarter(clockwise: true)
        let before = try pixels(ImageRenderer.render(original: img, stack: stack))

        stack.flipDisplayHorizontal()
        let after = try pixels(ImageRenderer.render(original: img, stack: stack))

        XCTAssertEqual(after.w, before.w)
        XCTAssertEqual(after.h, before.h)
        for (x, y) in [(2, 2), (before.w - 3, 2), (2, before.h - 3), (before.w - 3, before.h - 3)] {
            let mirrored = before.at(before.w - 1 - x, y)
            let got = after.at(x, y)
            XCTAssertTrue(abs(mirrored.0 - got.0) < 30 && abs(mirrored.1 - got.1) < 30
                          && abs(mirrored.2 - got.2) < 30,
                          "(\(x),\(y)): expected \(mirrored), got \(got)")
        }
    }

    func testDisplayFlipMirrorsTheCrop() throws {
        let img = quadrants()
        var stack = EditStack()
        stack.setCrop(CropRect(x: 0, y: 0, width: 0.5, height: 0.5))   // red
        stack.flipDisplayHorizontal()
        // Mirrored left-right, the red quadrant is now top-right; the crop
        // must have moved with it.
        let px = try pixels(ImageRenderer.render(original: img, stack: stack))
        XCTAssertTrue(isRed(px.at(px.w / 2, px.h / 2)))

        stack.flipDisplayVertical()
        let px2 = try pixels(ImageRenderer.render(original: img, stack: stack))
        XCTAssertTrue(isRed(px2.at(px2.w / 2, px2.h / 2)))
    }

    // MARK: - Resize

    func testResizeKeepingAspectFitsInsideTheBox() throws {
        var stack = EditStack()
        stack.resize = ResizeSpec(width: 32, height: 32, keepsAspect: true)
        let px = try pixels(ImageRenderer.render(original: quadrants(), stack: stack))
        XCTAssertEqual(px.w, 32)
        XCTAssertEqual(px.h, 16)
        XCTAssertTrue(isRed(px.at(4, 4)))
        XCTAssertTrue(isYellow(px.at(28, 12)))
    }

    func testResizeExactStretches() throws {
        var stack = EditStack()
        stack.resize = ResizeSpec(width: 20, height: 40, keepsAspect: false)
        let px = try pixels(ImageRenderer.render(original: quadrants(), stack: stack))
        XCTAssertEqual(px.w, 20)
        XCTAssertEqual(px.h, 40)
    }

    func testResizeAppliesAfterCrop() throws {
        var stack = EditStack()
        stack.setCrop(CropRect(x: 0, y: 0, width: 0.5, height: 1))   // 32x32
        stack.resize = ResizeSpec(width: 100, height: 50, keepsAspect: true)
        XCTAssertEqual(EditGeometry.outputSize(for: stack, sourceSize: CGSize(width: 64, height: 32)),
                       CGSize(width: 50, height: 50))
        let px = try pixels(ImageRenderer.render(original: quadrants(), stack: stack))
        XCTAssertEqual(px.w, 50)
        XCTAssertEqual(px.h, 50)
        // Edges must not darken from sampling past the border.
        XCTAssertTrue(isRed(px.at(0, 0)), "edge darkened: \(px.at(0, 0))")
    }

    // MARK: - Stack format

    /// Stacks written before crop basis and resize existed must still open.
    func testOldStackJSONDecodes() throws {
        let json = #"{"crop":{"x":0.1,"y":0.2,"width":0.5,"height":0.5},"rotateDegrees":90,"flipHorizontal":false,"flipVertical":true,"adjustments":{"brightness":0.3,"contrast":0,"saturation":0,"exposure":0}}"#
        let s = try JSONDecoder().decode(EditStack.self, from: Data(json.utf8))
        XCTAssertEqual(s.rotateDegrees, 90)
        XCTAssertTrue(s.flipVertical)
        XCTAssertEqual(s.cropBasisDegrees, 0)
        XCTAssertNil(s.resize)
        XCTAssertEqual(s.adjustments.brightness, 0.3)
    }

    func testPartialAndUnknownFieldsDecode() throws {
        let json = #"{"rotateDegrees":5,"adjustments":{"exposure":1},"somethingFromTheFuture":[1,2]}"#
        let s = try JSONDecoder().decode(EditStack.self, from: Data(json.utf8))
        XCTAssertEqual(s.rotateDegrees, 5)
        XCTAssertEqual(s.adjustments.exposure, 1)
        XCTAssertNil(s.crop)
    }

    func testNewFieldsRoundTrip() throws {
        var s = EditStack()
        s.rotateDegrees = 30
        s.setCrop(CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        s.resize = ResizeSpec(width: 1920, height: 1080, keepsAspect: false)
        let back = try JSONDecoder().decode(EditStack.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.cropBasisDegrees, 30)
    }

    func testRemovingTheCropForgetsItsBasis() {
        var a = EditStack()
        a.rotateDegrees = 30
        a.setCrop(CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        a.crop = nil
        var b = EditStack()
        b.rotateDegrees = 30
        XCTAssertEqual(a, b, "a removed crop must not leave a phantom difference")
    }
}
