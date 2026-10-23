// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import CoreGraphics
import AppKit
import CoreImage

enum CropAspect: String, CaseIterable, Identifiable {
    // Order matters: this is the order shown in the picker.
    case original, square, fourThree, threeFour, threeTwo, twoThree
    case sixteenNine, nineSixteen, free

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return t("Liber")
        case .original: return t("Original")
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeFour: return "3:4"
        case .threeTwo: return "3:2"
        case .twoThree: return "2:3"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }

    /// Returns the width / height ratio. nil if free.
    /// .original is resolved at the call site (uses the image's own ratio).
    func ratio(imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeFour: return 3.0 / 4.0
        case .threeTwo: return 3.0 / 2.0
        case .twoThree: return 2.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }
}

/// Live state of the crop tool while user is dragging handles.
/// `rect` is in IMAGE PIXEL coordinates of the IMAGE SHOWN WHILE EDITING —
/// which has flip + rotate + adjustments applied (so cropping happens on what
/// the user sees after orientation changes), but neither the crop nor the
/// final resize.
///
/// The document's stack is NOT touched while the tool is open: it keeps its
/// current crop until Apply, so saving or autosaving mid-crop writes the crop
/// the user already has instead of silently dropping it.
final class CropEditState: ObservableObject {
    @Published var rect: CGRect
    @Published var aspect: CropAspect = .original {
        didSet {
            if aspect != oldValue {
                applyAspect()
            }
        }
    }
    /// The crop in effect when the tool was opened, as it maps onto the
    /// current rotation; nil when the image was not cropped.
    let initialCrop: CropRect?
    /// Size of the image shown while editing (post-rotate / post-flip).
    let imageSize: CGSize
    /// Image to display behind the crop overlay.
    let preCropImage: NSImage

    init(preCropImage: NSImage, initialCrop: CropRect?) {
        let size = preCropImage.size
        self.preCropImage = preCropImage
        self.imageSize = size
        self.initialCrop = initialCrop
        if let c = initialCrop {
            self.rect = CGRect(x: c.x * size.width,
                               y: c.y * size.height,
                               width: c.width * size.width,
                               height: c.height * size.height)
        } else {
            self.rect = CGRect(origin: .zero, size: size)
        }
    }

    /// Render what the crop tool shows for `stack`. Slow for large photos;
    /// call it off the main thread.
    static func make(stack: EditStack, original: NSImage, sourceCI: CIImage?) -> CropEditState {
        var without = stack
        without.crop = nil
        without.resize = nil
        let pre = ImageRenderer.render(original: original, sourceCI: sourceCI, stack: without)
        let initial = EditGeometry.effectiveCrop(for: stack, sourceSize: original.size)
        return CropEditState(preCropImage: pre, initialCrop: initial)
    }

    /// True when the rect covers the whole image, i.e. applying it means
    /// "no crop".
    var coversWholeImage: Bool {
        let n = normalized
        return abs(n.x) < 0.001 && abs(n.y) < 0.001
            && abs(n.width - 1) < 0.001 && abs(n.height - 1) < 0.001
    }

    /// Whether the rect differs from the crop the tool was opened with.
    var hasChanges: Bool {
        let n = normalized
        let base = initialCrop ?? CropRect(x: 0, y: 0, width: 1, height: 1)
        let eps = 0.001
        return abs(n.x - base.x) > eps || abs(n.y - base.y) > eps
            || abs(n.width - base.width) > eps || abs(n.height - base.height) > eps
    }

    /// Normalized to image (0...1).
    var normalized: CropRect {
        CropRect(x: rect.minX / imageSize.width,
                 y: rect.minY / imageSize.height,
                 width: rect.width / imageSize.width,
                 height: rect.height / imageSize.height)
    }

    /// Adjust current rect to match new aspect (called when user changes the
    /// picker selection). Keep the rect centered on its current center.
    private func applyAspect() {
        guard let r = aspect.ratio(imageSize: imageSize), r > 0 else { return }
        let cx = rect.midX
        let cy = rect.midY
        // Start from current size, pick the dimension that lets us stay inside
        // the image bounds.
        var w = rect.width
        var h = w / r
        if h > rect.height {
            h = rect.height
            w = h * r
        }
        // Clamp to image bounds.
        let maxW = min(imageSize.width, w)
        let maxH = min(imageSize.height, h)
        if maxW / r <= maxH {
            w = maxW
            h = w / r
        } else {
            h = maxH
            w = h * r
        }
        var newRect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        // Shift inside image bounds if needed.
        if newRect.minX < 0 { newRect.origin.x = 0 }
        if newRect.minY < 0 { newRect.origin.y = 0 }
        if newRect.maxX > imageSize.width { newRect.origin.x = imageSize.width - newRect.width }
        if newRect.maxY > imageSize.height { newRect.origin.y = imageSize.height - newRect.height }
        rect = newRect
    }
}

enum CropHandle {
    case topLeft, topMid, topRight
    case midLeft,           midRight
    case bottomLeft, bottomMid, bottomRight
    case interior

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }
}
