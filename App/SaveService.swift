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
        guard let written = write(doc: doc, to: doc.url) else { return nil }
        doc.markSaved()
        return written.url
    }

    /// Show NSSavePanel with sensible defaults, then render + write XMP. The
    /// document then belongs to the new file, like Save As anywhere else on
    /// the Mac; use Export for a copy that leaves the document where it is.
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
        return saveAs(doc: doc, to: outURL)
    }

    /// Save As without the panel (tests, and the panel path above).
    @discardableResult
    static func saveAs(doc: OpenImage, to outURL: URL,
                       mode: SaveMode = AppSettings.shared.saveMode) -> URL? {
        let sameFile = outURL.standardizedFileURL == doc.url.standardizedFileURL
        guard let written = write(doc: doc, to: outURL, mode: mode) else { return nil }
        if !sameFile {
            doc.retarget(to: outURL, writtenAs: written.mode)
            RecentFiles.shared.add(outURL)
        }
        doc.markSaved()
        return written.url
    }

    struct Written {
        let url: URL
        /// The mode the file was actually written in (Save As in sidecar mode
        /// writes a flattened file).
        let mode: SaveMode
    }

    /// Render through the stack and write to `url` with XMP-embedded stack.
    ///
    /// `stack` overrides the document's (Export adds its own scaling);
    /// `isExport` = a copy that leaves the document and its file untouched.
    static func write(doc: OpenImage, to url: URL,
                      mode: SaveMode = AppSettings.shared.saveMode,
                      stack: EditStack? = nil,
                      quality: CGFloat = 0.92,
                      isExport: Bool = false) -> Written? {
        let stack = stack ?? doc.stack
        let inPlace = url.standardizedFileURL == doc.url.standardizedFileURL

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
        if mode == .sidecar, inPlace, !isExport, !doc.fileHasBakedEdits {
            guard SidecarStore.write(stack: stack, for: url) else {
                NSAlert.fail(t("Nu am putut scrie fisierul de editari alaturi de imagine."))
                    .runModal()
                return nil
            }
            return Written(url: url, mode: .sidecar)
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
            stack: stack)
        guard let cg = rendered.cgImage(
            forProposedRect: nil, context: nil, hints: nil)
        else {
            NSAlert.fail(t("Nu am putut randa imaginea.")).runModal()
            return nil
        }

        // We are writing real pixels here. In sidecar mode that only happens via
        // Save As (a different URL), and the result is a flattened file — record
        // it as such, not as a sidecar file that has no sidecar. An export is
        // always a plain flattened copy.
        let effectiveMode: SaveMode = (mode == .sidecar || isExport) ? .flattened : mode

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
            stack: stack, image: cg, to: url, utiType: uti,
            sourceURL: doc.url, extraTags: extraTags, jpegQuality: quality)
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
        if inPlace {
            doc.markFileFlattened()
            // See OpenImage.disableAutosave: a stack autosaved from here on
            // would be relative to an original this file no longer carries.
            if effectiveMode == .flattened { doc.disableAutosave() }
        }
        // A stale sidecar next to a now-flattened file would re-apply the edits.
        SidecarStore.clear(for: url)
        return Written(url: url, mode: effectiveMode)
    }

    // MARK: - Export

    /// A flattened copy in the format, quality and size chosen in the panel.
    /// The document keeps its file, its edits and its unsaved state.
    @discardableResult
    static func export(doc: OpenImage) -> URL? {
        let panel = NSSavePanel()
        panel.title = t("Exporta imaginea")
        panel.nameFieldLabel = t("Nume fisier:")
        panel.prompt = t("Exporta")
        let accessory = ExportAccessory(baseName: doc.url.deletingPathExtension().lastPathComponent,
                                        panel: panel)
        panel.accessoryView = accessory.accessoryView
        panel.isExtensionHidden = false
        panel.directoryURL = doc.url.deletingLastPathComponent()
        accessory.applyFormat()
        guard panel.runModal() == .OK, let outURL = panel.url else { return nil }
        if outURL.standardizedFileURL == doc.url.standardizedFileURL {
            NSAlert.fail(t("Exportul nu poate inlocui fisierul deschis. Foloseste Salveaza (Cmd+S)."))
                .runModal()
            return nil
        }
        let stack = exportStack(for: doc, longEdge: accessory.longEdge)
        return write(doc: doc, to: outURL, mode: .flattened, stack: stack,
                     quality: accessory.quality, isExport: true)?.url
    }

    /// The document's stack, scaled down so the long side is at most
    /// `longEdge` pixels. Never scales up.
    static func exportStack(for doc: OpenImage, longEdge: Int?) -> EditStack {
        var stack = doc.stack
        guard let longEdge, longEdge > 0 else { return stack }
        let out = EditGeometry.outputSize(for: stack, sourceSize: doc.originalImage.size)
        let long = max(out.width, out.height)
        guard long > CGFloat(longEdge) else { return stack }
        let k = CGFloat(longEdge) / long
        stack.resize = ResizeSpec(width: max(1, Int((out.width * k).rounded())),
                                  height: max(1, Int((out.height * k).rounded())),
                                  keepsAspect: false)
        return stack
    }
}

