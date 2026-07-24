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
    ///
    /// `sourceURL` is the file the pixels came from. Its EXIF / GPS / IPTC and
    /// any pre-existing XMP are carried across, because a photo editor that
    /// silently drops the camera, lens, capture date and GPS on every save is
    /// destroying data the user cannot get back.
    ///
    /// `extraTags` lets callers add p2m properties (save mode, embedded
    /// original) without this function knowing about them.
    ///
    /// Returns true on success.
    @discardableResult
    static func write(stack: EditStack,
                      image: CGImage,
                      to url: URL,
                      utiType: CFString,
                      sourceURL: URL? = nil,
                      extraTags: [String: String] = [:],
                      jpegQuality: CGFloat = 0.92) -> Bool {
        guard let data = try? JSONEncoder().encode(stack),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }

        // Start from the source's own metadata so foreign XMP (Lightroom,
        // Capture One, IPTC rights) survives, then layer ours on top.
        let md = copyOfSourceMetadata(sourceURL) ?? CGImageMetadataCreateMutable()

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
        for (name, value) in extraTags {
            setP2MTag(md, name: name, value: value)
        }

        // Standard tags that make Photo2Mac edits visible to ordinary viewers.
        writeStandardDescription(md: md, stack: stack)

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, utiType, 1, nil
        ) else { return false }
        var options = sourceProperties(sourceURL)
        options[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        CGImageDestinationAddImageAndMetadata(dest, image, md, options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// A mutable copy of the source file's XMP, or nil when there is none.
    private static func copyOfSourceMetadata(_ sourceURL: URL?) -> CGMutableImageMetadata? {
        guard let sourceURL,
              let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let existing = CGImageSourceCopyMetadataAtIndex(src, 0, nil)
        else { return nil }
        return CGImageMetadataCreateMutableCopy(existing)
    }

    /// The source file's properties (EXIF / GPS / TIFF / IPTC), cleaned of the
    /// entries that describe the OLD pixels. Geometry is baked into the image
    /// we are about to write, so:
    /// - orientation is reset to 1 (the pixels are already upright), and
    /// - the stored pixel dimensions are dropped so ImageIO writes the real ones.
    private static func sourceProperties(_ sourceURL: URL?) -> [CFString: Any] {
        guard let sourceURL,
              let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                as? [CFString: Any]
        else { return [:] }

        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        props[kCGImagePropertyOrientation] = 1

        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            props[kCGImagePropertyExifDictionary] = exif
        }
        return props
    }

    @discardableResult
    private static func setP2MTag(_ md: CGMutableImageMetadata,
                                    name: String, value: String) -> Bool {
        guard let tag = CGImageMetadataTagCreate(
            namespace as CFString, prefix as CFString, name as CFString,
            .string, value as CFTypeRef
        ) else { return false }
        return CGImageMetadataSetTagWithPath(
            md, nil, "\(prefix):\(name)" as CFString, tag)
    }

    /// Read a p2m string property, or nil.
    static func readP2MString(_ name: String, from url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let tag = CGImageMetadataCopyTagWithPath(
                md, nil, "\(prefix):\(name)" as CFString),
              let value = CGImageMetadataTagCopyValue(tag)
        else { return nil }
        if let s = value as? String { return s }
        if let s = value as? NSString { return s as String }
        return nil
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

    /// Destination UTI for a file URL, or nil when we cannot write that format.
    ///
    /// This used to fall through to JPEG for anything unrecognised, which meant
    /// saving in place over a `.webp` wrote JPEG bytes under the `.webp`
    /// extension — silently, because CGImageDestination happily accepts the
    /// mismatch. Returning nil lets callers refuse and offer Save As instead.
    static func utiType(for url: URL) -> CFString? {
        let ext = url.pathExtension.lowercased()
        let candidate: String?
        switch ext {
        case "jpg", "jpeg": candidate = UTType.jpeg.identifier
        case "png":         candidate = UTType.png.identifier
        case "heic":        candidate = UTType.heic.identifier
        case "heif":        candidate = UTType.heif.identifier
        case "tif", "tiff": candidate = UTType.tiff.identifier
        case "avif":        candidate = "public.avif"
        case "webp":        candidate = "org.webmproject.webp"
        default:            candidate = nil
        }
        guard let candidate else { return nil }
        // Ask the system rather than assuming: macOS can READ several formats
        // it cannot WRITE (WebP is the current example).
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(candidate) ? (candidate as CFString) : nil
    }
}
