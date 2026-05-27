// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit

enum InitialZoom: String, CaseIterable, Identifiable, Codable {
    case fit, actual, fill
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "Incadrare in fereastra"
        case .actual: return "Marime reala (100%)"
        case .fill: return "Umple fereastra"
        }
    }
}

final class CanvasNSView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image else { return }
        let imgSize = img.size
        let rect = NSRect(
            x: (bounds.width - imgSize.width) / 2,
            y: (bounds.height - imgSize.height) / 2,
            width: imgSize.width,
            height: imgSize.height
        )

        // Subtle shadow under image (workspace feel)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -3),
                          blur: 12,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            NSColor.white.setFill()
            rect.fill()
            ctx.restoreGState()
        }

        img.draw(in: rect,
                 from: .zero,
                 operation: .sourceOver,
                 fraction: 1.0,
                 respectFlipped: true,
                 hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}

struct ImageCanvasView: NSViewRepresentable {
    let image: NSImage?
    @Binding var zoom: CGFloat
    let initialZoomMode: InitialZoom

    final class Coordinator {
        var didInitialFit = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 32
        scroll.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
        scroll.drawsBackground = true
        scroll.borderType = .noBorder

        let canvas = CanvasNSView()
        canvas.image = image
        canvas.frame = canvasFrame(for: image, in: scroll.contentView.bounds.size)
        scroll.documentView = canvas

        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { _ in
            zoom = scroll.magnification
        }
        NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scroll,
            queue: .main
        ) { _ in
            zoom = scroll.magnification
        }
        scroll.contentView.postsBoundsChangedNotifications = true

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? CanvasNSView else { return }
        if canvas.image !== image {
            canvas.image = image
            canvas.frame = canvasFrame(for: image, in: scroll.contentView.bounds.size)
            context.coordinator.didInitialFit = false
        }

        if !context.coordinator.didInitialFit, let img = image {
            context.coordinator.didInitialFit = true
            DispatchQueue.main.async {
                applyInitialZoomAndCenter(scroll: scroll, image: img)
            }
        } else if abs(scroll.magnification - zoom) > 0.001 {
            scroll.magnification = zoom
        }
    }

    private func canvasFrame(for image: NSImage?, in viewport: CGSize) -> NSRect {
        let imgSize = image?.size ?? .zero
        // Large canvas so user can pan image anywhere in workspace
        let pad = max(viewport.width, viewport.height, max(imgSize.width, imgSize.height)) * 1.5
        let w = imgSize.width + pad * 2
        let h = imgSize.height + pad * 2
        return NSRect(x: 0, y: 0, width: max(w, 800), height: max(h, 600))
    }

    private func applyInitialZoomAndCenter(scroll: NSScrollView, image: NSImage) {
        let viewport = scroll.contentView.bounds.size
        let imgSize = image.size
        guard viewport.width > 0, viewport.height > 0,
              imgSize.width > 0, imgSize.height > 0 else { return }

        let fit = min(viewport.width / imgSize.width, viewport.height / imgSize.height)
        let fill = max(viewport.width / imgSize.width, viewport.height / imgSize.height)

        let mag: CGFloat
        switch initialZoomMode {
        case .fit: mag = min(1.0, fit)
        case .actual: mag = 1.0
        case .fill: mag = fill
        }
        scroll.magnification = mag
        zoom = mag

        // Center on image (image is drawn centered in canvas bounds)
        guard let canvas = scroll.documentView else { return }
        let canvasCenter = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let visible = scroll.contentView.bounds.size
        let origin = NSPoint(
            x: canvasCenter.x - visible.width / 2,
            y: canvasCenter.y - visible.height / 2
        )
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
