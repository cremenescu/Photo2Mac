// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

final class OpenImage: ObservableObject, Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let originalImage: NSImage
    let sourceCIImage: CIImage?
    @Published var displayImage: NSImage
    @Published var stack: EditStack {
        didSet {
            if stack != oldValue {
                rerender()
                scheduleAutosave()
            }
        }
    }
    @Published var history = UndoHistory()

    /// Bytes of the untouched original, when we have them. For a file that was
    /// saved in `.embeddedOriginal` mode this is the copy extracted from its
    /// XMP; otherwise it is the file as it was when opened. Nil once the file
    /// has been flattened and no original survives anywhere.
    private(set) var originalFileData: Data?

    /// Edits that are already baked into the pixels of a flattened file. Shown
    /// as provenance in the metadata inspector; never re-applied.
    @Published var recordedHistory: EditStack?

    /// Whether the bytes currently on disk at `url` are still the untouched
    /// original for this document.
    ///
    /// This is the fact every save decision hinges on, and it is NOT the same
    /// as the save-mode preference. Once a save has baked pixels into the file,
    /// the file and this document have diverged: the document still holds the
    /// pristine `originalImage` plus a live `stack`, while the file already
    /// contains both combined. A later save that assumes the file is pristine
    /// applies the stack a second time — which is how switching the preference
    /// mid-session used to shrink an image 64 -> 32 -> 16 -> 8 px.
    private(set) var fileHasBakedEdits: Bool = false

    /// Record that the file at `url` now contains rendered pixels.
    func markFileFlattened() { fileHasBakedEdits = true }

    /// Capture the pristine bytes before the first write destroys them. Safe to
    /// call repeatedly; only the first pristine copy is kept.
    func pinOriginalDataIfPristine() {
        guard originalFileData == nil, !fileHasBakedEdits else { return }
        originalFileData = try? Data(contentsOf: url)
    }

    init(url: URL, image: NSImage, originalFileData: Data? = nil) {
        self.url = url
        self.originalImage = image
        self.displayImage = image
        self.stack = EditStack()
        self.originalFileData = originalFileData
        // Convert source to CIImage once. Subsequent renders skip the
        // costly NSImage->CGImage->CIImage round-trip.
        self.sourceCIImage = ImageRenderer.makeCIImage(from: image)
    }

    /// The original bytes to embed when saving in `.embeddedOriginal` mode, or
    /// nil when no pristine copy exists any more.
    ///
    /// Never falls back to reading `url` once the file has been flattened: that
    /// would hand back the EDITED image as "the original", so the user's
    /// recovery would return an already-cropped photo.
    func pristineOriginalData() -> Data? {
        if let originalFileData { return originalFileData }
        guard !fileHasBakedEdits else { return nil }
        return try? Data(contentsOf: url)
    }

    var displayName: String { url.lastPathComponent }

    private var pendingRender: DispatchWorkItem?
    private let renderQueue = DispatchQueue(label: "ro.cremenescu.Photo2Mac.render",
                                             qos: .userInteractive)
    private var pendingAutosave: DispatchWorkItem?
    private let autosaveQueue = DispatchQueue(label: "ro.cremenescu.Photo2Mac.autosave",
                                                qos: .background)

    private func scheduleAutosave() {
        pendingAutosave?.cancel()
        let snap = stack
        let url = self.url
        let work = DispatchWorkItem {
            AutosaveStore.shared.save(snap, for: url)
        }
        pendingAutosave = work
        autosaveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func clearAutosave() {
        pendingAutosave?.cancel()
        AutosaveStore.shared.clear(for: url)
    }

    /// Write the current stack to disk right now, synchronously, bypassing
    /// the 500ms debounce. Used on app quit so the last edit isn't lost
    /// when closing the window terminates the app.
    func flushAutosaveNow() {
        pendingAutosave?.cancel()
        AutosaveStore.shared.save(stack, for: url)
    }


    /// Render off the main thread; cancels in-flight on next tick.
    func rerender() {
        pendingRender?.cancel()
        let stackSnapshot = stack
        let original = originalImage
        let ci = sourceCIImage
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            // Drop stale frames: when a gesture (trackpad rotate, accelerating
            // stepper arrows, slider drag) fires faster than we can render, the
            // serial queue would otherwise render EVERY intermediate angle and
            // fall behind. Each rerender() cancels the previous pending item, so
            // bailing on isCancelled means only the latest queued frame renders.
            if work.isCancelled { return }
            let rendered = ImageRenderer.render(original: original, sourceCI: ci, stack: stackSnapshot)
            if work.isCancelled { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stack == stackSnapshot {
                    self.displayImage = rendered
                }
            }
        }
        pendingRender = work
        renderQueue.async(execute: work)
    }

    static func == (lhs: OpenImage, rhs: OpenImage) -> Bool { lhs.id == rhs.id }

    // MARK: - Undo / Redo helpers

    /// Commit a discrete action: capture the OLD stack before mutation, then
    /// mutate via `change`. Use for one-shot actions (rotate, flip, crop apply).
    func commitChange(_ change: () -> Void) {
        let old = stack
        change()
        if stack != old {
            history.push(old)
        }
    }

    /// Push the given stack onto the undo history. Use for slider-style edits
    /// where the snapshot is captured at drag-start and committed at drag-end.
    func commitSnapshot(_ snapshot: EditStack) {
        if snapshot != stack {
            history.push(snapshot)
        }
    }

    /// Apply a stack restored from XMP / autosave. Doesn't push to history
    /// (it's the initial state, not a user action).
    func applyRestoredStack(_ s: EditStack) {
        stack = s
        // Cancel the scheduled autosave that didSet just queued — it's the
        // same content we just restored.
        pendingAutosave?.cancel()
    }

    func performUndo() {
        guard let prev = history.undo(current: stack) else { return }
        stack = prev
    }

    func performRedo() {
        guard let next = history.redo(current: stack) else { return }
        stack = next
    }
}

