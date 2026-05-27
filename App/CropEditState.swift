// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import CoreGraphics

/// Live state of the crop tool while user is dragging handles.
/// `rect` is in IMAGE PIXEL coordinates of the ORIGINAL (uncropped) image.
final class CropEditState: ObservableObject {
    @Published var rect: CGRect
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
            // Default: entire image.
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
}

enum CropHandle {
    case topLeft, topRight, bottomLeft, bottomRight, interior
}
