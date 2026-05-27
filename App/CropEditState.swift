// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import CoreGraphics
import AppKit

enum CropAspect: String, CaseIterable, Identifiable {
    // Order matters: this is the order shown in the picker.
    case original, square, fourThree, threeFour, threeTwo, twoThree
    case sixteenNine, nineSixteen, free

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Liber"
        case .original: return "Original"
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
/// which has flip + rotate applied (so cropping happens on what the user sees
/// after orientation changes), but NOT crop or adjustments-after-crop.
final class CropEditState: ObservableObject {
    @Published var rect: CGRect
    @Published var aspect: CropAspect = .original {
        didSet {
            if aspect != oldValue {
                applyAspect()
            }
        }
    }
    /// The crop that was in `doc.stack.crop` when the user entered crop mode.
    /// On Cancel we restore this; on Apply we replace with `rect` normalized.
    let originalStackCrop: CropRect?
    /// Size of the image shown while editing (post-rotate / post-flip).
    let imageSize: CGSize
    /// Image to display behind the crop overlay. Reflects the stack with
    /// crop temporarily disabled, so the user can pick a new crop region on
    /// the already-rotated / already-adjusted image.
    let preCropImage: NSImage

    init(doc: OpenImage) {
        // Render the image with crop disabled but every other operation
        // (flip, rotate, adjustments) applied. This is what the user sees
        // while choosing a new crop region.
        var without = doc.stack
        without.crop = nil
        let pre = ImageRenderer.render(original: doc.originalImage,
                                         sourceCI: doc.sourceCIImage,
                                         stack: without)
        self.preCropImage = pre
        self.imageSize = pre.size
        self.originalStackCrop = doc.stack.crop
        if let c = doc.stack.crop {
            self.rect = CGRect(x: c.x * pre.size.width,
                               y: c.y * pre.size.height,
                               width: c.width * pre.size.width,
                               height: c.height * pre.size.height)
        } else {
            self.rect = CGRect(origin: .zero, size: pre.size)
        }
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
