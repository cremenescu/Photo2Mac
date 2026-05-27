// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Photo2Mac

final class PersistenceTests: XCTestCase {

    // MARK: - Helpers

    /// Build a small JPEG fixture in tmp and return its URL.
    private func makeFixtureJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2m-fix-\(UUID().uuidString).jpg")
        let size = NSSize(width: 16, height: 16)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 64, bitsPerPixel: 32) else {
            XCTFail("Cannot create rep")
            return url
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .jpeg, properties: [:])!
        try data.write(to: url)
        return url
    }

    // MARK: - AutosaveStore

    func testAutosaveSaveLoadRoundtrip() {
        let store = AutosaveStore()
        let url = URL(fileURLWithPath: "/tmp/photo2mac-autosave-test-\(UUID().uuidString).png")
        var s = EditStack()
        s.rotateDegrees = 90
        s.flipHorizontal = true
        s.adjustments.brightness = 0.3

        store.save(s, for: url)
        XCTAssertTrue(store.exists(for: url))
        let loaded = store.load(for: url)
        XCTAssertEqual(loaded, s)

        store.clear(for: url)
        XCTAssertFalse(store.exists(for: url))
    }

    func testAutosaveDoesNotPersistNeutralStack() {
        let store = AutosaveStore()
        let url = URL(fileURLWithPath: "/tmp/photo2mac-autosave-neutral-\(UUID().uuidString).png")
        store.save(EditStack(), for: url)
        XCTAssertFalse(store.exists(for: url),
                       "Neutral stack should not create an autosave file")
    }

    func testAutosaveDifferentURLsAreIndependent() {
        let store = AutosaveStore()
        let u1 = URL(fileURLWithPath: "/tmp/photo2mac-A-\(UUID().uuidString).png")
        let u2 = URL(fileURLWithPath: "/tmp/photo2mac-B-\(UUID().uuidString).png")
        var s1 = EditStack(); s1.rotateDegrees = 90
        var s2 = EditStack(); s2.rotateDegrees = 270
        store.save(s1, for: u1)
        store.save(s2, for: u2)
        XCTAssertEqual(store.load(for: u1)?.rotateDegrees, 90)
        XCTAssertEqual(store.load(for: u2)?.rotateDegrees, 270)
        store.clear(for: u1); store.clear(for: u2)
    }

    // MARK: - XMP

    func testXMPRoundtripOnJPEG() throws {
        let inURL = try makeFixtureJPEG()
        defer { try? FileManager.default.removeItem(at: inURL) }

        // Read the source as CGImage.
        guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            XCTFail("Cannot load fixture")
            return
        }

        var stack = EditStack()
        stack.rotateDegrees = 180
        stack.adjustments.contrast = 0.4
        stack.crop = CropRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2m-xmp-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let ok = XMPStack.write(stack: stack, image: cg, to: outURL,
                                  utiType: UTType.jpeg.identifier as CFString)
        XCTAssertTrue(ok)

        guard let decoded = XMPStack.read(from: outURL) else {
            XCTFail("XMP read returned nil")
            return
        }
        XCTAssertEqual(decoded, stack)
    }

    func testXMPReadReturnsNilForFileWithoutOurMetadata() throws {
        let url = try makeFixtureJPEG()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(XMPStack.read(from: url))
    }
}
