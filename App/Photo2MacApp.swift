// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        for window in NSApp.windows {
            window.tabbingMode = .disallowed
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            win.tabbingMode = .disallowed
            // SwiftUI Settings scene creates a fixed-size window even when
            // .windowResizability(.contentMinSize) is set. Force-add resizable
            // styleMask + reasonable min/max sizes for the prefs window.
            if win.identifier?.rawValue.contains("settings") == true
                || win.title.contains("Settings")
                || win.title.contains("Preferences") {
                Self.makeWindowResizable(win)
                // Re-apply shortly after — SwiftUI may overwrite styleMask
                // when it finishes its own setup pass.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    Self.makeWindowResizable(win)
                }
            }
        }
    }

    static func makeWindowResizable(_ win: NSWindow) {
        win.styleMask.insert(.resizable)
        win.contentMinSize = NSSize(width: 520, height: 420)
        win.contentMaxSize = NSSize(width: 1600, height: 1200)
        win.minSize = NSSize(width: 520, height: 420)
        win.maxSize = NSSize(width: 1600, height: 1200)
        if win.frame.size.width < 620 || win.frame.size.height < 500 {
            var frame = win.frame
            frame.size = NSSize(width: 640, height: 540)
            win.setFrame(frame, display: true, animate: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
                return false
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        DispatchQueue.main.async {
            for url in urls { WorkspaceHolder.shared.workspace.open(url: url) }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        DispatchQueue.main.async {
            WorkspaceHolder.shared.workspace.open(url: url)
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.async {
            for url in urls { WorkspaceHolder.shared.workspace.open(url: url) }
        }
        sender.reply(toOpenOrPrint: .success)
    }
}

/// Singleton bridge so AppDelegate can reach the Workspace.
final class WorkspaceHolder {
    static let shared = WorkspaceHolder()
    let workspace = Workspace()
}

@main
struct Photo2MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        Window("Photo2Mac", id: "main") {
            WorkspaceView()
                .environmentObject(WorkspaceHolder.shared.workspace)
                .frame(minWidth: 500, minHeight: 380)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Deschide imagine...") {
                    WorkspaceHolder.shared.workspace.openPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                RecentMenu()
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Inchide tab") {
                    WorkspaceHolder.shared.workspace.closeSelected()
                }
                .keyboardShortcut("w", modifiers: [.command])

                Button("Inchide fereastra") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
