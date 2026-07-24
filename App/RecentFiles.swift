// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import Foundation

final class RecentFiles: ObservableObject {
    static let shared = RecentFiles()

    private let key = "recentFiles"

    @Published var urls: [URL] = []

    /// True while the process is hosting an XCTest run.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private init() {
        // Under `xcodebuild test` the app itself is the test host, so its UI
        // launches too: the welcome screen would build thumbnails for the real
        // recent files and macOS would put up a "would like to access files in
        // your Downloads folder" prompt in the middle of the run. Tests have no
        // business reading the user's documents.
        guard !Self.isRunningTests else { return }
        load()
    }

    func add(_ url: URL) {
        guard !Self.isRunningTests else { return }
        var list = urls
        list.removeAll { $0 == url }
        list.insert(url, at: 0)
        let limit = AppSettings.shared.maxRecentItems
        if list.count > limit { list = Array(list.prefix(limit)) }
        urls = list
        persist()
    }

    func clear() {
        urls.removeAll()
        persist()
    }

    func trim(to limit: Int) {
        if urls.count > limit {
            urls = Array(urls.prefix(limit))
            persist()
        }
    }

    private func load() {
        guard let paths = UserDefaults.standard.array(forKey: key) as? [String] else { return }
        urls = paths.map { URL(fileURLWithPath: $0) }
    }

    private func persist() {
        let paths = urls.map { $0.path }
        UserDefaults.standard.set(paths, forKey: key)
    }
}
