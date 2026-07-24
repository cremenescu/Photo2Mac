// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
import AppKit
@testable import Photo2Mac

/// The three save modes, and the rule that keeps them from corrupting each
/// other: the SETTING decides how a file is written, the FILE decides how it is
/// read.
final class SaveModeTests: XCTestCase {

    /// 64x64, top half red, bottom half blue — asymmetric so a mirrored or
    /// doubly-applied crop is visible.
    private func makeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2m-mode-\(UUID().uuidString).png")
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

    private func pixelWidth(of url: URL) throws -> Int {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTSkip("unreadable") }
        return cg.width
    }

    /// Open the file the way Workspace.open does, and report what the user
    /// would end up seeing.
    private func reopen(_ url: URL) throws -> (renderedWidth: Int, liveStack: EditStack) {
        let saved = SavedState.resolve(for: url)
        guard var img = NSImage(contentsOf: url) else { throw XCTSkip("unreadable") }
        var live = EditStack()
        switch saved {
        case .editable(let stack, let embedded):
            if let embedded, let original = NSImage(data: embedded) { img = original }
            live = stack
        case .flattened:
            live = EditStack()
        case .none:
            live = EditStack()
        }
        let shown = ImageRenderer.render(original: img,
                                         sourceCI: ImageRenderer.makeCIImage(from: img),
                                         stack: live)
        guard let cg = shown.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw XCTSkip("no cgImage") }
        return (cg.width, live)
    }

    // MARK: - Mode A

    func testFlattenedModeBakesPixelsAndDoesNotReapply() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("x") }
        let doc = OpenImage(url: url, image: img)
        doc.stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .flattened))

        // Pixels on disk are cropped.
        XCTAssertEqual(try pixelWidth(of: url), 32, "file should be half width")
        // Reopening must NOT crop again.
        let after = try reopen(url)
        XCTAssertEqual(after.renderedWidth, 32,
                       "flattened file was cropped a second time on reopen")
        XCTAssertNil(after.liveStack.crop,
                     "a flattened file must reopen with a neutral live stack")
    }

    // MARK: - Mode B

    func testSidecarModeLeavesTheOriginalUntouched() throws {
        let url = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: url)
            SidecarStore.clear(for: url)
        }
        let bytesBefore = try Data(contentsOf: url)

        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("x") }
        let doc = OpenImage(url: url, image: img)
        doc.stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .sidecar))

        // The image file must be byte-identical.
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore,
                       "sidecar mode modified the original image file")
        XCTAssertTrue(SidecarStore.exists(for: url), "no .p2m sidecar was written")

        // Reopening applies the sidecar stack to the untouched pixels.
        let after = try reopen(url)
        XCTAssertEqual(after.renderedWidth, 32,
                       "sidecar edits were not applied on reopen")
        XCTAssertNotNil(after.liveStack.crop,
                        "sidecar mode must reopen fully editable")
    }

    /// A sidecar left next to a file that has since changed must be ignored,
    /// or it applies a crop that describes different pixels.
    func testSidecarIsIgnoredWhenTheImageChanged() throws {
        let url = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: url)
            SidecarStore.clear(for: url)
        }
        var stack = EditStack()
        stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        XCTAssertTrue(SidecarStore.write(stack: stack, for: url))
        XCTAssertNotNil(SidecarStore.read(for: url))

        // Replace the image with a different one at the same path.
        let other = try makeFixture()
        defer { try? FileManager.default.removeItem(at: other) }
        var bytes = try Data(contentsOf: other)
        bytes.append(contentsOf: [0x00, 0x01, 0x02])   // change the size
        try bytes.write(to: url)

        XCTAssertNil(SidecarStore.read(for: url),
                     "a stale sidecar was applied to a different file")
    }

    // MARK: - Mode C

    func testEmbeddedOriginalModeStaysFullyEditable() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let originalBytes = try Data(contentsOf: url)

        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("x") }
        let doc = OpenImage(url: url, image: img)
        doc.stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .embeddedOriginal))

        // Other apps see the cropped image.
        XCTAssertEqual(try pixelWidth(of: url), 32,
                       "embedded mode should still flatten the visible pixels")

        // Photo2Mac recovers the original and re-applies the crop exactly once.
        let saved = SavedState.resolve(for: url)
        guard case .editable(let stack, let embedded) = saved else {
            return XCTFail("embedded file did not resolve as editable")
        }
        XCTAssertNotNil(stack.crop, "the stack was not preserved")
        XCTAssertEqual(embedded, originalBytes,
                       "the embedded original does not match the source bytes")

        let after = try reopen(url)
        XCTAssertEqual(after.renderedWidth, 32,
                       "reopening an embedded-original file changed the result")
    }

    // MARK: - The rule that ties them together

    /// Files must be read the way they were WRITTEN, regardless of what the
    /// preference happens to be now. Without this, changing the setting
    /// silently corrupts previously saved work.
    func testFileIsReadTheWayItWasWrittenNotHowTheSettingSaysNow() throws {
        let flat = try makeFixture()
        let embedded = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: flat)
            try? FileManager.default.removeItem(at: embedded)
        }

        for (url, mode) in [(flat, SaveMode.flattened), (embedded, .embeddedOriginal)] {
            guard let img = NSImage(contentsOf: url) else { throw XCTSkip("x") }
            let doc = OpenImage(url: url, image: img)
            doc.stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
            XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: mode))
        }

        // Whatever the preference is now, both must render at the same width.
        for pref in SaveMode.allCases {
            AppSettings.shared.saveMode = pref
            XCTAssertEqual(try reopen(flat).renderedWidth, 32,
                           "flattened file misread while the setting was \(pref)")
            XCTAssertEqual(try reopen(embedded).renderedWidth, 32,
                           "embedded file misread while the setting was \(pref)")
        }
        AppSettings.shared.saveMode = .flattened
    }

    /// Files written by v0.1.0 – v0.2.1 carry a stack with no mode marker and
    /// already-baked pixels. They must be read as flattened, or every reopen
    /// keeps compounding the edits.
    func testLegacyFileWithoutModeMarkerIsTreatedAsFlattened() throws {
        let url = try makeFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        // Reproduce exactly what the old code wrote: baked pixels + the stack,
        // and no saveMode property.
        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("x") }
        var stack = EditStack()
        stack.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        let rendered = ImageRenderer.render(original: img,
                                            sourceCI: ImageRenderer.makeCIImage(from: img),
                                            stack: stack)
        guard let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let uti = XMPStack.utiType(for: url)
        else { throw XCTSkip("no cgImage") }
        XCTAssertTrue(XMPStack.write(stack: stack, image: cg, to: url, utiType: uti))

        XCTAssertNil(XMPStack.readP2MString(SavedState.modeProperty, from: url),
                     "fixture should have no mode marker")

        guard case .flattened = SavedState.resolve(for: url) else {
            return XCTFail("a legacy file was resolved as editable — it will be double-applied")
        }
        XCTAssertEqual(try reopen(url).renderedWidth, 32,
                       "legacy file was cropped twice")
    }
}
