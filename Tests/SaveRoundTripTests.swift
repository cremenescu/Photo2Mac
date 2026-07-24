// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Photo2Mac

/// The save -> reopen cycle. `SaveService.write` bakes the stack into the
/// pixels AND embeds the same stack as XMP; `Workspace.restoreEdits` reads
/// that XMP back and applies it again. These tests pin down what the pixels
/// actually look like after a round trip, so a regression is loud.
final class SaveRoundTripTests: XCTestCase {

    // MARK: - Fixture

    /// An asymmetric image: a single opaque red pixel in the TOP-LEFT of an
    /// otherwise white canvas. Asymmetry is the point — a symmetric fixture
    /// cannot detect a flip or a double rotation.
    private func makeMarkedPNG(size: Int = 32) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2m-rt-\(UUID().uuidString).png")
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { throw XCTSkip("no bitmap rep") }

        // Draw through a graphics context: setColor(atX:y:) on a fresh rep is
        // unreliable (premultiplied alpha), and a wrong fixture would make
        // these tests lie.
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { throw XCTSkip("no context") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        // Context origin is bottom-left, so the top-left marker is at high y.
        NSColor.red.setFill()
        NSRect(x: 0, y: size - 4, width: 4, height: 4).fill()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("no png data") }
        try data.write(to: url)
        return url
    }

    /// Colour at a normalized position of the image's CGImage, sampled from
    /// the top-left origin (y down), which is how the marker was written.
    private func color(of image: NSImage, atFractionX fx: CGFloat, y fy: CGFloat)
        throws -> (r: Int, g: Int, b: Int)
    {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTSkip("no cgImage") }
        let rep = NSBitmapImageRep(cgImage: cg)
        let x = min(rep.pixelsWide - 1, max(0, Int(CGFloat(rep.pixelsWide) * fx)))
        let y = min(rep.pixelsHigh - 1, max(0, Int(CGFloat(rep.pixelsHigh) * fy)))
        guard let c = rep.colorAt(x: x, y: y)?
            .usingColorSpace(.deviceRGB)
        else { throw XCTSkip("no colour") }
        return (Int((c.redComponent * 255).rounded()),
                Int((c.greenComponent * 255).rounded()),
                Int((c.blueComponent * 255).rounded()))
    }

    private func isRedish(_ c: (r: Int, g: Int, b: Int)) -> Bool {
        c.r > 180 && c.g < 90 && c.b < 90
    }

    // MARK: - The round trip

    /// Save a 90-degree rotation, then reopen the saved file the way the app
    /// does (load pixels + restore the XMP stack) and render.
    ///
    /// The saved PIXELS are already rotated. If the restored stack is applied
    /// on top of them, the result is rotated 180 degrees in total and the
    /// marker lands in the bottom-right instead of the top-right.
    func testSavedRotationIsNotAppliedTwiceOnReopen() throws {
        let src = try makeMarkedPNG()
        defer { try? FileManager.default.removeItem(at: src) }

        guard let original = NSImage(contentsOf: src) else {
            throw XCTSkip("fixture unreadable")
        }
        // Sanity: marker starts top-left.
        XCTAssertTrue(isRedish(try color(of: original, atFractionX: 0.05, y: 0.05)),
                      "fixture marker should start in the top-left")

        // 1. Rotate 90 degrees clockwise and save in place.
        let doc = OpenImage(url: src, image: original)
        doc.stack.rotateDegrees = 90
        let out = SaveService.write(doc: doc, to: src)
        XCTAssertNotNil(out, "save should succeed")

        // 2. Reopen exactly like Workspace.open does.
        guard let reloaded = NSImage(contentsOf: src) else {
            throw XCTSkip("saved file unreadable")
        }
        // The pixels on disk are already rotated: marker now top-right.
        XCTAssertTrue(isRedish(try color(of: reloaded, atFractionX: 0.95, y: 0.05)),
                      "saved pixels should already carry the 90-degree rotation")

        // 3. Resolve the file the way the app does on open.
        let live = liveStack(for: src)

        // 4. Render the reopened document — this is what the user sees.
        let shown = ImageRenderer.render(original: reloaded,
                                         sourceCI: ImageRenderer.makeCIImage(from: reloaded),
                                         stack: live)

        // The marker must still be top-right. If the stack was re-applied it is
        // now bottom-right (180 degrees total).
        let bottomRight = try color(of: shown, atFractionX: 0.95, y: 0.95)
        XCTAssertFalse(isRedish(bottomRight),
                       "reopening re-applied the saved rotation: the image is rotated twice")

        let topRight = try color(of: shown, atFractionX: 0.95, y: 0.05)
        XCTAssertTrue(isRedish(topRight),
                      "after reopening, the marker should still be top-right (rotation applied exactly once)")
    }

    /// Same idea for a crop, which is the more destructive case: the saved file
    /// is already cropped, so re-applying a normalized crop rect crops a crop.
    func testSavedCropIsNotAppliedTwiceOnReopen() throws {
        let src = try makeMarkedPNG(size: 64)
        defer { try? FileManager.default.removeItem(at: src) }

        guard let original = NSImage(contentsOf: src) else {
            throw XCTSkip("fixture unreadable")
        }
        let fullPixels = try pixelSize(of: original)

        let doc = OpenImage(url: src, image: original)
        doc.stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        XCTAssertNotNil(SaveService.write(doc: doc, to: src))

        guard let reloaded = NSImage(contentsOf: src) else {
            throw XCTSkip("saved file unreadable")
        }
        let savedPixels = try pixelSize(of: reloaded)
        XCTAssertEqual(savedPixels.w, fullPixels.w / 2, accuracy: 2,
                       "saved file should be half width")

        let shown = ImageRenderer.render(original: reloaded,
                                         sourceCI: ImageRenderer.makeCIImage(from: reloaded),
                                         stack: liveStack(for: src))
        let shownPixels = try pixelSize(of: shown)

        XCTAssertEqual(shownPixels.w, savedPixels.w, accuracy: 2,
                       "reopening re-applied the saved crop: the image shrank again")
    }

    /// The stack the app would make live for this file, resolved from the file
    /// itself (not from the current save-mode preference).
    private func liveStack(for url: URL) -> EditStack {
        switch SavedState.resolve(for: url) {
        case .editable(let stack, _): return stack
        case .flattened, .none:       return EditStack()
        }
    }

    private func pixelSize(of image: NSImage) throws -> (w: CGFloat, h: CGFloat) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTSkip("no cgImage") }
        return (CGFloat(cg.width), CGFloat(cg.height))
    }
}
