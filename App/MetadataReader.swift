// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lightweight read-only view of an image file's metadata: file size +
/// format + dimensions + a handful of EXIF fields most users care about +
/// our own `p2m:editStack` if present.
public struct ImageMetadata {
    public var fileSizeBytes: Int64?
    public var format: String?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var colorModel: String?

    public var dateTakenISO: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var iso: Int?
    public var exposureTime: String?
    public var fNumber: Double?
    public var focalLengthMM: Double?

    /// If true, the file has a `p2m:editStack` tag from a previous save.
    public var hasPhoto2MacStack: Bool = false
    /// Raw JSON of the embedded edit stack (if any).
    public var photo2MacStackJSON: String?

    /// Read EXIF + XMP from the image file at `url`. Returns nil if the file
    /// can't be opened as an image.
    public static func read(from url: URL) -> ImageMetadata? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var meta = ImageMetadata()

        // File size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            meta.fileSizeBytes = size
        }

        // Format
        if let uti = CGImageSourceGetType(src) as String? {
            meta.format = uti
        }

        // Per-image properties dict
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
            meta.pixelWidth = props[kCGImagePropertyPixelWidth as String] as? Int
            meta.pixelHeight = props[kCGImagePropertyPixelHeight as String] as? Int
            meta.colorModel = props[kCGImagePropertyColorModel as String] as? String

            if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                meta.dateTakenISO = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
                meta.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
                if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double {
                    meta.exposureTime = formatShutter(t)
                }
                meta.fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double
                meta.focalLengthMM = exif[kCGImagePropertyExifFocalLength as String] as? Double
                meta.lens = exif[kCGImagePropertyExifLensModel as String] as? String
            }
            if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                meta.cameraMake = tiff[kCGImagePropertyTIFFMake as String] as? String
                meta.cameraModel = tiff[kCGImagePropertyTIFFModel as String] as? String
            }
        }

        // p2m:editStack via XMP
        if let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            let path = "\(XMPStack.prefix):\(XMPStack.propertyName)" as CFString
            if let tag = CGImageMetadataCopyTagWithPath(md, nil, path),
               let value = CGImageMetadataTagCopyValue(tag) {
                meta.hasPhoto2MacStack = true
                if let s = value as? String {
                    meta.photo2MacStackJSON = s
                } else if let s = value as? NSString {
                    meta.photo2MacStackJSON = s as String
                }
            }
        }

        return meta
    }

    private static func formatShutter(_ t: Double) -> String {
        if t >= 1.0 {
            return String(format: "%.1f s", t)
        }
        let denom = (1.0 / t).rounded()
        return "1/\(Int(denom)) s"
    }

    /// Human-readable file size.
    public var formattedFileSize: String? {
        guard let b = fileSizeBytes else { return nil }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: b)
    }

    public var formattedFormat: String? {
        guard let uti = format else { return nil }
        if let t = UTType(uti)?.preferredFilenameExtension { return t.uppercased() }
        return uti
    }
}
