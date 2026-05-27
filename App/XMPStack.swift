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

    // Standard XMP namespaces used by all the well-known viewers — adding
    // these makes Photo2Mac's edits visible to Preview, Metapho, Bridge, etc.
    static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    static let xmpPrefix = "xmp"
    static let tiffNS = "http://ns.adobe.com/tiff/1.0/"
    static let tiffPrefix = "tiff"
    static let dcNS = "http://purl.org/dc/elements/1.1/"
    static let dcPrefix = "dc"

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

        // p2m: our custom edit-stack JSON (for re-edit roundtrip).
        CGImageMetadataRegisterNamespaceForPrefix(
            md, namespace as CFString, prefix as CFString, nil)
        guard let stackTag = CGImageMetadataTagCreate(
            namespace as CFString,
            prefix as CFString,
            propertyName as CFString,
            .string,
            json as CFTypeRef
        ) else { return false }
        guard CGImageMetadataSetTagWithPath(md, nil, path, stackTag) else {
            return false
        }

        // Standard tags that make Photo2Mac edits visible to ordinary viewers.
        writeStandardDescription(md: md, stack: stack)

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, utiType, 1, nil
        ) else { return false }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ]
        CGImageDestinationAddImageAndMetadata(dest, image, md, options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Register xmp/tiff/dc tags so generic viewers (Preview, Metapho, Bridge)
    /// can see that the file was processed by Photo2Mac and which edits were
    /// applied, in plain text.
    private static func writeStandardDescription(md: CGMutableImageMetadata,
                                                  stack: EditStack) {
        CGImageMetadataRegisterNamespaceForPrefix(
            md, xmpNS as CFString, xmpPrefix as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(
            md, tiffNS as CFString, tiffPrefix as CFString, nil)
        CGImageMetadataRegisterNamespaceForPrefix(
            md, dcNS as CFString, dcPrefix as CFString, nil)

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "?"
        let creatorTool = "Photo2Mac \(appVersion)"
        let description = humanDescription(of: stack, creator: creatorTool)

        setStringTag(md, ns: xmpNS, prefix: xmpPrefix,
                     name: "CreatorTool", value: creatorTool)
        setStringTag(md, ns: tiffNS, prefix: tiffPrefix,
                     name: "ImageDescription", value: description)
        setStringTag(md, ns: dcNS, prefix: dcPrefix,
                     name: "description", value: description)
    }

    @discardableResult
    private static func setStringTag(_ md: CGMutableImageMetadata,
                                       ns: String,
                                       prefix: String,
                                       name: String,
                                       value: String) -> Bool {
        guard let tag = CGImageMetadataTagCreate(
            ns as CFString,
            prefix as CFString,
            name as CFString,
            .string,
            value as CFTypeRef
        ) else { return false }
        let path = "\(prefix):\(name)" as CFString
        return CGImageMetadataSetTagWithPath(md, nil, path, tag)
    }

    /// One-line human-readable summary of the edits applied. Always English —
    /// this lives in the file metadata and is read by tools / people anywhere,
    /// so we keep it locale-independent regardless of the app's UI language.
    private static func humanDescription(of s: EditStack, creator: String) -> String {
        if s.isNeutral {
            return "\(creator) — no edits"
        }
        var parts: [String] = []
        if abs(s.rotateDegrees) > 0.0001 {
            parts.append(String(format: "rotate %.2f°", s.rotateDegrees))
        }
        if s.flipHorizontal { parts.append("flip horizontal") }
        if s.flipVertical { parts.append("flip vertical") }
        if let c = s.crop {
            parts.append(String(format: "crop %d%%×%d%% at (%d%%, %d%%)",
                                 Int(c.width * 100), Int(c.height * 100),
                                 Int(c.x * 100), Int(c.y * 100)))
        }
        let adj = s.adjustments
        if adj.brightness != 0 {
            parts.append(String(format: "brightness %+d", Int((adj.brightness * 100).rounded())))
        }
        if adj.contrast != 0 {
            parts.append(String(format: "contrast %+d", Int((adj.contrast * 100).rounded())))
        }
        if adj.saturation != 0 {
            parts.append(String(format: "saturation %+d", Int((adj.saturation * 100).rounded())))
        }
        if adj.exposure != 0 {
            parts.append(String(format: "exposure %+.2f EV", adj.exposure))
        }
        return "\(creator) — " + parts.joined(separator: ", ")
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