final class UndoHistory: ObservableObject {
    @Published private(set) var undoStack: [EditStack] = []
    @Published private(set) var redoStack: [EditStack] = []
    var maxDepth: Int { max(1, AppSettings.shared.maxUndoLevels) }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func push(_ snapshot: EditStack) {
        undoStack.append(snapshot)
        if undoStack.count > maxDepth {
            undoStack.removeFirst(undoStack.count - maxDepth)
        }
        // Any new action invalidates the redo branch.
        redoStack.removeAll()
    }

    func undo(current: EditStack) -> EditStack? {
        guard let prev = undoStack.popLast() else { return nil }
        redoStack.append(current)
        if redoStack.count > maxDepth {
            redoStack.removeFirst(redoStack.count - maxDepth)
        }
        return prev
    }

    func redo(current: EditStack) -> EditStack? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        if undoStack.count > maxDepth {
            undoStack.removeFirst(undoStack.count - maxDepth)
        }
        return next
    }
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

        // How this file must be read is decided by the FILE, not by the current
        // save-mode preference — otherwise saving in one mode and switching the
        // setting would make us misinterpret our own output.
        let saved = SavedState.resolve(for: url)

        var image = img
        var originalData: Data?
        if case .editable(_, let embedded) = saved, let embedded,
           let restoredOriginal = NSImage(data: embedded) {
            // Mode C: the pixels on disk are the flattened result, but the file
            // carries the untouched original — edit from that instead.
            image = restoredOriginal
            originalData = embedded
        }

        let doc = OpenImage(url: url, image: image, originalFileData: originalData)
        documents.append(doc)
        selectedID = doc.id
        RecentFiles.shared.add(url)
        restoreEdits(for: doc, saved: saved)
        return doc
    }

    /// Apply whatever edits belong to this file: a re-applicable stack when the
    /// original pixels are available, otherwise nothing (the pixels are already
    /// final and re-applying would double every edit).
    private func restoreEdits(for doc: OpenImage, saved: SavedState) {
        switch saved {
        case .editable(let stack, _):
            doc.applyRestoredStack(stack)
            AutosaveStore.shared.clear(for: doc.url)
            return

        case .flattened(let recorded):
            // The pixels already contain these edits. Keep the record for the
            // metadata inspector, but start the live stack neutral.
            doc.recordedHistory = recorded
            AutosaveStore.shared.clear(for: doc.url)
            return

        case .none:
            break
        }

        // No edits in the file — offer the invisible autosave, if any.
        guard let pending = AutosaveStore.shared.load(for: doc.url),
              !pending.isNeutral else {
            return
        }
        let alert = NSAlert()
        alert.messageText = t("Continuati editarile salvate automat?")
        alert.informativeText = t("Photo2Mac a gasit editari nesalvate pentru %@.", doc.displayName)
        alert.addButton(withTitle: t("Continui"))
        alert.addButton(withTitle: t("Renunt"))
        if alert.runModal() == .alertFirstButtonReturn {
            doc.applyRestoredStack(pending)
        } else {
            AutosaveStore.shared.clear(for: doc.url)
        }
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

    /// Flush every open document's pending autosave synchronously. Called
    /// on app termination.
    func flushAllAutosaves() {
        for doc in documents { doc.flushAutosaveNow() }
    }

    private func supportedTypes() -> [UTType] {
        var types: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .webP]
        if let avif = UTType("public.avif") { types.append(avif) }
        return types
    }
}