/// Format, quality and size controls under the export panel.
private final class ExportAccessory: NSObject {
    enum Format: Int, CaseIterable {
        case jpeg, png, heic, tiff
        var type: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .heic: return .heic
            case .tiff: return .tiff
            }
        }
        var label: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png: return "PNG"
            case .heic: return "HEIC"
            case .tiff: return "TIFF"
            }
        }
        var isLossy: Bool { self == .jpeg || self == .heic }
    }

    let view: NSView
    private weak var panel: NSSavePanel?
    private let baseName: String
    private let formatPopup = NSPopUpButton()
    private let qualitySlider = NSSlider(value: 0.9, minValue: 0.3, maxValue: 1.0,
                                         target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "")
    private let sizeCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sizeField = NSTextField(string: "2048")

    private static let lastFormatKey = "exportFormat"
    private static let lastQualityKey = "exportQuality"

    init(baseName: String, panel: NSSavePanel) {
        self.baseName = baseName
        self.panel = panel
        let defaults = UserDefaults.standard
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        view = grid
        super.init()

        for f in Format.allCases { formatPopup.addItem(withTitle: f.label) }
        formatPopup.selectItem(at: defaults.object(forKey: Self.lastFormatKey) as? Int ?? 0)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        qualitySlider.doubleValue = defaults.object(forKey: Self.lastQualityKey) as? Double ?? 0.9
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        sizeCheck.title = t("Latura lunga maxima")
        sizeCheck.target = self
        sizeCheck.action = #selector(sizeToggled)
        let fmt = NumberFormatter()
        fmt.allowsFloats = false
        fmt.minimum = 16
        fmt.maximum = 100_000
        sizeField.formatter = fmt
        sizeField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        sizeField.isEnabled = false

        grid.addRow(with: [NSTextField(labelWithString: t("Format:")), formatPopup, NSGridCell.emptyContentView])
        grid.addRow(with: [NSTextField(labelWithString: t("Calitate:")), qualitySlider, qualityLabel])
        grid.addRow(with: [NSGridCell.emptyContentView, sizeCheck,
                           NSStackView(views: [sizeField, NSTextField(labelWithString: "px")])])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 420, height: 110)
        viewHolder = container
        qualityChanged()
    }

    /// NSGridView sized by Auto Layout inside a plain container, which is
    /// what the panel gets.
    private var viewHolder: NSView?
    var accessoryView: NSView { viewHolder ?? view }

    private var format: Format { Format(rawValue: formatPopup.indexOfSelectedItem) ?? .jpeg }

    var quality: CGFloat { format.isLossy ? CGFloat(qualitySlider.doubleValue) : 1.0 }

    var longEdge: Int? {
        guard sizeCheck.state == .on else { return nil }
        let v = sizeField.integerValue
        return v > 0 ? v : nil
    }

    func applyFormat() {
        panel?.allowedContentTypes = [format.type]
        panel?.nameFieldStringValue = baseName + "." + (format.type.preferredFilenameExtension ?? "jpg")
        qualitySlider.isEnabled = format.isLossy
        qualityLabel.textColor = format.isLossy ? .labelColor : .disabledControlTextColor
    }

    @objc private func formatChanged() {
        UserDefaults.standard.set(formatPopup.indexOfSelectedItem, forKey: Self.lastFormatKey)
        // Keep whatever name the user typed, change only the extension.
        if let current = panel?.nameFieldStringValue, !current.isEmpty {
            let stem = (current as NSString).deletingPathExtension
            panel?.allowedContentTypes = [format.type]
            panel?.nameFieldStringValue = stem + "." + (format.type.preferredFilenameExtension ?? "jpg")
            qualitySlider.isEnabled = format.isLossy
            qualityLabel.textColor = format.isLossy ? .labelColor : .disabledControlTextColor
        } else {
            applyFormat()
        }
    }

    @objc private func qualityChanged() {
        UserDefaults.standard.set(qualitySlider.doubleValue, forKey: Self.lastQualityKey)
        qualityLabel.stringValue = "\(Int((qualitySlider.doubleValue * 100).rounded()))%"
    }

    @objc private func sizeToggled() {
        sizeField.isEnabled = sizeCheck.state == .on
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
