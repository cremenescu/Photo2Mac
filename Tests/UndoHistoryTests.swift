// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import XCTest
@testable import Photo2Mac

final class UndoHistoryTests: XCTestCase {

    private func stack(brightness: Double) -> EditStack {
        var s = EditStack()
        s.adjustments.brightness = brightness
        return s
    }

    func testInitiallyEmpty() {
        let h = UndoHistory()
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
    }

    func testPushEnablesUndo() {
        let h = UndoHistory()
        h.push(stack(brightness: 0))
        XCTAssertTrue(h.canUndo)
        XCTAssertFalse(h.canRedo)
    }

    func testUndoMovesToRedo() {
        let h = UndoHistory()
        let s0 = stack(brightness: 0)
        let s1 = stack(brightness: 0.5)
        h.push(s0)  // pre-edit snapshot
        // simulate the doc is now at s1
        let restored = h.undo(current: s1)
        XCTAssertEqual(restored, s0)
        XCTAssertFalse(h.canUndo)
        XCTAssertTrue(h.canRedo)
    }

    func testRedoAfterUndo() {
        let h = UndoHistory()
        let s0 = stack(brightness: 0)
        let s1 = stack(brightness: 0.5)
        h.push(s0)
        _ = h.undo(current: s1)
        let next = h.redo(current: s0)
        XCTAssertEqual(next, s1)
        XCTAssertTrue(h.canUndo)
        XCTAssertFalse(h.canRedo)
    }

    func testNewPushClearsRedo() {
        let h = UndoHistory()
        let s0 = stack(brightness: 0)
        let s1 = stack(brightness: 0.5)
        let s2 = stack(brightness: 0.8)
        h.push(s0)
        _ = h.undo(current: s1)  // redo now has s1
        XCTAssertTrue(h.canRedo)
        h.push(s0)  // new action invalidates redo
        XCTAssertFalse(h.canRedo)
    }

    func testTrimAtMaxDepth() {
        let h = UndoHistory()
        AppSettings.shared.maxUndoLevels = 3
        for i in 0..<10 {
            h.push(stack(brightness: Double(i) / 10.0))
        }
        XCTAssertEqual(h.undoStack.count, 3)
        // Reset for other tests
        AppSettings.shared.maxUndoLevels = 50
    }

    func testOpenImageCommitChangePushes() {
        // Smoke test of OpenImage's commitChange helper.
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        img.unlockFocus()
        let url = URL(fileURLWithPath: "/tmp/fixture.png")
        let doc = OpenImage(url: url, image: img)
        XCTAssertFalse(doc.history.canUndo)
        doc.commitChange { doc.stack.rotateDegrees = 90 }
        XCTAssertTrue(doc.history.canUndo)
        XCTAssertEqual(doc.stack.rotateDegrees, 90)
        doc.performUndo()
        XCTAssertEqual(doc.stack.rotateDegrees, 0)
        XCTAssertTrue(doc.history.canRedo)
        doc.performRedo()
        XCTAssertEqual(doc.stack.rotateDegrees, 90)
    }
}
