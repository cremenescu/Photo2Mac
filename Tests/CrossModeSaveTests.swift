// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
import AppKit
@testable import Photo2Mac

/// Changing the save-mode preference while a document is open.
///
/// The Settings copy tells the user this is safe, and it is the one thing the
/// original mode tests did not cover: they reopened files under different
/// settings, but never SAVED under a mode other than the one that wrote the
/// file. Doing so used to re-apply the whole stack onto pixels that already
/// contained it, shrinking an image 64 -> 32 -> 16 -> 8 px over four saves.
final class CrossModeSaveTests: XCTestCase {

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2m-cross-\(UUID().uuidString).png")
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
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: size, height: size / 2).fill()
        NSColor.red.setFill()
        NSRect(x: 0, y: size / 2, width: size, height: size / 2).fill()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:])
        else { throw XCTSkip("no png") }
        try data.write(to: url)
        return url
    }

    private func widthOnDisk(_ url: URL) throws -> Int {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTSkip("unreadable") }
        return cg.width
    }

    /// What the user would see after reopening.
    private func widthOnReopen(_ url: URL) throws -> Int {
        guard var img = NSImage(contentsOf: url) else { throw XCTSkip("unreadable") }
        var live = EditStack()
        if case .editable(let stack, let embedded) = SavedState.resolve(for: url) {
            if let embedded, let original = NSImage(data: embedded) { img = original }
            live = stack
        }
        let shown = ImageRenderer.render(original: img,
                                         sourceCI: ImageRenderer.makeCIImage(from: img),
                                         stack: live)
        guard let cg = shown.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTSkip("no cgImage") }
        return cg.width
    }

    /// Save in every mode, one after another, on the SAME open document —
    /// exactly what a user does after reading the Settings blurb. The image
    /// must never shrink past the single crop that was actually applied.
    func testCyclingThroughEveryModeNeverReappliesTheCrop() throws {
        for order in [[SaveMode.flattened, .sidecar, .embeddedOriginal],
                      [.embeddedOriginal, .sidecar, .flattened],
                      [.sidecar, .flattened, .embeddedOriginal],
                      [.sidecar, .embeddedOriginal, .flattened]] {
            let url = try fixture()
            defer {
                try? FileManager.default.removeItem(at: url)
                SidecarStore.clear(for: url)
            }
            guard let img = NSImage(contentsOf: url) else { throw XCTSkip("x") }
            let doc = OpenImage(url: url, image: img)
            doc.stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)

            for (i, mode) in order.enumerated() {
                XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: mode),
                                "\(order) step \(i) (\(mode)) failed to save")
                // 64 wide, cropped to half = 32. Ever seeing 16 means the crop
                // was applied to pixels that already contained it.
                XCTAssertEqual(try widthOnReopen(url), 32,
                               "\(order): after saving as \(mode) the reopened image is not 32px")
            }
        }
    }

    /// The specific case the audit reproduced: flatten, then switch to
    /// "keep the original inside". There is no pristine copy left on disk, so
    /// the app must not pass the edited image off as the original.
    func testFlattenThenEmbedDoesNotPassOffTheEditedImageAsTheOriginal() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let trueOriginal = try Data(contentsOf: url)

        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("x") }
        let doc = OpenImage(url: url, image: img)
        doc.stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)

        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .flattened))
        XCTAssertEqual(try widthOnDisk(url), 32)

        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .embeddedOriginal))
        if let b64 = XMPStack.readP2MString(SavedState.originalProperty, from: url),
           let embedded = Data(base64Encoded: b64) {
            XCTAssertEqual(embedded, trueOriginal,
                           "the edited image was embedded and labelled 'the original'")
        }
        XCTAssertEqual(try widthOnReopen(url), 32,
                       "reopening after the mode switch re-applied the crop")
    }

    /// A sidecar written before a flattening save must not be honoured
    /// afterwards — its stack is already in the pixels.
    func testStaleSidecarIsNotAppliedToFlattenedPixels() throws {
        let url = try fixture()
        defer {
            try? FileManager.default.removeItem(at: url)
            SidecarStore.clear(for: url)
        }
        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("x") }
        let doc = OpenImage(url: url, image: img)
        doc.stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)

        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .sidecar))
        XCTAssertTrue(SidecarStore.exists(for: url))
        XCTAssertEqual(try widthOnDisk(url), 64, "sidecar mode modified the image")

        // Now flatten. The sidecar must stop being authoritative.
        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .flattened))
        XCTAssertEqual(try widthOnDisk(url), 32)
        XCTAssertEqual(try widthOnReopen(url), 32,
                       "a leftover sidecar re-applied the crop to baked pixels")
    }

    /// A corrupt or non-image payload must never be adopted as "the original".
    func testUndecodableEmbeddedOriginalIsRejected() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("x") }
        let doc = OpenImage(url: url, image: img)
        doc.stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .embeddedOriginal))

        // Rewrite the payload with valid base64 that is not an image.
        guard let cg = NSImage(contentsOf: url)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil),
              let uti = XMPStack.utiType(for: url)
        else { throw XCTSkip("x") }
        XCTAssertTrue(XMPStack.write(
            stack: doc.stack, image: cg, to: url, utiType: uti, sourceURL: url,
            extraTags: [SavedState.modeProperty: SaveMode.embeddedOriginal.rawValue,
                        SavedState.originalProperty:
                            Data(repeating: 0x41, count: 4096).base64EncodedString()]))

        guard case .flattened = SavedState.resolve(for: url) else {
            return XCTFail("a non-image payload was accepted as the original")
        }
        XCTAssertEqual(try widthOnReopen(url), 32,
                       "crop was re-applied on top of a bogus 'original'")
    }
}
