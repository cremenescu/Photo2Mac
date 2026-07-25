// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import AppKit
import UniformTypeIdentifiers

enum SaveService {

    /// Ceiling on the original we are willing to embed in mode C. Above roughly
    /// 64 MB of payload ImageIO writes a file it cannot read back while
    /// reporting success; this stays well clear of that cliff.
    static let maxEmbeddedOriginalBytes = 48 * 1_000_000

    /// Save back to the file the document was opened from (overwrite).
    /// macOS automatically captures a filesystem version via NSFileVersion
    /// so the user can recover the previous content from Finder if needed.
    @discardableResult
    static func saveInPlace(doc: OpenImage) -> URL? {
        // Best-effort version snapshot before overwrite.
        _ = try? NSFileVersion.addOfItem(at: doc.url, withContentsOf: doc.url)
        return write(doc: doc, to: doc.url)
    }

    /// Show NSSavePanel with sensible defaults, then render + write XMP.
    /// Returns the URL that was written, or nil if user cancelled / write failed.
    @discardableResult
    static func saveAs(doc: OpenImage) -> URL? {
        let panel = NSSavePanel()
        panel.title = t("Salveaza imaginea")
        panel.nameFieldLabel = t("Nume fisier:")
        // Default name: <original>-edited.<ext>, JPEG by default.
        let baseName = doc.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = baseName + "-edited.jpg"
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.directoryURL = doc.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let outURL = panel.url else { return nil }
        return write(doc: doc, to: outURL)
    }

    /// Render through the stack and write to `url` with XMP-embedded stack.
    /// On success, clears the autosave (file is the source of truth now).
    @discardableResult
    static func write(doc: OpenImage, to url: URL,
                      mode: SaveMode = AppSettings.shared.saveMode) -> URL? {
        // Capture the pristine bytes before anything can overwrite them. Doing
        // this lazily at embed time is too late: by then an earlier save may
        // already have replaced the file with the edited image.
        doc.pinOriginalDataIfPristine()

        // Mode B never rewrites the image: the edits go into a sidecar and the
        // original bytes stay exactly as they were.
        //
        // It is only meaningful while the file still IS the original. If an
        // earlier save baked pixels into it, a sidecar holding the full stack
        // would be applied on top of pixels that already contain it — the
        // double-application bug, re-entered through the back door of changing
        // the preference mid-session. In that case fall through and flatten:
        // the promise "never modify the original" is already void for this file.
        if mode == .sidecar, url == doc.url, !doc.fileHasBakedEdits {
            guard SidecarStore.write(stack: doc.stack, for: url) else {
                NSAlert.fail(t("Nu am putut scrie fisierul de editari alaturi de imagine."))
                    .runModal()
                return nil
            }
            AutosaveStore.shared.clear(for: doc.url)
            return url
        }

        guard let uti = XMPStack.utiType(for: url) else {
            NSAlert.fail(t("Photo2Mac nu poate scrie formatul %@. Foloseste Salveaza ca... si alege JPEG, PNG, HEIC sau TIFF.",
                            url.pathExtension.uppercased()))
                .runModal()
            return nil
        }
        let rendered = ImageRenderer.render(
            original: doc.originalImage,
            sourceCI: doc.sourceCIImage,
            stack: doc.stack)
        guard let cg = rendered.cgImage(
            forProposedRect: nil, context: nil, hints: nil)
        else {
            NSAlert.fail(t("Nu am putut randa imaginea.")).runModal()
            return nil
        }

        // We are writing real pixels here. In sidecar mode that only happens via
        // Save As (a different URL), and the result is a flattened file — record
        // it as such, not as a sidecar file that has no sidecar.
        let effectiveMode: SaveMode = (mode == .sidecar) ? .flattened : mode

        // The file records which mode wrote it so reopening cannot misread it.
        var extraTags: [String: String] = [
            SavedState.modeProperty: effectiveMode.rawValue
        ]
        // The stack is written for provenance in every mode; only mode C marks
        // it as re-applicable, by shipping the original alongside it.
        if effectiveMode == .embeddedOriginal {
            // No pristine copy means we would be embedding the edited image and
            // calling it the original. Refuse rather than lie about it.
            guard let originalBytes = doc.pristineOriginalData() else {
                NSAlert.fail(t("Nu am putut citi imaginea originala pentru a o pastra in fisier."))
                    .runModal()
                return nil
            }
            // Above roughly 64 MB of payload ImageIO reports a successful write
            // and produces a file it cannot read back: every p2m tag returns
            // nil and even NSImage refuses it. Saving in place would replace the
            // user's photo with that. Measured cliff between 64 MB and 131 MB.
            guard originalBytes.count <= maxEmbeddedOriginalBytes else {
                NSAlert.fail(t("Imaginea originala e prea mare (%d MB) ca sa incapa in fisier. Alege alt mod de salvare in Preferinte.",
                                originalBytes.count / 1_000_000))
                    .runModal()
                return nil
            }
            extraTags[SavedState.originalProperty] =
                originalBytes.base64EncodedString()
            extraTags[SavedState.originalTypeProperty] =
                (XMPStack.utiType(for: doc.url) as String?) ?? ""
        }

        let ok = XMPStack.write(
            stack: doc.stack, image: cg, to: url, utiType: uti,
            sourceURL: doc.url, extraTags: extraTags)
        if !ok {
            NSAlert.fail(t("Scrierea fisierului a esuat la %@.", url.lastPathComponent))
                .runModal()
            return nil
        }
        // Verify the write actually round-tripped before declaring success: a
        // file whose marker did not survive would be misread on reopen.
        if XMPStack.readP2MString(SavedState.modeProperty, from: url)
            != effectiveMode.rawValue {
            NSAlert.fail(t("Fisierul a fost scris, dar Photo2Mac nu poate reciti informatiile de editare din el."))
                .runModal()
        }
        if url == doc.url { doc.markFileFlattened() }
        // A stale sidecar next to a now-flattened file would re-apply the edits.
        SidecarStore.clear(for: url)
        AutosaveStore.shared.clear(for: doc.url)
        return url
    }
}

private extension NSAlert {
    static func fail(_ message: String) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Eroare la salvare"
        a.informativeText = message
        a.addButton(withTitle: "OK")
        return a
    }
}
