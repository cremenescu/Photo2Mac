// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
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

    var body: some Scene {
        WindowGroup("Photo2Mac") {
            WorkspaceView()
                .environmentObject(WorkspaceHolder.shared.workspace)
                .frame(minWidth: 900, minHeight: 600)
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
                .frame(width: 480, height: 280)
        }
    }
}
