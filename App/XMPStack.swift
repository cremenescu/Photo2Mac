// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Serialize / deserialize the EditStack to an image file's XMP metadata.
/// Saved files thus carry the recipe; reopening them in Photo2Mac restores
/// the editable stack. Other apps still see the rendered pixels.
enum XMPStack {

    /// Our custom XMP namespace. Choose something that's unlikely to collide
    /// with established schemas like dc:, xmp:, crs: (Camera Raw), etc.
    static let namespace = "http://ns.photo2mac.cremenescu.ro/1.0/"
    static let prefix = "p2m"
    static let propertyName = "editStack"
    static var path: CFString { "\(prefix):\(propertyName)" as CFString }

    /// Read the EditStack from XMP if present, else nil.
    static func read(from url: URL) -> EditStack? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let tag = CGImageMetadataCopyTagWithPath(md, nil, path),
              let value = CGImageMetadataTagCopyValue(tag) else {
            return nil
        }
        // Value is typed as CFString -> NSString.
        let str: String?
        if let s = value as? String {
            str = s
        } else if let s = value as? NSString {
            str = s as String
        } else {
            str = nil
        }
        guard let json = str, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EditStack.self, from: data)
    }

    /// Write `image` (rendered pixels) + EditStack JSON in XMP to `url`,
    /// using `utiType` as the destination format (JPEG/PNG/HEIC/TIFF).
    /// Returns true on success.
    @discardableResult
    static func write(stack: EditStack,
                      image: CGImage,
                      to url: URL,
                      utiType: CFString,
                      jpegQuality: CGFloat = 0.92) -> Bool {
        guard let data = try? JSONEncoder().encode(stack),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        let md = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(
            md, namespace as CFString, prefix as CFString, nil)
        guard let tag = CGImageMetadataTagCreate(
            namespace as CFString,
            prefix as CFString,
            propertyName as CFString,
            .string,
            json as CFTypeRef
        ) else { return false }
        guard CGImageMetadataSetTagWithPath(md, nil, path, tag) else {
            return false
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, utiType, 1, nil
        ) else { return false }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImageAndMetadata(dest, image, md, options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Best-effort UTI for a file URL based on extension.
    static func utiType(for url: URL) -> CFString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return UTType.jpeg.identifier as CFString
        case "png":         return UTType.png.identifier as CFString
        case "heic":        return UTType.heic.identifier as CFString
        case "heif":        return UTType.heif.identifier as CFString
        case "tif", "tiff": return UTType.tiff.identifier as CFString
        default:            return UTType.jpeg.identifier as CFString
        }
    }
}
