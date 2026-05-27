// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import AppKit
import UniformTypeIdentifiers

enum SaveService {

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
    static func write(doc: OpenImage, to url: URL) -> URL? {
        let rendered = ImageRenderer.render(
            original: doc.originalImage,
            sourceCI: doc.sourceCIImage,
            stack: doc.stack)
        guard let cg = rendered.cgImage(
            forProposedRect: nil, context: nil, hints: nil)
        else {
            NSAlert.fail("Nu am putut randa imaginea.").runModal()
            return nil
        }
        let uti = XMPStack.utiType(for: url)
        let ok = XMPStack.write(
            stack: doc.stack, image: cg, to: url, utiType: uti)
        if !ok {
            NSAlert.fail("Scrierea fisierului a esuat la \(url.lastPathComponent).")
                .runModal()
            return nil
        }
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
