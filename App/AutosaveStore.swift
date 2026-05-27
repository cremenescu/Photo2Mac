// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import CryptoKit

/// Invisible per-image edit stack persistence, stored as JSON under
/// `~/Library/Application Support/Photo2Mac/autosave/<sha256(url)>.json`.
/// User never sees these files; they're crash-recovery + close-without-save
/// safety net. Cleared on explicit Save.
final class AutosaveStore {
    static let shared = AutosaveStore()

    let baseDir: URL

    init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        baseDir = support
            .appendingPathComponent("Photo2Mac", isDirectory: true)
            .appendingPathComponent("autosave", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: baseDir, withIntermediateDirectories: true)
    }

    /// Stable filename derived from the file's canonical path. Renaming the
    /// source file detaches its autosave (acceptable: a rename is "a new
    /// document" from our point of view).
    func file(for url: URL) -> URL {
        let key = sha256Hex(url.standardizedFileURL.path)
        return baseDir.appendingPathComponent(key + ".json")
    }

    func exists(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: file(for: url).path)
    }

    func mtime(for url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: file(for: url).path)
        return attrs?[.modificationDate] as? Date
    }

    func load(for url: URL) -> EditStack? {
        let f = file(for: url)
        guard let data = try? Data(contentsOf: f) else { return nil }
        return try? JSONDecoder().decode(EditStack.self, from: data)
    }

    func save(_ stack: EditStack, for url: URL) {
        let f = file(for: url)
        if stack.isNeutral {
            // Nothing to remember = no autosave file.
            clear(for: url)
            return
        }
        guard let data = try? JSONEncoder().encode(stack) else { return }
        try? data.write(to: f, options: .atomic)
    }

    func clear(for url: URL) {
        try? FileManager.default.removeItem(at: file(for: url))
    }

    private func sha256Hex(_ string: String) -> String {
        let data = Data(string.utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
