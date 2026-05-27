// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import UniformTypeIdentifiers

@main
struct Photo2MacApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PhotoDocument() }) { config in
            ContentView(document: config.document)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .frame(width: 480, height: 280)
        }
    }
}
