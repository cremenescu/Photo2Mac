// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class OpenImage: ObservableObject, Identifiable, Equatable {
    let id = UUID()
    let url: URL
    @Published var image: NSImage
    @Published var stack = EditStack()

    init(url: URL, image: NSImage) {
        self.url = url
        self.image = image
    }

    var displayName: String { url.lastPathComponent }

    static func == (lhs: OpenImage, rhs: OpenImage) -> Bool { lhs.id == rhs.id }
}

struct EditStack: Codable, Equatable {
    var operations: [EditOperation] = []
}

enum EditOperation: Codable, Equatable {
    case crop(x: Double, y: Double, w: Double, h: Double)
    case rotate(degrees: Int)
    case flipHorizontal
    case flipVertical
    case adjustments(brightness: Double, contrast: Double, saturation: Double, exposure: Double)
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
