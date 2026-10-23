// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Starts Sparkle, which schedules its daily check.
        _ = AppUpdater.shared
        NSWindow.allowsAutomaticWindowTabbing = false
        for window in NSApp.windows {
            window.tabbingMode = .disallowed
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            window.tabbingMode = .disallowed
            if window.title == "Photo2Mac" { WindowCloseGuard.install(on: window) }
        }
    }

    /// Cmd+Q (and the quit that follows closing the window) with unsaved
    /// edits asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WorkspaceHolder.shared.workspace.resolveUnsaved() ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the (only) main window quits the app — the red X and
        // closing the last tab both end up here. Settings/Help are
        // auxiliary; closing one of those alone won't quit while the main
        // window is still open.
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persist the last edit synchronously — the 500ms autosave debounce
        // may not have fired if the user just quit by closing the window.
        WorkspaceHolder.shared.workspace.flushAllAutosaves()
    }

    /// Close the main editor window (title "Photo2Mac"), not Settings/Help.
    /// With terminateAfterLastWindowClosed this quits the app when it's the
    /// only remaining window.
    static func closeMainWindow() {
        let main = NSApp.windows.first { $0.title == "Photo2Mac" }
            ?? NSApp.keyWindow
        main?.close()
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

/// Asks about unsaved edits before the main window closes.
///
/// SwiftUI owns the window's delegate, so this one sits in front of it and
/// forwards everything else. Without it the red close button would close the
/// window first and only then ask, from a quit that can no longer bring the
/// window back.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    private weak var inner: NSWindowDelegate?
    private static var guards: [ObjectIdentifier: WindowCloseGuard] = [:]

    static func install(on window: NSWindow) {
        guard !(window.delegate is WindowCloseGuard) else { return }
        let g = WindowCloseGuard()
        g.inner = window.delegate
        guards[ObjectIdentifier(window)] = g
        window.delegate = g
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard WorkspaceHolder.shared.workspace.resolveUnsaved() else { return false }
        return inner?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        inner?.windowWillClose?(notification)
        if let w = notification.object as? NSWindow {
            Self.guards[ObjectIdentifier(w)] = nil
        }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (inner?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let inner, inner.responds(to: aSelector) { return inner }
        return super.forwardingTarget(for: aSelector)
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

struct SaveCommands: Commands {
    @ObservedObject private var workspace = WorkspaceHolder.shared.workspace

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button(t("Salveaza")) {
                NotificationCenter.default.post(name: .photo2MacDismissPopovers, object: nil)
                if let doc = workspace.selected {
                    _ = SaveService.saveInPlace(doc: doc)
                }
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(workspace.selected == nil)

            Button(t("Salveaza ca...")) {
                NotificationCenter.default.post(name: .photo2MacDismissPopovers, object: nil)
                if let doc = workspace.selected {
                    _ = SaveService.saveAs(doc: doc)
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(workspace.selected == nil)

            Button(t("Exporta...")) {
                NotificationCenter.default.post(name: .photo2MacDismissPopovers, object: nil)
                if let doc = workspace.selected {
                    _ = SaveService.export(doc: doc)
                }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(workspace.selected == nil)
        }
    }
}

struct NavigationCommands: Commands {
    @ObservedObject private var workspace = WorkspaceHolder.shared.workspace

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(t("Imaginea anterioara din dosar")) {
                workspace.openSibling(offset: -1)
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(workspace.selected == nil)
            Button(t("Imaginea urmatoare din dosar")) {
                workspace.openSibling(offset: 1)
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(workspace.selected == nil)
            Divider()
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
                    let ws = WorkspaceHolder.shared.workspace
                    ws.closeSelected()
                    // Browser-style: closing the last tab closes the window,
                    // which quits the app (terminateAfterLastWindowClosed).
                    if ws.documents.isEmpty {
                        AppDelegate.closeMainWindow()
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])

                Button(t("Inchide fereastra")) {
                    AppDelegate.closeMainWindow()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            SaveCommands()
            NavigationCommands()
            PreferencesCommand()
            UndoRedoCommands()
            AboutHelpCommands()
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
