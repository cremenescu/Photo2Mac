// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import Foundation

/// Supported UI languages.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case auto, en, ro
    var id: String { rawValue }
    var bundleCode: String? {
        switch self {
        case .auto: return nil
        case .en:   return "en"
        case .ro:   return "ro"
        }
    }
    var nativeName: String {
        switch self {
        case .auto: return "Auto / System"
        case .en:   return "English"
        case .ro:   return "Română"
        }
    }
}

/// Owns the currently-active localization bundle and republishes when the
/// user switches language. Views observe this object and re-render via .id().
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var choice: AppLanguage {
        didSet {
            if choice != oldValue {
                UserDefaults.standard.set(choice.rawValue, forKey: "appLanguage")
                rebuildBundle()
            }
        }
    }

    /// The bundle to read NSLocalizedString from. Updated on language change.
    private(set) var bundle: Bundle = .main

    private init() {
        let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.auto.rawValue
        self.choice = AppLanguage(rawValue: raw) ?? .auto
        rebuildBundle()
    }

    private func rebuildBundle() {
        if let code = choice.bundleCode,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            self.bundle = b
        } else {
            self.bundle = .main
        }
    }
}

/// Localize a key through the LanguageManager-controlled bundle.
/// NSLocalizedString reads Bundle.main once at launch and cannot follow the
/// user's choice mid-session — going through `LanguageManager.shared.bundle`
/// lets us swap the language live.
func t(_ key: String, comment: String = "") -> String {
    LanguageManager.shared.bundle.localizedString(forKey: key, value: key, table: nil)
}

/// Formatted-string variant: t("%d edits", count).
func t(_ key: String, _ args: CVarArg..., comment: String = "") -> String {
    let format = LanguageManager.shared.bundle.localizedString(forKey: key, value: key, table: nil)
    return String(format: format, locale: Locale.current, arguments: args)
}
