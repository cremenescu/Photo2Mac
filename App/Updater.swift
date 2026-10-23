// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import Sparkle

/// Owns the Sparkle updater for the app's lifetime.
final class AppUpdater {
    static let shared = AppUpdater()

    let controller: SPUStandardUpdaterController

    var updater: SPUUpdater { controller.updater }

    private init() {
        // Under `xcodebuild test` the app is the test host; a test run has no
        // business checking a live feed or putting up an update dialog.
        controller = SPUStandardUpdaterController(
            startingUpdater: !RecentFiles.isRunningTests,
            updaterDelegate: nil, userDriverDelegate: nil)
    }
}

/// Mirrors the updater's KVO properties for SwiftUI: whether a check may be
/// started now, and whether checks run automatically (the Settings toggle).
final class UpdaterViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecks: Bool {
        didSet {
            if updater.automaticallyChecksForUpdates != automaticallyChecks {
                updater.automaticallyChecksForUpdates = automaticallyChecks
            }
        }
    }

    private let updater: SPUUpdater

    init(updater: SPUUpdater = AppUpdater.shared.updater) {
        self.updater = updater
        automaticallyChecks = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { updater.checkForUpdates() }
}

/// "Check for Updates…" menu item. A view of its own so the disabled state
/// follows the updater (a bare Button in a CommandGroup would not refresh).
struct CheckForUpdatesView: View {
    @StateObject private var model = UpdaterViewModel()

    var body: some View {
        Button(t("Cauta actualizari..."), action: model.checkForUpdates)
            .disabled(!model.canCheckForUpdates)
    }
}
