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
        NSCursor.closedHand.set()
        let current = event.locationInWindow
        let dx = current.x - last.x
        let dy = current.y - last.y
        let mag = scroll.magnification == 0 ? 1 : scroll.magnification

        // See sign rationale in commit history. y is flipped between window
        // (up positive) and the clipView (down positive after isFlipped doc).
        var origin = scroll.contentView.bounds.origin
        origin.x -= dx / mag
        origin.y += dy / mag

        // scroll(to:) on NSClipView bypasses constrainBoundsRect, so call it
        // manually for clamping.
        let proposed = NSRect(origin: origin, size: scroll.contentView.bounds.size)
        let clamped = scroll.contentView.constrainBoundsRect(proposed)
        scroll.contentView.scroll(to: clamped.origin)
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

/// ClipView that clamps the scroll origin so the image always intersects
/// the viewport by at least `minOverlap` on each axis. Applies uniformly to
/// trackpad scroll, mouse drag pan, and programmatic scrolls.
final class CanvasClipView: NSClipView {
    /// Image rect in document (canvas) coordinates. Set by the canvas.
    var imageRect: CGRect = .zero

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard imageRect.width > 0, imageRect.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        // We want a consistent visible overlap regardless of zoom, so express
        // the minimum overlap in screen points and convert to doc-points.
        let mag = enclosingScrollView?.magnification ?? 1.0
        let minOverlapScreen: CGFloat = 80
        let minOverlapDoc = minOverlapScreen / max(mag, 0.0001)
        let minSide = min(imageRect.width, imageRect.height)
        // Cap at half the smaller side so it never exceeds image dimensions.
        let overlap = min(minOverlapDoc, minSide * 0.5)

        let maxX = imageRect.maxX - overlap
        let minX = imageRect.minX + overlap - bounds.width
        let maxY = imageRect.maxY - overlap
        let minY = imageRect.minY + overlap - bounds.height

        // If image fits entirely (viewport bigger than image with the overlap
        // requirement), keep image visible by clamping origin so image rect is
        // wholly inside the viewport.
        bounds.origin.x = (minX <= maxX) ? max(minX, min(maxX, bounds.origin.x)) : bounds.origin.x
        bounds.origin.y = (minY <= maxY) ? max(minY, min(maxY, bounds.origin.y)) : bounds.origin.y
        return bounds
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
    /// When true, every viewport resize re-applies the current zoom mode
    /// even if the user has manually panned/zoomed.
    let alwaysRefitOnResize: Bool

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

        // Replace the default clipView with our clamping one.
        let clamping = CanvasClipView()
        clamping.drawsBackground = true
        clamping.backgroundColor = scroll.backgroundColor
        scroll.contentView = clamping

        let canvas = CanvasNSView()
        canvas.image = image
        canvas.panEnabled = (tool == .hand)
        let cFrame = canvasFrame(for: image, in: scroll.contentView.bounds.size)
        canvas.frame = cFrame
        updateImageRect(clipView: clamping, canvasFrame: cFrame, image: image)
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
                let cFrame = canvasFrame(for: image, in: scroll.contentView.bounds.size)
                canvas.frame = cFrame
                if let clip = scroll.contentView as? CanvasClipView {
                    updateImageRect(clipView: clip, canvasFrame: cFrame, image: image)
                }
                context.coordinator.fittedDocumentID = nil
                context.coordinator.userInteracted = false
            } else if let clip = scroll.contentView as? CanvasClipView {
                // Same document, possibly re-rendered with different geometry
                // (e.g. crop applied later). Update image rect.
                updateImageRect(clipView: clip, canvasFrame: canvas.frame, image: image)
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
                if alwaysRefitOnResize || !context.coordinator.userInteracted {
                    if alwaysRefitOnResize {
                        context.coordinator.userInteracted = false
                    }
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
        // With CanvasClipView's constrainBoundsRect, the image is always at
        // least minOverlap visible. Re-tickle the clipView so it re-clamps
        // its current origin under the new viewport size.
        let origin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func updateImageRect(clipView: CanvasClipView,
                                  canvasFrame: NSRect,
                                  image: NSImage) {
        let imgSize = image.size
        clipView.imageRect = NSRect(
            x: (canvasFrame.width - imgSize.width) / 2,
            y: (canvasFrame.height - imgSize.height) / 2,
            width: imgSize.width,
            height: imgSize.height
        )
    }
}
