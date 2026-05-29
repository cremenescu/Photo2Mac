// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit
import Combine

enum InitialZoom: String, CaseIterable, Identifiable, Codable {
    case fit, actual, fill
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return t("Incadrare in fereastra")
        case .actual: return t("Marime reala (100%)")
        case .fill: return t("Umple fereastra")
        }
    }
}

final class CanvasNSView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var panEnabled: Bool = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    /// When non-nil, draw a crop overlay and forward drags to the crop edit state.
    var cropEditState: CropEditState? {
        didSet {
            cropStateObservation?.cancel()
            cropStateObservation = nil
            if let s = cropEditState {
                // Re-draw on ANY change to the crop state (rect or aspect).
                // Without this, picking a new aspect ratio mutates `rect`
                // via applyAspect but the canvas doesn't know to redraw.
                cropStateObservation = s.objectWillChange.sink { [weak self] _ in
                    DispatchQueue.main.async { self?.needsDisplay = true }
                }
            }
            needsDisplay = true
        }
    }
    private var cropStateObservation: AnyCancellable?
    /// Where the image (and so the crop overlay) is drawn within canvas bounds.
    private var imageDrawRect: CGRect = .zero

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var onUserInteract: (() -> Void)?

    /// True only while the Rotate tool is active. Gates the two-finger
    /// trackpad rotation gesture so it never fires in other tools.
    var rotationEnabled: Bool = false
    /// Reports an incremental rotation delta (clockwise-positive degrees)
    /// from the trackpad rotate gesture.
    var onRotate: ((CGFloat) -> Void)?

    /// Two-finger trackpad rotate. `event.rotation` is the per-event delta in
    /// degrees, positive = counterclockwise (AppKit). Our model angle is
    /// clockwise-positive, so we negate. Only active in the Rotate tool;
    /// otherwise forward so we don't swallow the gesture.
    override func rotate(with event: NSEvent) {
        guard rotationEnabled, let onRotate = onRotate else {
            super.rotate(with: event)
            return
        }
        onUserInteract?()
        onRotate(-CGFloat(event.rotation))
    }

    private var trackingArea: NSTrackingArea?
    private var lastDragWindowPoint: NSPoint?
    private var isDragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited,
                      .mouseMoved, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    /// Movement within the tracking area: re-evaluate cursor so the user sees
    /// the right shape (resize arrows, openHand, crosshair) as they hover
    /// across handles, edges, and the interior of the crop rect.
    override func mouseMoved(with event: NSEvent) {
        if isDragging { return }
        if let crop = cropEditState {
            let p = convert(event.locationInWindow, from: nil)
            if let handle = cropHandleHitTest(at: p, crop: crop) {
                cursorForCropHandle(handle).set()
                return
            }
        }
        if panEnabled {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        // Mid-drag: the cursor was selected at mouseDown and should stay.
        if isDragging { return }

        // In crop mode, show the handle-appropriate resize cursor when
        // hovering over a handle or the interior. This wins over pan cursor.
        if let crop = cropEditState {
            let p = convert(event.locationInWindow, from: nil)
            if let handle = cropHandleHitTest(at: p, crop: crop) {
                cursorForCropHandle(handle).set()
                return
            }
        }

        if panEnabled {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        cursorUpdate(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging { NSCursor.arrow.set() }
    }

    /// Cursor for a crop handle. macOS 14 exposes resizeUpDown / resizeLeftRight
    /// as public NSCursors. The diagonal cursors aren't in the public API but
    /// the AppKit class exposes them as private class methods that have been
    /// stable for years — we resolve them via NSSelectorFromString and fall
    /// back to crosshair if they're ever removed.
    private func cursorForCropHandle(_ h: CropHandle) -> NSCursor {
        switch h {
        case .interior:           return NSCursor.openHand
        case .topMid, .bottomMid: return NSCursor.resizeUpDown
        case .midLeft, .midRight: return NSCursor.resizeLeftRight
        case .topLeft, .bottomRight:
            return Self.diagonalCursorNWSE ?? NSCursor.crosshair
        case .topRight, .bottomLeft:
            return Self.diagonalCursorNESW ?? NSCursor.crosshair
        }
    }

    private static let diagonalCursorNWSE: NSCursor? =
        privateCursor("_windowResizeNorthWestSouthEastCursor")
    private static let diagonalCursorNESW: NSCursor? =
        privateCursor("_windowResizeNorthEastSouthWestCursor")

    private static func privateCursor(_ name: String) -> NSCursor? {
        let sel = NSSelectorFromString(name)
        let obj: AnyObject = NSCursor.self
        guard obj.responds(to: sel) else { return nil }
        // Call the (class) method via NSObject's perform on the metaclass.
        let unmanaged: Unmanaged<AnyObject>? = obj.perform(sel)
        return unmanaged?.takeUnretainedValue() as? NSCursor
    }

    override func mouseDown(with event: NSEvent) {
        // Crop mode: intercept clicks if they hit the crop UI.
        if let crop = cropEditState {
            let p = convert(event.locationInWindow, from: nil)
            if let handle = cropHandleHitTest(at: p, crop: crop) {
                activeCropHandle = handle
                dragStartCropRect = crop.rect
                dragStartCanvasPoint = p
                // Closed-hand for interior drag, directional resize for handles.
                if handle == .interior {
                    NSCursor.closedHand.set()
                } else {
                    cursorForCropHandle(handle).set()
                }
                isDragging = true
                return
            }
        }
        guard panEnabled else { return }
        isDragging = true
        NSCursor.closedHand.set()
        lastDragWindowPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        // Crop drag — takes priority.
        if let crop = cropEditState, let handle = activeCropHandle {
            let p = convert(event.locationInWindow, from: nil)
            applyCropDrag(handle: handle, currentCanvasPoint: p, crop: crop)
            return
        }
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
        if activeCropHandle != nil {
            activeCropHandle = nil
            isDragging = false
            NSCursor.crosshair.set()
            return
        }
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
        imageDrawRect = rect

        // Draw the image with a drop shadow cast by its own (possibly rotated)
        // silhouette. We must NOT fill a white rectangle behind it: when the
        // image is rotated by a free angle its bounding box has transparent
        // corners, and a white backing would show through as white triangles.
        // Applying the shadow to the image draw makes the shadow follow the
        // real, tilted shape and leaves the corners transparent (canvas shows
        // through).
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -3),
                          blur: 12,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            img.draw(in: rect,
                     from: .zero,
                     operation: .sourceOver,
                     fraction: 1.0,
                     respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
            ctx.restoreGState()
        } else {
            img.draw(in: rect,
                     from: .zero,
                     operation: .sourceOver,
                     fraction: 1.0,
                     respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }

        if let crop = cropEditState {
            drawCropOverlay(crop: crop, in: rect)
        }
    }

    private func drawCropOverlay(crop: CropEditState, in imgRect: CGRect) {
        // Crop rect in canvas coords (the image inside CanvasNSView is drawn
        // 1:1, so crop pixel coords map directly into imgRect with offset).
        let cr = canvasRect(forImageRect: crop.rect, in: imgRect)

        // Dim mask outside the crop.
        let outside = NSBezierPath(rect: imgRect)
        outside.append(NSBezierPath(rect: cr).reversed)
        NSColor(white: 0, alpha: 0.5).setFill()
        outside.fill()

        // Crop border.
        let borderColor = NSColor.white
        borderColor.setStroke()
        let border = NSBezierPath(rect: cr)
        border.lineWidth = 1.5
        border.stroke()

        // Rule-of-thirds guides.
        NSColor(white: 1, alpha: 0.4).setStroke()
        let thirds = NSBezierPath()
        thirds.lineWidth = 0.75
        for i in 1...2 {
            let x = cr.minX + cr.width * CGFloat(i) / 3.0
            thirds.move(to: NSPoint(x: x, y: cr.minY))
            thirds.line(to: NSPoint(x: x, y: cr.maxY))
            let y = cr.minY + cr.height * CGFloat(i) / 3.0
            thirds.move(to: NSPoint(x: cr.minX, y: y))
            thirds.line(to: NSPoint(x: cr.maxX, y: y))
        }
        thirds.stroke()

        // Corner handles (bigger) and edge mid handles (smaller).
        NSColor.white.setFill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let corners: [CropHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let edges:   [CropHandle] = [.topMid, .bottomMid, .midLeft, .midRight]
        for h in corners {
            let center = handleCenter(h, in: cr)
            let s: CGFloat = 12
            let r = NSRect(x: center.x - s / 2, y: center.y - s / 2,
                           width: s, height: s)
            let p = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            p.fill()
            p.lineWidth = 1
            p.stroke()
        }
        for h in edges {
            let center = handleCenter(h, in: cr)
            // Edge handles drawn as a small pill perpendicular to their axis.
            let isHorizontal = (h == .topMid || h == .bottomMid)
            let w: CGFloat = isHorizontal ? 24 : 8
            let hgt: CGFloat = isHorizontal ? 8 : 24
            let r = NSRect(x: center.x - w / 2, y: center.y - hgt / 2,
                           width: w, height: hgt)
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            p.fill()
            p.lineWidth = 1
            p.stroke()
        }
    }

    private func canvasRect(forImageRect ir: CGRect, in imgRect: CGRect) -> CGRect {
        // ir is in image-pixel coords (origin top-left of image, y-down).
        return CGRect(x: imgRect.minX + ir.minX,
                      y: imgRect.minY + ir.minY,
                      width: ir.width,
                      height: ir.height)
    }

    private func handleCenter(_ h: CropHandle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft:     return CGPoint(x: r.minX, y: r.minY)
        case .topMid:      return CGPoint(x: r.midX, y: r.minY)
        case .topRight:    return CGPoint(x: r.maxX, y: r.minY)
        case .midLeft:     return CGPoint(x: r.minX, y: r.midY)
        case .midRight:    return CGPoint(x: r.maxX, y: r.midY)
        case .bottomLeft:  return CGPoint(x: r.minX, y: r.maxY)
        case .bottomMid:   return CGPoint(x: r.midX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .interior:    return CGPoint(x: r.midX, y: r.midY)
        }
    }

    private var activeCropHandle: CropHandle?
    private var dragStartCropRect: CGRect = .zero
    private var dragStartCanvasPoint: CGPoint = .zero

    private func cropHandleHitTest(at point: CGPoint, crop: CropEditState) -> CropHandle? {
        let cr = canvasRect(forImageRect: crop.rect, in: imageDrawRect)
        // Test corners first (priority over edges), then edges.
        let hitR: CGFloat = 18
        let order: [CropHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight,
                                    .topMid, .bottomMid, .midLeft, .midRight]
        for h in order {
            let c = handleCenter(h, in: cr)
            if abs(point.x - c.x) <= hitR && abs(point.y - c.y) <= hitR {
                return h
            }
        }
        if cr.contains(point) { return .interior }
        return nil
    }

    private func applyCropDrag(handle: CropHandle, currentCanvasPoint p: CGPoint,
                                crop: CropEditState) {
        let dx = p.x - dragStartCanvasPoint.x
        let dy = p.y - dragStartCanvasPoint.y
        let imgSize = crop.imageSize
        let minSize: CGFloat = 16

        var r = dragStartCropRect
        let aspect = crop.aspect.ratio(imageSize: imgSize)

        switch handle {
        case .interior:
            r.origin.x += dx
            r.origin.y += dy
            r.origin.x = max(0, min(imgSize.width - r.width, r.origin.x))
            r.origin.y = max(0, min(imgSize.height - r.height, r.origin.y))

        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // Anchor = opposite corner.
            let anchor: CGPoint
            switch handle {
            case .topLeft:     anchor = CGPoint(x: r.maxX, y: r.maxY)
            case .topRight:    anchor = CGPoint(x: r.minX, y: r.maxY)
            case .bottomLeft:  anchor = CGPoint(x: r.maxX, y: r.minY)
            case .bottomRight: anchor = CGPoint(x: r.minX, y: r.minY)
            default: anchor = .zero
            }
            // Free corner = drag-point + delta.
            var freeX: CGFloat
            var freeY: CGFloat
            switch handle {
            case .topLeft:     freeX = r.minX + dx; freeY = r.minY + dy
            case .topRight:    freeX = r.maxX + dx; freeY = r.minY + dy
            case .bottomLeft:  freeX = r.minX + dx; freeY = r.maxY + dy
            case .bottomRight: freeX = r.maxX + dx; freeY = r.maxY + dy
            default: freeX = 0; freeY = 0
            }
            // Clamp to image bounds.
            freeX = max(0, min(imgSize.width, freeX))
            freeY = max(0, min(imgSize.height, freeY))

            var w = abs(freeX - anchor.x)
            var h = abs(freeY - anchor.y)

            if let aspect, aspect > 0 {
                // Pick whichever candidate keeps the user feeling natural:
                // the one whose ratio is closer to or above the target wins.
                let wFromH = h * aspect
                if wFromH > w { w = wFromH } else { h = w / aspect }
                // Also clamp so anchored corner doesn't push past image bounds.
                // Determine sign of expansion from anchor.
                let dirX: CGFloat = freeX >= anchor.x ? 1 : -1
                let dirY: CGFloat = freeY >= anchor.y ? 1 : -1
                let maxW = dirX > 0 ? imgSize.width - anchor.x : anchor.x
                let maxH = dirY > 0 ? imgSize.height - anchor.y : anchor.y
                if w > maxW { w = maxW; h = w / aspect }
                if h > maxH { h = maxH; w = h * aspect }
                w = max(minSize, w)
                h = max(minSize, h)
                let signX: CGFloat = dirX
                let signY: CGFloat = dirY
                let newFreeX = anchor.x + signX * w
                let newFreeY = anchor.y + signY * h
                r = CGRect(x: min(anchor.x, newFreeX),
                           y: min(anchor.y, newFreeY),
                           width: w, height: h)
            } else {
                w = max(minSize, w)
                h = max(minSize, h)
                r = CGRect(x: min(anchor.x, freeX),
                           y: min(anchor.y, freeY),
                           width: w, height: h)
            }

        case .topMid:
            let newMinY = max(0, min(r.maxY - minSize, r.minY + dy))
            r = CGRect(x: r.minX, y: newMinY,
                       width: r.width, height: r.maxY - newMinY)
        case .bottomMid:
            let newMaxY = max(r.minY + minSize, min(imgSize.height, r.maxY + dy))
            r = CGRect(x: r.minX, y: r.minY,
                       width: r.width, height: newMaxY - r.minY)
        case .midLeft:
            let newMinX = max(0, min(r.maxX - minSize, r.minX + dx))
            r = CGRect(x: newMinX, y: r.minY,
                       width: r.maxX - newMinX, height: r.height)
        case .midRight:
            let newMaxX = max(r.minX + minSize, min(imgSize.width, r.maxX + dx))
            r = CGRect(x: r.minX, y: r.minY,
                       width: newMaxX - r.minX, height: r.height)
        }

        crop.rect = r
        needsDisplay = true
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
    /// Active crop editing state, or nil if not in crop mode.
    let cropEditState: CropEditState?
    /// Called with an incremental clockwise-positive degree delta from the
    /// trackpad two-finger rotate gesture (only while the Rotate tool is on).
    var onRotate: ((CGFloat) -> Void)? = nil

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
        // Pinch-zoom competes physically with the two-finger rotate gesture
        // (fingers that rotate also pinch slightly), so turn magnification off
        // while the Rotate tool is active. Re-enabled in updateNSView.
        scroll.allowsMagnification = (tool != .rotate)
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
        canvas.rotationEnabled = (tool == .rotate)
        canvas.onRotate = onRotate
        canvas.cropEditState = cropEditState
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
        canvas.rotationEnabled = (tool == .rotate)
        canvas.onRotate = onRotate
        // Keep pinch-zoom out of the way of the rotate gesture.
        let wantMagnify = (tool != .rotate)
        if scroll.allowsMagnification != wantMagnify {
            scroll.allowsMagnification = wantMagnify
        }
        if canvas.cropEditState !== cropEditState {
            canvas.cropEditState = cropEditState
        }

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

        var mag: CGFloat
        switch initialZoomMode {
        case .fit: mag = min(1.0, fitMag)
        case .actual: mag = 1.0
        case .fill: mag = fillMag
        }
        // Leave margin around the image when in crop mode so corner handles
        // are easily reachable, not hugging the viewport edge.
        if cropEditState != nil {
            mag *= 0.9
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
