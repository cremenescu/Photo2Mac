// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

final class OpenImage: ObservableObject, Identifiable, Equatable {
    let id = UUID()
    /// The file this document saves to. Changes on Save As.
    @Published private(set) var url: URL
    let originalImage: NSImage
    let sourceCIImage: CIImage?
    @Published var displayImage: NSImage
    @Published var stack: EditStack {
        didSet {
            if stack != oldValue {
                rerender()
                scheduleAutosave()
                // Undo, redo or an edits-list revert while cropping: the image
                // behind the crop overlay is stale, so rebuild it.
                if isCropEditing { beginCropEdit() }
            }
        }
    }
    @Published var history = UndoHistory()

    /// The stack as the file on disk has it: neutral for a plain image, the
    /// re-applicable stack for one we saved editable. Unsaved = differs.
    @Published private(set) var savedStack = EditStack()

    var isDirty: Bool { stack != savedStack }

    /// The current stack is now what is on disk.
    func markSaved() {
        savedStack = stack
        clearAutosave()
    }

    /// Forget the unsaved edits' safety net: the user chose to discard them.
    func discardUnsavedState() {
        savedStack = stack
        clearAutosave()
    }

    /// Point the document at the file it was just saved as.
    ///
    /// The pixels of that file are rendered, so it is marked as baked; and
    /// when it carries no original, autosave stops — see `disableAutosave`.
    func retarget(to newURL: URL, writtenAs mode: SaveMode) {
        clearAutosave()
        url = newURL
        fileHasBakedEdits = true
        recordedHistory = nil
        if mode == .flattened { disableAutosave() }
    }

    /// After a flattened write the file on disk already contains the edits,
    /// but this document keeps editing from the untouched original in memory.
    /// An autosave taken now would be a stack relative to an original the
    /// file no longer has; restored on the next open it would be applied on
    /// top of baked pixels — the double-application bug again. So stop.
    private(set) var autosaveDisabled = false

    func disableAutosave() {
        autosaveDisabled = true
        clearAutosave()
    }

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
        let pixels = ImageRenderer.pixelSized(image)
        self.originalImage = pixels
        self.displayImage = pixels
        self.stack = EditStack()
        self.originalFileData = originalFileData
        // Convert source to CIImage once. Subsequent renders skip the
        // costly NSImage->CGImage->CIImage round-trip.
        self.sourceCIImage = ImageRenderer.makeCIImage(from: pixels)
        refreshHistogram()
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
        guard !autosaveDisabled else { return }
        let snap = stack
        let url = self.url
        let clean = (snap == savedStack)
        let work = DispatchWorkItem {
            // Back to what is on disk = nothing to recover.
            if clean {
                AutosaveStore.shared.clear(for: url)
            } else {
                AutosaveStore.shared.save(snap, for: url)
            }
        }
        pendingAutosave = work
        autosaveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Cancel a pending autosave and remove the stored one. Cancelling
    /// matters: a debounced write scheduled just before Save would otherwise
    /// land after it and resurrect the edits as "unsaved" on the next open.
    func clearAutosave() {
        pendingAutosave?.cancel()
        AutosaveStore.shared.clear(for: url)
    }

    /// Write the current stack to disk right now, synchronously, bypassing
    /// the 500ms debounce. Used on app quit so the last edit isn't lost
    /// when closing the window terminates the app.
    func flushAutosaveNow() {
        pendingAutosave?.cancel()
        guard !autosaveDisabled else { return }
        if isDirty {
            AutosaveStore.shared.save(stack, for: url)
        } else {
            AutosaveStore.shared.clear(for: url)
        }
    }


    /// Histogram of `displayImage`, refreshed with every render. Computed
    /// off the main thread: done in the inspector's body it ran a GPU readback
    /// on every slider tick.
    @Published private(set) var histogram: Histogram = .empty

