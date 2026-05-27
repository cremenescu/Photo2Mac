// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import CoreGraphics

enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, fourThree, threeFour, threeTwo, twoThree
    case sixteenNine, nineSixteen

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
/// `rect` is in IMAGE PIXEL coordinates of the ORIGINAL (uncropped) image.
final class CropEditState: ObservableObject {
    @Published var rect: CGRect
    @Published var aspect: CropAspect = .free {
        didSet {
            if aspect != oldValue {
                applyAspect()
            }
        }
    }
    /// The crop that was in `doc.stack.crop` when the user entered crop mode.
    /// On Cancel we restore this; on Apply we replace with `rect` normalized.
    let originalStackCrop: CropRect?
    let imageSize: CGSize

    init(imageSize: CGSize, currentCrop: CropRect?) {
        self.imageSize = imageSize
        self.originalStackCrop = currentCrop
        if let c = currentCrop {
            self.rect = CGRect(x: c.x * imageSize.width,
                               y: c.y * imageSize.height,
                               width: c.width * imageSize.width,
                               height: c.height * imageSize.height)
        } else {
            self.rect = CGRect(origin: .zero, size: imageSize)
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
