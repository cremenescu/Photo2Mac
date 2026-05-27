// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit

struct ImageCanvasView: NSViewRepresentable {
    let image: NSImage?
    @Binding var zoom: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 32
        scroll.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
        scroll.drawsBackground = true

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        if let img = image {
            imageView.frame = NSRect(origin: .zero, size: img.size)
        }
        scroll.documentView = imageView

        DispatchQueue.main.async {
            if let img = image {
                let viewSize = scroll.contentView.bounds.size
                if viewSize.width > 0 && viewSize.height > 0 {
                    let fit = min(viewSize.width / img.size.width,
                                  viewSize.height / img.size.height)
                    scroll.magnification = max(0.05, min(1.0, fit))
                    zoom = scroll.magnification
                }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let iv = scroll.documentView as? NSImageView {
            if iv.image !== image {
                iv.image = image
                if let img = image {
                    iv.frame = NSRect(origin: .zero, size: img.size)
                }
            }
        }
        if abs(scroll.magnification - zoom) > 0.001 {
            scroll.magnification = zoom
        }
    }
}
