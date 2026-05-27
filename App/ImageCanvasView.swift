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
    var panEnabled: Bool = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var onUserInteract: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var lastDragWindowPoint: NSPoint?
    private var isDragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited,
                      .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func cursorUpdate(with event: NSEvent) {
        if isDragging {
            NSCursor.closedHand.set()
        } else if panEnabled {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if isDragging {
            NSCursor.closedHand.set()
        } else if panEnabled {
            NSCursor.openHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard panEnabled else { return }
        isDragging = true
        NSCursor.closedHand.set()
        lastDragWindowPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard panEnabled,
              let last = lastDragWindowPoint,
              let scroll = enclosingScrollView else { return }
        // Keep closed-hand cursor pinned through the drag; tracking-area
        // cursorUpdate runs constantly and would otherwise reset it to openHand.
        NSCursor.closedHand.set()
        let current = event.locationInWindow
        let dx = current.x - last.x
        let dy = current.y - last.y
        let mag = scroll.magnification == 0 ? 1 : scroll.magnification

        // Window coords: y is up-positive. Flipped clipView origin: y down-positive.
        // Mouse moves right (dx>0) => image follows right => viewport reveals content
        //   to the left => origin.x decreases.
        // Mouse moves up (dy>0)    => image follows up    => viewport reveals content
        //   above => in flipped doc coords (y down), "above" = smaller y => origin.y
        //   decreases. Since dy>0 here, we want origin.y -= dy. WAIT: in flipped
        //   clipView, origin.y INCREASES as we scroll down. So scrolling up = origin.y
        //   DECREASES. Mouse up (dy>0 in window coords) wants image follow up = scroll
        //   up = origin.y -= dy. But because of the flip, contentView.bounds.origin.y
        //   semantics already accounts for flip => actually subtracting dy is wrong;
        //   we need to ADD dy because clipView origin in flipped doc has opposite
        //   direction to window y.
        var origin = scroll.contentView.bounds.origin
        origin.x -= dx / mag
        origin.y += dy / mag
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        lastDragWindowPoint = current
        onUserInteract?()
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        lastDragWindowPoint = nil
        if panEnabled, let win = window,
           NSPointInRect(win.mouseLocationOutsideOfEventStream, convert(bounds, to: nil)) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image else { return }
        let imgSize = img.size
        let rect = NSRect(
            x: (bounds.width - imgSize.width) / 2,
            y: (bounds.height - imgSize.height) / 2,
            width: imgSize.width,
            height: imgSize.height
        )

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

final class CanvasScrollView: NSScrollView {
    var onResize: (() -> Void)?
    private var lastReportedSize: NSSize = .zero

    private func reportIfChanged() {
        if frame.size != lastReportedSize, frame.size.width > 0, frame.size.height > 0 {
            lastReportedSize = frame.size
            onResize?()
        }
    }

    override func tile() {
        super.tile()
        reportIfChanged()
    }

    override func layout() {
        super.layout()
        reportIfChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportIfChanged()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        reportIfChanged()
    }
}

struct ImageCanvasView: NSViewRepresentable {
    let image: NSImage
    @Binding var zoom: CGFloat
    let initialZoomMode: InitialZoom
    let tool: EditorTool
    let documentID: UUID
    let viewportSize: CGSize
    /// Bumped by the toolbar's "View" menu to force a re-fit on demand.
    let forceFitNonce: Int

    final class Coordinator {
        var fittedDocumentID: UUID?
        var lastDocumentID: UUID?
        var userInteracted = false
        var lastViewportSize: CGSize = .zero
        var lastForceFitNonce: Int = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CanvasScrollView()
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
        canvas.panEnabled = (tool == .hand)
        canvas.frame = canvasFrame(for: image, in: scroll.contentView.bounds.size)
        canvas.onUserInteract = { [weak coord = context.coordinator] in
            coord?.userInteracted = true
        }
        scroll.documentView = canvas

        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true

        NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification,
            object: scroll,
            queue: .main
        ) { _ in
            zoom = scroll.magnification
            context.coordinator.userInteracted = true
        }

        // Auto re-fit / re-center on viewport resize until user manually interacts.
        scroll.onResize = { [weak scroll] in
            guard let scroll = scroll else { return }
            if !context.coordinator.userInteracted {
                applyInitialFit(scroll: scroll)
            } else {
                ensureImageVisible(scroll: scroll)
            }
        }

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? CanvasNSView else { return }

        canvas.panEnabled = (tool == .hand)

        let docChanged = context.coordinator.lastDocumentID != documentID
        context.coordinator.lastDocumentID = documentID

        if canvas.image !== image {
            canvas.image = image
            // Only refit frame + state if it's actually a new document.
            // A re-render of the same document (slider tick) keeps zoom & pan.
            if docChanged {
                canvas.frame = canvasFrame(for: image, in: scroll.contentView.bounds.size)
                context.coordinator.fittedDocumentID = nil
                context.coordinator.userInteracted = false
            }
        }

        let viewportChanged = abs(context.coordinator.lastViewportSize.width - viewportSize.width) > 0.5 ||
                              abs(context.coordinator.lastViewportSize.height - viewportSize.height) > 0.5
        context.coordinator.lastViewportSize = viewportSize

        let forceFit = forceFitNonce != context.coordinator.lastForceFitNonce
        context.coordinator.lastForceFitNonce = forceFitNonce

        if context.coordinator.fittedDocumentID != documentID {
            scheduleInitialFit(scroll: scroll, coordinator: context.coordinator)
        } else if forceFit {
            DispatchQueue.main.async {
                context.coordinator.userInteracted = false
                applyInitialFit(scroll: scroll)
            }
        } else if viewportChanged {
            // SwiftUI told us the viewport changed (window resize, splitter drag).
            DispatchQueue.main.async {
                if !context.coordinator.userInteracted {
                    applyInitialFit(scroll: scroll)
                } else {
                    ensureImageVisible(scroll: scroll)
                }
            }
        } else if abs(scroll.magnification - zoom) > 0.001 {
            scroll.magnification = zoom
            context.coordinator.userInteracted = true
        }
    }

    private func scheduleInitialFit(scroll: NSScrollView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            let viewport = scroll.contentView.bounds.size
            if viewport.width < 2 || viewport.height < 2 {
                // Layout not ready yet — retry on next runloop turn.
                scheduleInitialFit(scroll: scroll, coordinator: coordinator)
                return
            }
            applyInitialFit(scroll: scroll)
            coordinator.fittedDocumentID = documentID
        }
    }

    private func canvasFrame(for image: NSImage, in viewport: CGSize) -> NSRect {
        let imgSize = image.size
        let pad = max(2000,
                      max(viewport.width, viewport.height) * 2,
                      max(imgSize.width, imgSize.height))
        let w = imgSize.width + pad * 2
        let h = imgSize.height + pad * 2
        return NSRect(x: 0, y: 0, width: w, height: h)
    }

    private func applyInitialFit(scroll: NSScrollView) {
        let viewportPoints = scroll.frame.size
        let imgSize = image.size
        guard viewportPoints.width > 0, viewportPoints.height > 0,
              imgSize.width > 0, imgSize.height > 0 else { return }

        // viewportPoints is screen-space (independent of magnification).
        let fitMag = min(viewportPoints.width / imgSize.width,
                         viewportPoints.height / imgSize.height)
        let fillMag = max(viewportPoints.width / imgSize.width,
                          viewportPoints.height / imgSize.height)

        let mag: CGFloat
        switch initialZoomMode {
        case .fit: mag = min(1.0, fitMag)
        case .actual: mag = 1.0
        case .fill: mag = fillMag
        }
        scroll.magnification = mag
        zoom = mag

        guard let canvas = scroll.documentView else { return }
        // After setting magnification, contentView.bounds.size is in doc coords
        // (= viewport / mag). Center on canvas mid.
        let visible = scroll.contentView.bounds.size
        let canvasCenter = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let origin = NSPoint(
            x: canvasCenter.x - visible.width / 2,
            y: canvasCenter.y - visible.height / 2
        )
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func ensureImageVisible(scroll: NSScrollView) {
        guard let canvas = scroll.documentView else { return }
        let visible = scroll.contentView.bounds
        let imgSize = image.size
        let imgRect = NSRect(
            x: (canvas.bounds.width - imgSize.width) / 2,
            y: (canvas.bounds.height - imgSize.height) / 2,
            width: imgSize.width,
            height: imgSize.height
        )
        if !visible.intersects(imgRect) {
            // Image fully scrolled out of view — bring it back to center.
            let origin = NSPoint(
                x: imgRect.midX - visible.width / 2,
                y: imgRect.midY - visible.height / 2
            )
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
