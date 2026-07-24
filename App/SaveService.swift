// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import AppKit
import UniformTypeIdentifiers

enum SaveService {

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
        // Mode B never rewrites the image: the edits go into a sidecar and the
        // original bytes stay exactly as they were.
        if mode == .sidecar, url == doc.url {
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

        // What goes in the XMP depends on the mode, and the file records which
        // mode wrote it so reopening cannot misread it.
        var extraTags: [String: String] = [
            SavedState.modeProperty: mode.rawValue
        ]
        // The stack is written for provenance in every mode; only mode C marks
        // it as re-applicable, by shipping the original alongside it.
        if mode == .embeddedOriginal {
            guard let originalBytes = doc.pristineOriginalData() else {
                NSAlert.fail(t("Nu am putut citi imaginea originala pentru a o pastra in fisier."))
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
        // A stale sidecar next to a now-flattened file would re-apply the edits.
        if mode != .sidecar { SidecarStore.clear(for: url) }
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
