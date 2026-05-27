// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import ImageIO

extension UTType {
    static let photo2macSupported: [UTType] = [
        .jpeg, .png, .heic, .heif, .tiff, .webP,
        UTType("public.avif") ?? .image
    ]
}

final class PhotoDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    static var readableContentTypes: [UTType] { UTType.photo2macSupported }
    static var writableContentTypes: [UTType] { UTType.photo2macSupported }

    @Published var image: NSImage?
    @Published var sourceData: Data?
    @Published var sourceUTI: UTType = .jpeg

    @Published var stack = EditStack()

    init() {}

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.sourceData = data
        self.sourceUTI = configuration.contentType
        guard let img = NSImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.image = img
        self.stack = EditStack.readFromXMP(in: data) ?? EditStack()
    }

    func snapshot(contentType: UTType) throws -> Data {
        return sourceData ?? Data()
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: snapshot)
    }
}

struct EditStack: Codable, Equatable {
    var operations: [EditOperation] = []

    static func readFromXMP(in data: Data) -> EditStack? {
        return nil
    }
}

enum EditOperation: Codable, Equatable {
    case crop(x: Double, y: Double, w: Double, h: Double)
    case rotate(degrees: Int)
    case flipHorizontal
    case flipVertical
    case adjustments(brightness: Double, contrast: Double, saturation: Double, exposure: Double)
}
