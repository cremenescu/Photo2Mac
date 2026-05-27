// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("initialZoomMode") var initialZoomModeRaw: String = InitialZoom.fit.rawValue
    @AppStorage("maxRecentItems") var maxRecentItems: Int = 10

    var initialZoomMode: InitialZoom {
        get { InitialZoom(rawValue: initialZoomModeRaw) ?? .fit }
        set { initialZoomModeRaw = newValue.rawValue }
    }
}
