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

    /// What is stored: the stack, plus the identity of the file it was
    /// taken against. A stack only describes the pixels it was made on; if the
    /// file was replaced, edited elsewhere or flattened since, applying it
    /// would crop or rotate a different image.
    struct Payload: Codable {
        var version: Int = 2
        var stack: EditStack
        var fileSize: Int?
        var fileModified: Date?
    }

    static func identity(of url: URL) -> (size: Int?, modified: Date?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int, attrs?[.modificationDate] as? Date)
    }

    /// The autosaved stack for `url`, or nil when there is none or it was
    /// taken against a different version of the file.
    ///
    /// Autosaves written before v0.3.0 carry no identity and are ignored: the
    /// versions that wrote them re-applied stacks onto already-edited files,
    /// so they cannot be trusted to describe the pixels on disk.
    func load(for url: URL) -> EditStack? {
        let f = file(for: url)
        guard let data = try? Data(contentsOf: f),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version >= 2
        else { return nil }
        let now = Self.identity(of: url)
        guard let size = payload.fileSize, size == now.size,
              let then = payload.fileModified, let mod = now.modified,
              abs(then.timeIntervalSince(mod)) < 1
        else { return nil }
        return payload.stack
    }

    func save(_ stack: EditStack, for url: URL) {
        let id = Self.identity(of: url)
        let payload = Payload(stack: stack, fileSize: id.size, fileModified: id.modified)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: file(for: url), options: .atomic)
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
