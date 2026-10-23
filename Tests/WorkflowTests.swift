// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Photo2Mac

/// What happens between opening a file and closing it: tool sessions, unsaved
/// state, autosave, Save As, paging through a folder.
final class WorkflowTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2m-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files { AutosaveStore.shared.clear(for: f) }
        }
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    /// A 64x32 PNG named `name` in the test folder.
    @discardableResult
    private func fixture(_ name: String) throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.orange.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = dir.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    /// A workspace whose alerts answer `answers` in order (then "cancel").
    private func workspace(answers: [NSApplication.ModalResponse] = []) -> (Workspace, () -> Int) {
        let ws = Workspace()
        var queue = answers
        var asked = 0
        ws.presentAlert = { _ in
            asked += 1
            return queue.isEmpty ? .alertThirdButtonReturn : queue.removeFirst()
        }
        return (ws, { asked })
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func pixelWidth(_ url: URL) throws -> Int {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int)
    }

    // MARK: - Tool sessions

    /// The crop tool used to clear `stack.crop` on entry, so Cmd+S or an
    /// autosave while it was open wrote the image WITHOUT its crop.
    func testOpeningTheCropToolKeepsTheExistingCrop() throws {
        let (ws, _) = workspace()
        let doc = try XCTUnwrap(ws.open(url: try fixture("a.png")))
        doc.stack.setCrop(CropRect(x: 0, y: 0, width: 0.5, height: 0.5))

        ws.tool = .crop
        XCTAssertNotNil(doc.stack.crop, "entering crop dropped the crop from the stack")
        waitFor("crop state") { doc.cropEdit != nil }
        XCTAssertEqual(doc.cropEdit?.preCropImage.size, NSSize(width: 64, height: 32),
                       "the crop tool should show the uncropped image")
        XCTAssertNotNil(doc.stack.crop)

        ws.tool = .hand
        XCTAssertEqual(doc.stack.crop, CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertNil(doc.cropEdit)
    }

    func testCropApplyIsOneUndoStep() throws {
        let (ws, _) = workspace()
        let doc = try XCTUnwrap(ws.open(url: try fixture("a.png")))
        ws.tool = .crop
        waitFor("crop state") { doc.cropEdit != nil }
        doc.cropEdit?.rect = CGRect(x: 0, y: 0, width: 32, height: 16)
        ws.applyTool()

        XCTAssertEqual(ws.tool, .hand)
        XCTAssertEqual(doc.stack.crop, CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        doc.performUndo()
        XCTAssertNil(doc.stack.crop)
    }

    /// The snapshot a tool restores on Cancel lived in the inspector view,
    /// which SwiftUI reuses across tabs: cancelling in tab B restored tab A's
    /// stack onto B.
    func testToolSessionsBelongToTheirDocument() throws {
        let (ws, _) = workspace()
        let a = try XCTUnwrap(ws.open(url: try fixture("a.png")))
        ws.tool = .tune
        a.stack.adjustments.brightness = 0.5

        let b = try XCTUnwrap(ws.open(url: try fixture("b.png")))
        XCTAssertEqual(ws.selected?.id, b.id)
        b.stack.adjustments.contrast = 0.3
        ws.cancelTool()

        XCTAssertEqual(b.stack.adjustments.contrast, 0, "cancel did not revert the visible document")
        XCTAssertEqual(b.stack.adjustments.brightness, 0, "cancel applied the other tab's stack")
        XCTAssertEqual(a.stack.adjustments.brightness, 0.5, "switching tabs lost the first tab's edit")
        XCTAssertTrue(a.history.canUndo, "the first tab's edit should be one undo step")
    }

    func testUndoInsideAnOpenToolDoesNotCorruptHistory() throws {
        let (ws, _) = workspace()
        let doc = try XCTUnwrap(ws.open(url: try fixture("a.png")))
        ws.tool = .rotate
        doc.stack.rotateQuarter(clockwise: true)
        doc.performUndo()
        XCTAssertEqual(doc.stack.rotateDegrees, 0)
        doc.stack.rotateQuarter(clockwise: false)
        ws.applyTool()
        XCTAssertEqual(doc.stack.rotateDegrees, -90)
        doc.performUndo()
        XCTAssertEqual(doc.stack.rotateDegrees, 0)
        XCTAssertFalse(doc.history.canUndo)
    }

    // MARK: - Unsaved state

    func testDirtyTracksTheFileNotTheHistory() throws {
        let (ws, _) = workspace()
        let url = try fixture("a.png")
        let doc = try XCTUnwrap(ws.open(url: url))
        XCTAssertFalse(doc.isDirty)
        doc.stack.rotateQuarter(clockwise: true)
        XCTAssertTrue(doc.isDirty)
        doc.stack.rotateQuarter(clockwise: false)
        XCTAssertFalse(doc.isDirty, "back to what is on disk is not unsaved")
    }

    /// A debounced autosave scheduled just before Save used to land after it
    /// and bring the saved edits back as "unsaved" on the next open.
    func testSaveCancelsThePendingAutosave() throws {
        let url = try fixture("a.png")
        let doc = OpenImage(url: url, image: try XCTUnwrap(NSImage(contentsOf: url)))
        doc.stack.adjustments.brightness = 0.4
        XCTAssertNotNil(SaveService.saveInPlace(doc: doc))
        XCTAssertFalse(doc.isDirty)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(AutosaveStore.shared.exists(for: url), "the pre-save autosave survived the save")
    }

    /// After a flattened in-place save the document still edits from the
    /// untouched original in memory; an autosave of that stack, restored onto
    /// the now-baked file, would apply every edit twice.
    func testNoAutosaveAfterAFlattenedSave() throws {
        let url = try fixture("a.png")
        let doc = OpenImage(url: url, image: try XCTUnwrap(NSImage(contentsOf: url)))
        doc.stack.setCrop(CropRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .flattened))
        doc.stack.adjustments.brightness = 0.2
        doc.flushAutosaveNow()
        XCTAssertFalse(AutosaveStore.shared.exists(for: url))
    }

    func testAutosaveIsOfferedAndCanBeDeclined() throws {
        let url = try fixture("a.png")
        var s = EditStack()
        s.rotateDegrees = 90
        AutosaveStore.shared.save(s, for: url)

        let (declining, asked) = workspace(answers: [.alertSecondButtonReturn])
        let doc = try XCTUnwrap(declining.open(url: url))
        XCTAssertEqual(asked(), 1)
        XCTAssertEqual(doc.stack.rotateDegrees, 0)
        XCTAssertFalse(AutosaveStore.shared.exists(for: url))
    }

    func testAcceptedAutosaveIsUnsaved() throws {
        let url = try fixture("a.png")
        var s = EditStack()
        s.rotateDegrees = 90
        AutosaveStore.shared.save(s, for: url)

        let (ws, _) = workspace(answers: [.alertFirstButtonReturn])
        let doc = try XCTUnwrap(ws.open(url: url))
        XCTAssertEqual(doc.stack.rotateDegrees, 90)
        XCTAssertTrue(doc.isDirty, "recovered edits are not on disk yet")
    }

    /// For a file saved editable, an autosave used to be deleted silently on
    /// open. Edits made after that save must be offered back.
    func testAutosaveOnTopOfAnEditableFileIsOffered() throws {
        let url = try fixture("a.png")
        let doc = OpenImage(url: url, image: try XCTUnwrap(NSImage(contentsOf: url)))
        doc.stack.rotateQuarter(clockwise: true)
        XCTAssertNotNil(SaveService.write(doc: doc, to: url, mode: .sidecar))
        var later = doc.stack
        later.adjustments.exposure = 1
        AutosaveStore.shared.save(later, for: url)

        let (ws, asked) = workspace(answers: [.alertFirstButtonReturn])
        let reopened = try XCTUnwrap(ws.open(url: url))
        XCTAssertEqual(asked(), 1)
        XCTAssertEqual(reopened.stack, later)
        XCTAssertTrue(reopened.isDirty)
        SidecarStore.clear(for: url)
    }

    // MARK: - Save As

    func testSaveAsMovesTheDocumentToTheNewFile() throws {
        let url = try fixture("a.png")
        let doc = OpenImage(url: url, image: try XCTUnwrap(NSImage(contentsOf: url)))
        doc.stack.setCrop(CropRect(x: 0, y: 0, width: 0.5, height: 1))
        let out = dir.appendingPathComponent("a-edited.png")

        XCTAssertNotNil(SaveService.saveAs(doc: doc, to: out, mode: .flattened))
        XCTAssertEqual(doc.url, out)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try pixelWidth(url), 64, "Save As modified the original file")
        XCTAssertEqual(try pixelWidth(out), 32)

        // The new file has baked pixels: saving again must not crop again.
        XCTAssertNotNil(SaveService.saveInPlace(doc: doc))
        XCTAssertEqual(try pixelWidth(out), 32, "second save re-applied the crop to the new file")
    }

    func testExportLeavesTheDocumentAlone() throws {
        let url = try fixture("a.png")
        let doc = OpenImage(url: url, image: try XCTUnwrap(NSImage(contentsOf: url)))
        doc.stack.adjustments.saturation = -1
        let out = dir.appendingPathComponent("small.jpg")
        let stack = SaveService.exportStack(for: doc, longEdge: 16)
        XCTAssertNotNil(SaveService.write(doc: doc, to: out, mode: .flattened, stack: stack,
                                          quality: 0.8, isExport: true))
        XCTAssertEqual(try pixelWidth(out), 16)
        XCTAssertEqual(doc.url, url)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(SaveService.exportStack(for: doc, longEdge: 4096), doc.stack,
                       "export must never scale up")
    }

    // MARK: - Folder navigation

    func testNextReplacesACleanTabAndKeepsADirtyOne() throws {
        try fixture("01.png")
        try fixture("02.png")
        try fixture("10.png")   // Finder order: 01, 02, 10 (not 01, 10, 02)
        let (ws, _) = workspace()
        let first = try XCTUnwrap(ws.open(url: dir.appendingPathComponent("01.png")))

        ws.openSibling(offset: 1)
        XCTAssertEqual(ws.documents.count, 1, "a clean tab should be replaced")
        XCTAssertEqual(ws.selected?.url.lastPathComponent, "02.png")
        XCTAssertFalse(ws.documents.contains(first))

        ws.selected?.stack.rotateQuarter(clockwise: true)
        ws.openSibling(offset: 1)
        XCTAssertEqual(ws.documents.count, 2, "a tab with unsaved edits must not be replaced")
        XCTAssertEqual(ws.selected?.url.lastPathComponent, "10.png")

        ws.openSibling(offset: -1)
        XCTAssertEqual(ws.documents.count, 2, "going back should select the open tab")
        XCTAssertEqual(ws.selected?.url.lastPathComponent, "02.png")
    }

    // MARK: - Closing

    func testClosingAnUnsavedTabAsks() throws {
        let (ws, asked) = workspace(answers: [.alertThirdButtonReturn, .alertSecondButtonReturn])
        let doc = try XCTUnwrap(ws.open(url: try fixture("a.png")))
        doc.stack.rotateQuarter(clockwise: true)

        ws.close(doc)
        XCTAssertEqual(asked(), 1)
        XCTAssertEqual(ws.documents.count, 1, "Cancel closed the tab")

        ws.close(doc)
        XCTAssertEqual(ws.documents.count, 0, "Don't Save did not close the tab")
        XCTAssertFalse(AutosaveStore.shared.exists(for: doc.url))
    }

    func testQuitSavesWhenAskedTo() throws {
        let (ws, _) = workspace(answers: [.alertFirstButtonReturn])
        var saved: [URL] = []
        ws.save = { doc in saved.append(doc.url); doc.markSaved(); return doc.url }
        let a = try XCTUnwrap(ws.open(url: try fixture("a.png")))
        _ = try XCTUnwrap(ws.open(url: try fixture("b.png")))
        a.stack.rotateQuarter(clockwise: true)

        XCTAssertTrue(ws.resolveUnsaved())
        XCTAssertEqual(saved, [a.url], "only the unsaved document should be saved")
        XCTAssertTrue(ws.resolveUnsaved(), "nothing left to ask about")
    }

    func testOpeningAMissingFileExplainsAndForgetsIt() {
        let (ws, asked) = workspace(answers: [.alertFirstButtonReturn])
        XCTAssertNil(ws.open(url: dir.appendingPathComponent("gone.png")))
        XCTAssertEqual(asked(), 1, "a missing file should be explained, not just beeped at")
    }
}
