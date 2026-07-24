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

        // Read EVERYTHING from the source before opening the destination: when
        // saving in place the two are the same file, and reading it after
        // ImageIO has taken it for writing is asking for trouble.
        //
        // The metadata object is built FRESH and the source's foreign XMP is
        // copied onto it tag by tag. Handing ImageIO a
        // CGImageMetadataCreateMutableCopy of the source instead looks tidier
        // and works the first time, but on the SECOND write of the same file it
        // silently drops some of the custom properties while keeping others —
        // measured: p2m:saveMode and p2m:editStack vanished while
        // p2m:originalImage and p2m:originalType survived, even though all four
        // were present in the object handed to CGImageDestination. That is what
        // made a file lose its edit stack on the second Cmd+S.
        let md = CGImageMetadataCreateMutable()
        copyForeignXMP(from: sourceURL, into: md)
        var options = sourceProperties(sourceURL)
        options[kCGImageDestinationLossyCompressionQuality] = jpegQuality

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
        CGImageDestinationAddImageAndMetadata(dest, image, md, options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Namespaces we do NOT copy from the source:
    /// - `p2m` is ours and is rewritten from scratch on every save;
    /// - `exif` / `tiff` are re-derived by ImageIO from the destination
    ///   properties, which carry the real EXIF/TIFF segments;
    /// - `iio` is ImageIO's own bookkeeping.
    private static let nonPortablePrefixes: Set<String> = [prefix, "exif", "tiff", "iio"]

    /// Copy the source's third-party XMP (dc, xmpRights, photoshop, Lightroom,
    /// Capture One, ...) onto a fresh metadata object, so editing a photo in
    /// Photo2Mac does not throw away metadata another tool wrote.
    private static func copyForeignXMP(from sourceURL: URL?,
                                        into md: CGMutableImageMetadata) {
        guard let sourceURL,
              let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let existing = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let tags = CGImageMetadataCopyTags(existing) as? [CGImageMetadataTag]
        else { return }

        for tag in tags {
            guard let pfx = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  let ns = CGImageMetadataTagCopyNamespace(tag) as String?,
                  !nonPortablePrefixes.contains(pfx)
            else { continue }
            CGImageMetadataRegisterNamespaceForPrefix(
                md, ns as CFString, pfx as CFString, nil)
            CGImageMetadataSetTagWithPath(
                md, nil, "\(pfx):\(name)" as CFString, tag)
        }
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

        // Do NOT forward IPTC. ImageIO keeps IPTC and XMP in sync, so handing it
        // an {IPTC} dictionary alongside a CGImageMetadata makes it REBUILD the
        // XMP packet from the properties — silently dropping every namespace it
        // does not know, p2m included. The symptom is brutal and easy to miss:
        // the FIRST save of a file is fine, and the second one loses the edit
        // stack and the save-mode marker, because the first save is what created
        // the IPTC block (from dc:description). The IPTC content we care about
        // is already in `md`, which is a copy of the source's own XMP.
        props.removeValue(forKey: kCGImagePropertyIPTCDictionary)
        props.removeValue(forKey: "{Photoshop}" as CFString)

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
