// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import AppKit
import ImageIO
import CryptoKit

/// What Cmd+S does to the file on disk.
///
/// The three modes are genuinely different promises to the user, so the choice
/// is a setting rather than a hardcoded policy.
///
/// IMPORTANT — the setting decides how a file is WRITTEN; the file itself
/// decides how it is READ (see `SavedState.resolve`). Without that split,
/// saving in one mode and then switching the preference would make Photo2Mac
/// misinterpret its own files.
enum SaveMode: String, CaseIterable, Identifiable, Codable {
    /// A — the saved file becomes the edited image. The recipe is recorded in
    /// XMP as provenance only and is never re-applied. What Preview does.
    case flattened
    /// B — the original file is never modified. The recipe lives in a `.p2m`
    /// sidecar next to it. Other apps see the untouched original.
    case sidecar
    /// C — the saved file is the edited image and carries the original bytes
    /// inside its XMP, so Photo2Mac can always get back to the untouched
    /// source. Costs roughly the size of the original again.
    case embeddedOriginal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flattened:        return t("Salveaza ce vezi")
        case .sidecar:          return t("Nu modifica originalul")
        case .embeddedOriginal: return t("Pastreaza originalul in fisier")
        }
    }

    var explanation: String {
        switch self {
        case .flattened:
            return t("Fisierul devine imaginea editata, ca in Preview. Alte aplicatii vad editarile. Poti recupera versiunea dinainte din Fisier > Revino la.")
        case .sidecar:
            return t("Fisierul original ramane neatins; editarile stau intr-un fisier .p2m alaturi. Reversibil oricand, dar alte aplicatii vad originalul needitat — foloseste Salveaza ca... ca sa obtii imaginea editata.")
        case .embeddedOriginal:
            return t("Fisierul devine imaginea editata si poarta originalul in interior, deci poti reveni oricand. Alte aplicatii vad editarile. Fisierul creste cu marimea originalului.")
        }
    }
}

/// Reads/writes the `.p2m` sidecar used by `SaveMode.sidecar`.
enum SidecarStore {

    struct Payload: Codable {
        var version: Int = 1
        var stack: EditStack
        /// Size and mtime of the image the stack was captured against, so a
        /// sidecar left behind next to a *different* file is not applied.
        var sourceSize: Int?
        var sourceModified: Date?
    }

    static func url(for imageURL: URL) -> URL {
        imageURL.appendingPathExtension("p2m")
    }

    static func exists(for imageURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(for: imageURL).path)
    }

    @discardableResult
    static func write(stack: EditStack, for imageURL: URL) -> Bool {
        let attrs = try? FileManager.default
            .attributesOfItem(atPath: imageURL.path)
        let payload = Payload(
            stack: stack,
            sourceSize: attrs?[.size] as? Int,
            sourceModified: attrs?[.modificationDate] as? Date)
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        do {
            try data.write(to: url(for: imageURL), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The stack for `imageURL`, or nil when there is no sidecar or it belongs
    /// to a different version of the file.
    static func read(for imageURL: URL) -> EditStack? {
        guard let data = try? Data(contentsOf: url(for: imageURL)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }

        // Identity check: if the image changed underneath the sidecar, the
        // stored crop/rotation no longer describes these pixels.
        if let recordedSize = payload.sourceSize,
           let attrs = try? FileManager.default
            .attributesOfItem(atPath: imageURL.path),
           let currentSize = attrs[.size] as? Int,
           recordedSize != currentSize {
            return nil
        }
        return payload.stack
    }

    static func clear(for imageURL: URL) {
        try? FileManager.default.removeItem(at: url(for: imageURL))
    }
}

/// How a file on disk should be interpreted when it is opened.
///
/// Resolved from the FILE, never from the current preference.
enum SavedState {

    /// The pixels are final; `recordedStack` is history to display, not to apply.
    case flattened(recordedStack: EditStack?)
    /// The pixels are the untouched original; apply `stack` to get the edit.
    case editable(stack: EditStack, originalData: Data?)
    /// Nothing of ours in this file.
    case none

    /// An embedded "original" is only trustworthy if it is actually an image.
    /// Valid base64 is not enough: a mode-C JPEG stores the payload as an Adobe
    /// ExtendedXMP chain, and any tool that rewrites XMP without full
    /// ExtendedXMP support drops trailing chunks — base64 is conventionally
    /// wrapped at multiples of 4, so the truncation stays decodable and would
    /// otherwise be adopted as "the untouched original" and written over the
    /// photo on the next save.
    ///
    /// Files written since v0.3.0 carry a SHA-256 of the original, which
    /// settles it cheaply and exactly. This is the fallback for files without
    /// one, and it has to decode the pixels: ImageIO reports a truncated PNG
    /// as complete and even hands out a CGImage for it — only reading the
    /// pixels fails.
    static func isDecodableImage(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(src) != nil,
              CGImageSourceGetCount(src) > 0,
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let pixels = image.dataProvider?.data,
              CFDataGetLength(pixels) > 0
        else { return false }
        return true
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `data` is the original the file says it embedded.
    static func isTrustworthyOriginal(_ data: Data, recordedHash: String?) -> Bool {
        if let recordedHash { return sha256Hex(data) == recordedHash }
        return isDecodableImage(data)
    }

    /// Property names used in XMP.
    static let modeProperty = "saveMode"
    static let originalProperty = "originalImage"
    static let originalTypeProperty = "originalType"
    static let originalHashProperty = "originalSHA256"

    static func resolve(for url: URL) -> SavedState {
        let record = XMPStack.readRecord(from: url)
        let recorded = record.stack
        let mode = record.strings[modeProperty]

        // 1. The file's own marker is consulted FIRST. A sidecar sitting next
        //    to a file that was written with baked pixels is stale — trusting
        //    it would apply a stack the pixels already contain.
        if mode == SaveMode.embeddedOriginal.rawValue,
           let b64 = record.strings[originalProperty],
           let data = Data(base64Encoded: b64),
           isTrustworthyOriginal(data, recordedHash: record.strings[originalHashProperty]),
           let stack = recorded {
            return .editable(stack: stack, originalData: data)
        }
        if mode != nil {
            // Marked as written by us with baked pixels (or an embedded
            // original we could not decode — in which case the pixels are still
            // final, so treating it as flattened is the safe reading).
            return .flattened(recordedStack: recorded)
        }

        // 2. No marker: a sidecar means the pixels are the untouched original.
        if let stack = SidecarStore.read(for: url) {
            return .editable(stack: stack, originalData: nil)
        }

        // 3. Legacy: files written by v0.1.0 – v0.2.1 carry an edit stack with
        //    NO mode marker, and their pixels are already baked. Treating them
        //    as editable is exactly the double-application bug, so they must be
        //    read as flattened.
        if recorded != nil {
            return .flattened(recordedStack: recorded)
        }

        return .none
    }
}