    private func refreshHistogram() {
        let image = displayImage
        renderQueue.async { [weak self] in
            let hist = HistogramComputer.compute(for: image)
            DispatchQueue.main.async { self?.histogram = hist }
        }
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
            let hist = HistogramComputer.compute(for: rendered)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stack == stackSnapshot {
                    self.displayImage = rendered
                    self.histogram = hist
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
        let reopen = closeSessionForHistory()
        let old = stack
        change()
        if stack != old {
            history.push(old)
        }
        if reopen { beginSession() }
    }

    /// Push the given stack onto the undo history. Use for slider-style edits
    /// where the snapshot is captured at drag-start and committed at drag-end.
    func commitSnapshot(_ snapshot: EditStack) {
        if snapshot != stack {
            history.push(snapshot)
        }
    }

    /// Apply a stack restored from XMP / autosave. Doesn't push to history
    /// (it's the initial state, not a user action). `asSaved` = the stack
    /// came from the file itself, so it is not an unsaved change.
    func applyRestoredStack(_ s: EditStack, asSaved: Bool) {
        if asSaved { savedStack = s }
        stack = s
        // Cancel the scheduled autosave that didSet just queued — it's the
        // same content we just restored.
        pendingAutosave?.cancel()
    }

    func performUndo() {
        let reopen = closeSessionForHistory()
        if let prev = history.undo(current: stack) { stack = prev }
        if reopen { beginSession() }
    }

    func performRedo() {
        let reopen = closeSessionForHistory()
        if let next = history.redo(current: stack) { stack = next }
        if reopen { beginSession() }
    }

    // MARK: - Tool sessions

    /// The stack as it was when the current tool (rotate, adjustments,
    /// resize) was opened. Edits inside the tool change `stack` live, for the
    /// preview, but reach the undo history as ONE step when the tool closes.
    ///
    /// It lives on the document, not in the inspector view: SwiftUI reuses the
    /// inspector when the selected tab changes, so a snapshot held there was
    /// taken from one document and restored onto another.
    @Published private(set) var sessionSnapshot: EditStack?

    var sessionHasChanges: Bool {
        guard let s = sessionSnapshot else { return false }
        return s != stack
    }

    func beginSession() {
        if sessionSnapshot == nil { sessionSnapshot = stack }
    }

    /// Close the session and record it as one undo step.
    func commitSession() {
        guard let s = sessionSnapshot else { return }
        sessionSnapshot = nil
        commitSnapshot(s)
    }

    /// Close the session and throw its edits away.
    func cancelSession() {
        guard let s = sessionSnapshot else { return }
        sessionSnapshot = nil
        stack = s
    }

    /// History operations inside an open session must not interleave with it:
    /// the session's pending step is committed first, and the session is
    /// reopened afterwards so the tool keeps grouping what follows.
    private func closeSessionForHistory() -> Bool {
        guard sessionSnapshot != nil else { return false }
        commitSession()
        return true
    }

    // MARK: - Crop editing

    /// The crop tool's live state, or nil while it is being rendered or when
    /// the tool is closed.
    @Published private(set) var cropEdit: CropEditState?
    private(set) var isCropEditing = false
    private var cropEditToken = 0

    /// Open (or rebuild) the crop tool. The image shown behind the overlay is
    /// rendered off the main thread: for a large photo it takes long enough
    /// to freeze the window when done inline.
    func beginCropEdit() {
        isCropEditing = true
        cropEditToken &+= 1
        let token = cropEditToken
        let stack = self.stack, original = originalImage, ci = sourceCIImage
        renderQueue.async { [weak self] in
            let state = CropEditState.make(stack: stack, original: original, sourceCI: ci)
            DispatchQueue.main.async {
                guard let self, self.isCropEditing, self.cropEditToken == token else { return }
                self.cropEdit = state
            }
        }
    }

    func cancelCropEdit() {
        isCropEditing = false
        cropEditToken &+= 1
        cropEdit = nil
    }

    func applyCropEdit() {
        guard let s = cropEdit else {
            cancelCropEdit()
            return
        }
        let whole = s.coversWholeImage
        let n = s.normalized
        cancelCropEdit()
        var next = stack
        if whole { next.crop = nil } else { next.setCrop(n) }
        commitChange { stack = next }
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
    @Published var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            Self.endSession(of: tool, on: documents.first(where: { $0.id == oldValue }))
            Self.beginSession(of: tool, on: selected)
            comparing = false
        }
    }

