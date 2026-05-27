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
            object: nil, queue: .main
        ) { note in
            (note.object as? NSWindow)?.tabbingMode = .disallowed
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

struct PreferencesCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(t("Preferinte...")) {
                openWindow(id: "preferences")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }
    }
}

struct UndoRedoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(t("Anuleaza")) {
                WorkspaceHolder.shared.workspace.selected?.performUndo()
            }
            .keyboardShortcut("z", modifiers: [.command])
            Button(t("Refa")) {
                WorkspaceHolder.shared.workspace.selected?.performRedo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}

@main
struct Photo2MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    @StateObject private var languageManager = LanguageManager.shared

    var body: some Scene {
        Window("Photo2Mac", id: "main") {
            WorkspaceView()
                .environmentObject(WorkspaceHolder.shared.workspace)
                .environmentObject(languageManager)
                .frame(minWidth: 500, minHeight: 380)
                .id(languageManager.choice)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(t("Deschide imagine...")) {
                    WorkspaceHolder.shared.workspace.openPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                RecentMenu()
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button(t("Inchide tab")) {
                    WorkspaceHolder.shared.workspace.closeSelected()
                }
                .keyboardShortcut("w", modifiers: [.command])

                Button(t("Inchide fereastra")) {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button(t("Salveaza ca...")) {
                    if let doc = WorkspaceHolder.shared.workspace.selected {
                        _ = SaveService.saveAs(doc: doc)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])
            }
            PreferencesCommand()
            UndoRedoCommands()
        }

        Window("Photo2Mac Settings", id: "preferences") {
            SettingsView()
                .environmentObject(languageManager)
                .id(languageManager.choice)
        }
        .defaultSize(width: 640, height: 540)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
    }
}
