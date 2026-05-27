// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit

/// Loads bundled Iconify SVG (Phosphor set) and renders as template image
/// so SwiftUI .foregroundStyle / .tint colors it like an SF Symbol.
struct IconifyImage: View {
    let name: String
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: makeImage())
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private func makeImage() -> NSImage {
        if let url = Bundle.main.url(forResource: name, withExtension: "svg",
                                     subdirectory: "Icons")
            ?? Bundle.main.url(forResource: name, withExtension: "svg") {
            if let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                return img
            }
        }
        // Fallback: SF Symbol with similar meaning
        return NSImage(systemSymbolName: "questionmark.square",
                       accessibilityDescription: name) ?? NSImage()
    }
}