    /// The active tool. Owned here rather than by a view so that keyboard
    /// shortcuts, menu commands and the inspector all open and close the same
    /// session.
    @Published var tool: EditorTool = .hand {
        didSet {
            guard tool != oldValue else { return }
            Self.endSession(of: oldValue, on: selected)
            Self.beginSession(of: tool, on: selected)
        }
    }

    /// True while the user holds the before/after control: the canvas shows
    /// the untouched original.
    @Published var comparing = false

    var selected: OpenImage? {
        documents.first(where: { $0.id == selectedID })
    }

    // MARK: - Tools

    /// Leaving a tool without Apply/Cancel keeps its edits (they are already
    /// visible) — except crop, whose rectangle is only a proposal until Apply.
    private static func endSession(of tool: EditorTool, on doc: OpenImage?) {
        guard let doc else { return }
        switch tool {
        case .crop: doc.cancelCropEdit()
        case .rotate, .tune, .resize: doc.commitSession()
        case .hand, .info: break
        }
    }

    private static func beginSession(of tool: EditorTool, on doc: OpenImage?) {
        guard let doc else { return }
        switch tool {
        case .crop: doc.beginCropEdit()
        case .rotate, .tune, .resize: doc.beginSession()
        case .hand, .info: break
        }
    }

    /// The inspector's Apply (or Return on the canvas).
    func applyTool() {
        if let doc = selected {
            if tool == .crop { doc.applyCropEdit() } else { doc.commitSession() }
        }
        tool = .hand
    }

    /// The inspector's Cancel (or Escape on the canvas).
    func cancelTool() {
        if let doc = selected {
            if tool == .crop { doc.cancelCropEdit() } else { doc.cancelSession() }
        }
        tool = .hand
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

    /// Modal alerts go through here so tests can answer them.
    var presentAlert: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    @discardableResult
    func open(url: URL) -> OpenImage? {
        if let existing = documents.first(where: { $0.url == url }) {
            selectedID = existing.id
            return existing
        }
        guard let doc = makeDocument(for: url) else { return nil }
        documents.append(doc)
        // Selected last: selecting opens the active tool's session, which
        // must start from the restored stack, not from the neutral one.
        selectedID = doc.id
        return doc
    }

    /// Load `url` into a document with its saved edits restored, or explain
    /// why not.
    private func makeDocument(for url: URL) -> OpenImage? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            RecentFiles.shared.remove(url)
            fail(t("Fisierul nu mai exista"),
                 t("%@ a fost mutat sau sters.", url.lastPathComponent))
            return nil
        }
        guard let img = NSImage(contentsOf: url), img.isValid,
              img.representations.first.map({ $0.pixelsWide > 0 }) ?? false else {
            fail(t("Nu pot deschide imaginea"),
                 t("%@ nu este o imagine pe care macOS o poate citi.", url.lastPathComponent))
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
        RecentFiles.shared.add(url)
        restoreEdits(for: doc, saved: saved)
        return doc
    }

    private func fail(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = presentAlert(alert)
    }

