// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
import CoreImage
import AppKit
@testable import Photo2Mac

final class ImageRendererTests: XCTestCase {

    // MARK: - Fixtures

    /// 4x4 solid gray (0x80) image. Easy to read back exact pixel values.
    private func grayFixture() -> NSImage {
        let size = NSSize(width: 4, height: 4)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 128.0/255.0, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    /// Sample the rendered output by converting back to bitmap and reading pixel (0,0).
    private func samplePixel(_ image: NSImage) -> (r: Int, g: Int, b: Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    // MARK: - Neutral stack

    func testNeutralStackReturnsSameInstance() {
        let img = grayFixture()
        let out = ImageRenderer.render(original: img, stack: EditStack())
        XCTAssertTrue(out === img, "Neutral stack should bypass render")
    }

    // MARK: - Brightness

    func testBrightnessPositiveMakesPixelsLighter() throws {
        let img = grayFixture()
        var stack = EditStack()
        stack.adjustments.brightness = 1.0   // max in UI -> +0.5 in CI
        let out = ImageRenderer.render(original: img, stack: stack)
        let px = try XCTUnwrap(samplePixel(out))
        XCTAssertGreaterThan(px.r, 128 + 60, "Expected pixel brighter than 128+60, got \(px)")
    }

    func testBrightnessNegativeMakesPixelsDarker() throws {
        let img = grayFixture()
        var stack = EditStack()
        stack.adjustments.brightness = -1.0
        let out = ImageRenderer.render(original: img, stack: stack)
        let px = try XCTUnwrap(samplePixel(out))
        XCTAssertLessThan(px.r, 128 - 60, "Expected pixel darker than 128-60, got \(px)")
    }

    // MARK: - Saturation

    func testSaturationZeroProducesGrayscale() throws {
        // Use a red image, full desaturation should equalize channels.
        let size = NSSize(width: 4, height: 4)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()

        var stack = EditStack()
        stack.adjustments.saturation = -1.0  // -> CI value 0 (full desaturate)
        let out = ImageRenderer.render(original: img, stack: stack)
        let px = try XCTUnwrap(samplePixel(out))
        // Channels should be roughly equal; allow some Core Image rounding slack.
        XCTAssertLessThan(abs(px.r - px.g), 5)
        XCTAssertLessThan(abs(px.g - px.b), 5)
    }

    private func pixelDimensions(_ image: NSImage) -> (w: Int, h: Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return (cg.width, cg.height)
    }

    private func solidImage(width: Int, height: Int, color: NSColor) -> NSImage {
        // 1x scale via explicit bitmap rep, so pixel dims == logical dims.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ) else { fatalError("rep create failed") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: width, height: height))
        img.addRepresentation(rep)
        return img
    }

    // MARK: - Crop

    func testCropReducesExtent() throws {
        let img = solidImage(width: 100, height: 100, color: .blue)
        var stack = EditStack()
        stack.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let out = ImageRenderer.render(original: img, stack: stack)
        let dims = try XCTUnwrap(pixelDimensions(out))
        XCTAssertEqual(dims.w, 50)
        XCTAssertEqual(dims.h, 50)
    }

    // MARK: - Rotate

    func testRotate90SwapsDimensions() throws {
        let img = solidImage(width: 100, height: 50, color: .green)
        var stack = EditStack()
        stack.rotateDegrees = 90
        let out = ImageRenderer.render(original: img, stack: stack)
        let dims = try XCTUnwrap(pixelDimensions(out))
        XCTAssertEqual(dims.w, 50)
        XCTAssertEqual(dims.h, 100)
    }

    // MARK: - Equatable

    func testEditStackEquatable() {
        var a = EditStack()
        var b = EditStack()
        XCTAssertEqual(a, b)
        a.adjustments.brightness = 0.5
        XCTAssertNotEqual(a, b)
        b.adjustments.brightness = 0.5
        XCTAssertEqual(a, b)
    }

    func testAdjustmentsReset() {
        var a = Adjustments()
        a.brightness = 0.5
        a.exposure = 1.0
        XCTAssertFalse(a.isNeutral)
        a.reset()
        XCTAssertTrue(a.isNeutral)
    }

    // MARK: - Codable roundtrip (for future XMP)

    func testEditStackJSONRoundtrip() throws {
        var stack = EditStack()
        stack.rotateDegrees = 90
        stack.flipHorizontal = true
        stack.crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        stack.adjustments.brightness = 0.3
        stack.adjustments.exposure = -1.2

        let data = try JSONEncoder().encode(stack)
        let decoded = try JSONDecoder().decode(EditStack.self, from: data)
        XCTAssertEqual(stack, decoded)
    }
}
