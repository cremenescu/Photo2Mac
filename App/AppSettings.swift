// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("initialZoomMode") var initialZoomModeRaw: String = InitialZoom.fit.rawValue
    @AppStorage("maxRecentItems") var maxRecentItems: Int = 10
    @AppStorage("alwaysRefitOnResize") var alwaysRefitOnResize: Bool = false
    @AppStorage("maxUndoLevels") var maxUndoLevels: Int = 50
    @AppStorage("saveMode") var saveModeRaw: String = SaveMode.flattened.rawValue

    var initialZoomMode: InitialZoom {
        get { InitialZoom(rawValue: initialZoomModeRaw) ?? .fit }
        set { initialZoomModeRaw = newValue.rawValue }
    }

    /// What Cmd+S does to the file. Defaults to `.flattened`: it is what every
    /// other lightweight editor does, and it is the only mode whose result is
    /// visible to the rest of the system without an extra export step.
    var saveMode: SaveMode {
        get { SaveMode(rawValue: saveModeRaw) ?? .flattened }
        set { saveModeRaw = newValue.rawValue }
    }
}
