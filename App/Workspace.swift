// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class OpenImage: ObservableObject, Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let originalImage: NSImage
    @Published var displayImage: NSImage
    @Published var stack: EditStack {
        didSet {
            if stack != oldValue {
                rerender()
            }
        }
    }

    init(url: URL, image: NSImage) {
        self.url = url
        self.originalImage = image
        self.displayImage = image
        self.stack = EditStack()
    }

    var displayName: String { url.lastPathComponent }

    private var pendingRender: DispatchWorkItem?
    private let renderQueue = DispatchQueue(label: "ro.cremenescu.Photo2Mac.render",
                                             qos: .userInitiated)

    /// Debounced render: cheap slider drag won't queue dozens of renders.
    func rerender() {
        pendingRender?.cancel()
        let stackSnapshot = stack
        let original = originalImage
        let work = DispatchWorkItem { [weak self] in
            let rendered = ImageRenderer.render(original: original, stack: stackSnapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                // Only apply if stack hasn't moved on while we were rendering.
                if self.stack == stackSnapshot {
                    self.displayImage = rendered
                }
            }
        }
        pendingRender = work
        renderQueue.asyncAfter(deadline: .now() + 0.02, execute: work)
    }

    static func == (lhs: OpenImage, rhs: OpenImage) -> Bool { lhs.id == rhs.id }
}

final class Workspace: ObservableObject {
    @Published var documents: [OpenImage] = []
    @Published var selectedID: UUID?

    var selected: OpenImage? {
        documents.first(where: { $0.id == selectedID })
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedTypes()
        if panel.runModal() == .OK {
            for url in panel.urls { open(url: url) }
        }
    }

    @discardableResult
    func open(url: URL) -> OpenImage? {
        if let existing = documents.first(where: { $0.url == url }) {
            selectedID = existing.id
            return existing
        }
        guard let img = NSImage(contentsOf: url) else {
            NSSound.beep()
            return nil
        }
        let doc = OpenImage(url: url, image: img)
        documents.append(doc)
        selectedID = doc.id
        RecentFiles.shared.add(url)
        return doc
    }

    func closeSelected() {
        guard let id = selectedID,
              let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        documents.remove(at: idx)
        if documents.isEmpty {
            selectedID = nil
        } else {
            let newIdx = min(idx, documents.count - 1)
            selectedID = documents[newIdx].id
        }
    }

    func close(_ doc: OpenImage) {
        guard let idx = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        let wasSelected = selectedID == doc.id
        documents.remove(at: idx)
        if wasSelected {
            if documents.isEmpty {
                selectedID = nil
            } else {
                selectedID = documents[min(idx, documents.count - 1)].id
            }
        }
    }

    private func supportedTypes() -> [UTType] {
        var types: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .webP]
        if let avif = UTType("public.avif") { types.append(avif) }
        return types
    }
}
