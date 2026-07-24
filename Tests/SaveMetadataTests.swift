// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Photo2Mac

/// Saving must not destroy the metadata the photographer's camera wrote.
/// `XMPStack.write` builds a fresh CGImageMetadata, so unless the source
/// properties are explicitly carried over they are dropped on the floor:
/// camera, lens, ISO, shutter, aperture, capture date, GPS and copyright.
final class SaveMetadataTests: XCTestCase {

    /// A JPEG carrying EXIF / TIFF / GPS, like a file straight off a camera.
    private func makeCameraJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2m-exif-\(UUID().uuidString).jpg")
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
        NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.7, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = rep.cgImage else { throw XCTSkip("no cgImage") }

        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "EF 24-70mm f/2.8L II USM",
                kCGImagePropertyExifISOSpeedRatings: [400],
                kCGImagePropertyExifExposureTime: 0.008,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifDateTimeOriginal: "2026:05:20 14:31:07",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "EOS R5",
                kCGImagePropertyTIFFCopyright: "(c) 2026 Razvan Cremenescu",
            ] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 44.4268,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 26.1025,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any],
        ]
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw XCTSkip("no destination") }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("write failed") }
        return url
    }

    private func properties(of url: URL) throws -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { throw XCTSkip("no properties") }
        return p
    }

    private func dict(_ p: [CFString: Any], _ key: CFString) -> [CFString: Any] {
        (p[key] as? [CFString: Any]) ?? [:]
    }

    /// Camera identification and shooting parameters must survive a save.
    func testSavePreservesExifCameraAndExposure() throws {
        let url = try makeCameraJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try properties(of: url)
        XCTAssertEqual(dict(before, kCGImagePropertyTIFFDictionary)[kCGImagePropertyTIFFModel] as? String,
                       "EOS R5", "fixture should carry the camera model")

        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("unreadable") }
        let doc = OpenImage(url: url, image: img)
        doc.stack.adjustments.brightness = 0.1
        XCTAssertNotNil(SaveService.write(doc: doc, to: url), "save should succeed")

        let after = try properties(of: url)
        let tiff = dict(after, kCGImagePropertyTIFFDictionary)
        let exif = dict(after, kCGImagePropertyExifDictionary)

        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Canon",
                       "camera make was destroyed by save")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "EOS R5",
                       "camera model was destroyed by save")
        XCTAssertEqual(exif[kCGImagePropertyExifLensModel] as? String,
                       "EF 24-70mm f/2.8L II USM",
                       "lens model was destroyed by save")
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                       "2026:05:20 14:31:07",
                       "capture date was destroyed by save")
        XCTAssertNotNil(exif[kCGImagePropertyExifISOSpeedRatings],
                        "ISO was destroyed by save")
    }

    /// Losing the copyright tag on someone's photo is not a cosmetic bug.
    func testSavePreservesCopyright() throws {
        let url = try makeCameraJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("unreadable") }
        let doc = OpenImage(url: url, image: img)
        doc.stack.rotateDegrees = 90
        XCTAssertNotNil(SaveService.write(doc: doc, to: url))

        let tiff = dict(try properties(of: url), kCGImagePropertyTIFFDictionary)
        XCTAssertEqual(tiff[kCGImagePropertyTIFFCopyright] as? String,
                       "(c) 2026 Razvan Cremenescu",
                       "copyright was destroyed by save")
    }

    /// GPS coordinates are irreplaceable — you cannot re-derive where a photo
    /// was taken once the tag is gone.
    func testSavePreservesGPS() throws {
        let url = try makeCameraJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        guard let img = NSImage(contentsOf: url) else { throw XCTSkip("unreadable") }
        let doc = OpenImage(url: url, image: img)
        doc.stack.adjustments.contrast = 0.2
        XCTAssertNotNil(SaveService.write(doc: doc, to: url))

        let gps = dict(try properties(of: url), kCGImagePropertyGPSDictionary)
        XCTAssertFalse(gps.isEmpty, "the whole GPS block was destroyed by save")
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double {
            XCTAssertEqual(lat, 44.4268, accuracy: 0.001, "GPS latitude changed")
        }
    }
}
