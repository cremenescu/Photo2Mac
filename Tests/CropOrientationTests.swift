// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
import AppKit
@testable import Photo2Mac

/// Which pixels a crop actually keeps.
///
/// The crop rect travels from a FLIPPED NSView (y grows downward, so y=0 is the
/// top of the image) through `CropEditState.normalized`, into `EditStack.crop`,
/// and is finally applied by `ImageRenderer` against a `CIImage`, whose origin
/// is at the BOTTOM. If nothing flips y along the way, cropping the top half
/// yields the bottom half.
///
/// The existing crop test uses a solid-colour fixture and a crop that is
/// symmetric on both axes, so it cannot see this.
final class CropOrientationTests: XCTestCase {

    /// 64x64: top half red, bottom half blue.
    private func makeTopRedBottomBlue() throws -> NSImage {
        let size = 64
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { throw XCTSkip("no bitmap context") }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // Context origin is bottom-left: the visual TOP half is the high-y half.
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: size, height: size / 2).fill()
        NSColor.red.setFill()
        NSRect(x: 0, y: size / 2, width: size, height: size / 2).fill()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }

    /// Dominant colour of a rendered image, sampled at its centre.
    private func centreColour(_ image: NSImage) throws -> (r: Int, g: Int, b: Int) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTSkip("no cgImage") }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.deviceRGB)
        else { throw XCTSkip("no colour") }
        return (Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()))
    }

    /// The user drags a crop over the visually TOP half of the image.
    /// In the flipped canvas that is y = 0 ..< height/2, which
    /// `CropEditState.normalized` turns into CropRect(y: 0, height: 0.5).
    /// The rendered result must be the RED half.
    func testCroppingTheTopHalfKeepsTheTopHalf() throws {
        let img = try makeTopRedBottomBlue()

        // Sanity: the fixture really is red on top.
        let whole = try centreColourOfHalf(img, top: true)
        XCTAssertTrue(whole.r > 180 && whole.b < 90,
                      "fixture should be red in its top half, got \(whole)")

        var stack = EditStack()
        stack = applyingCrop(stack, CropRect(x: 0, y: 0, width: 1, height: 0.5))

        let out = ImageRenderer.render(original: img,
                                       sourceCI: ImageRenderer.makeCIImage(from: img),
                                       stack: stack)
        let c = try centreColour(out)
        XCTAssertTrue(c.r > 180 && c.b < 90,
                      "cropping the top half returned \(c) — expected red (the top half). "
                      + "A blue result means the crop is vertically mirrored.")
    }

    /// Mirror of the above so a sign flip cannot make both pass.
    func testCroppingTheBottomHalfKeepsTheBottomHalf() throws {
        let img = try makeTopRedBottomBlue()

        var stack = EditStack()
        stack = applyingCrop(stack, CropRect(x: 0, y: 0.5, width: 1, height: 0.5))

        let out = ImageRenderer.render(original: img,
                                       sourceCI: ImageRenderer.makeCIImage(from: img),
                                       stack: stack)
        let c = try centreColour(out)
        XCTAssertTrue(c.b > 180 && c.r < 90,
                      "cropping the bottom half returned \(c) — expected blue (the bottom half).")
    }

    // MARK: - helpers

    private func applyingCrop(_ stack: EditStack, _ crop: CropRect) -> EditStack {
        var s = stack
        s.crop = crop
        return s
    }

    private func centreColourOfHalf(_ image: NSImage, top: Bool) throws -> (r: Int, g: Int, b: Int) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTSkip("no cgImage") }
        let rep = NSBitmapImageRep(cgImage: cg)
        // NSBitmapImageRep.colorAt uses y=0 at the TOP.
        let y = top ? rep.pixelsHigh / 4 : (rep.pixelsHigh * 3) / 4
        guard let c = rep.colorAt(x: rep.pixelsWide / 2, y: y)?
            .usingColorSpace(.deviceRGB)
        else { throw XCTSkip("no colour") }
        return (Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()))
    }
}