    /// Apply whatever edits belong to this file: a re-applicable stack when the
    /// original pixels are available, otherwise nothing (the pixels are already
    /// final and re-applying would double every edit). Then offer unsaved
    /// edits left behind by a crash or a quit, if they still match the file.
    private func restoreEdits(for doc: OpenImage, saved: SavedState) {
        var fileStack = EditStack()
        switch saved {
        case .editable(let stack, _):
            fileStack = stack
            doc.applyRestoredStack(stack, asSaved: true)
        case .flattened(let recorded):
            // The pixels already contain these edits. Keep the record for the
            // metadata inspector, but start the live stack neutral.
            doc.recordedHistory = recorded
        case .none:
            break
        }

        // `load` already refuses an autosave taken against a different
        // version of the file. One equal to what the file has is not unsaved.
        guard let pending = AutosaveStore.shared.load(for: doc.url),
              pending != fileStack else {
            AutosaveStore.shared.clear(for: doc.url)
            return
        }
        let alert = NSAlert()
        alert.messageText = t("Continuati editarile salvate automat?")
        alert.informativeText = t("Photo2Mac a gasit editari nesalvate pentru %@.", doc.displayName)
        alert.addButton(withTitle: t("Continui"))
        alert.addButton(withTitle: t("Renunt"))
        if presentAlert(alert) == .alertFirstButtonReturn {
            doc.applyRestoredStack(pending, asSaved: false)
        } else {
            AutosaveStore.shared.clear(for: doc.url)
        }
    }

    // MARK: - Folder navigation

    /// Images in `dir`, in Finder's order.
    static func images(in dir: URL) -> [URL] {
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
                                 "webp", "avif", "gif", "bmp"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending }
    }

    /// Open the previous (-1) or next (+1) image in the selected document's
    /// folder. It replaces the current tab when that tab has nothing unsaved,
    /// so paging through a folder does not pile up tabs; otherwise it opens
    /// in a new one.
    func openSibling(offset: Int) {
        guard let doc = selected else { return }
        let list = Self.images(in: doc.url.deletingLastPathComponent())
        let me = doc.url.standardizedFileURL
        guard let idx = list.firstIndex(where: { $0.standardizedFileURL == me }) else { return }
        let target = idx + offset
        guard list.indices.contains(target) else {
            NSSound.beep()
            return
        }
        let url = list[target]
        if let existing = documents.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            selectedID = existing.id
            return
        }
        guard !doc.isDirty, let i = documents.firstIndex(where: { $0.id == doc.id }) else {
            open(url: url)
            return
        }
        guard let next = makeDocument(for: url) else { return }
        Self.endSession(of: tool, on: doc)
        documents[i] = next
        selectedID = next.id
    }

    // MARK: - Closing

    enum CloseDecision { case save, discard, cancel }

    /// Ask what to do with unsaved edits. Nil means there is nothing to ask.
    private func askAboutUnsaved(_ dirty: [OpenImage]) -> CloseDecision? {
        guard !dirty.isEmpty else { return nil }
        let alert = NSAlert()
        if dirty.count == 1 {
            alert.messageText = t("Salvezi modificarile din %@?", dirty[0].displayName)
        } else {
            alert.messageText = t("%d imagini au modificari nesalvate. Le salvezi?", dirty.count)
        }
        alert.informativeText = t("Daca nu le salvezi, modificarile se pierd.")
        alert.addButton(withTitle: dirty.count == 1 ? t("Salveaza") : t("Salveaza tot"))
        alert.addButton(withTitle: t("Nu salva"))
        alert.addButton(withTitle: t("Anuleaza"))
        switch presentAlert(alert) {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Settle every unsaved document before the window closes or the app
    /// quits. Returns false when the user cancelled or a save failed.
    func resolveUnsaved(_ docs: [OpenImage]? = nil) -> Bool {
        let dirty = (docs ?? documents).filter(\.isDirty)
        switch askAboutUnsaved(dirty) {
        case nil:
            return true
        case .cancel:
            return false
        case .discard:
            dirty.forEach { $0.discardUnsavedState() }
            return true
        case .save:
            for doc in dirty where save(doc) == nil { return false }
            return true
        }
    }

    /// Save in place; injectable for tests.
    var save: (OpenImage) -> URL? = { SaveService.saveInPlace(doc: $0) }

    func closeSelected() {
        guard let doc = selected else { return }
        close(doc)
    }

    func close(_ doc: OpenImage) {
        guard let idx = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        guard resolveUnsaved([doc]) else { return }
        let wasSelected = selectedID == doc.id
        if wasSelected { Self.endSession(of: tool, on: doc) }
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
