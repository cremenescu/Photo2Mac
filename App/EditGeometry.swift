// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import CoreGraphics

/// Size and crop arithmetic shared by the renderer and the crop editor, so the
/// rectangle the user draws and the rectangle that gets rendered can never
/// drift apart.
public enum EditGeometry {

    /// Bounding box of `size` rotated by `degrees`.
    public static func rotatedSize(_ size: CGSize, degrees: Double) -> CGSize {
        let rad = degrees * .pi / 180
        let c = abs(cos(rad)), s = abs(sin(rad))
        return CGSize(width: size.width * c + size.height * s,
                      height: size.width * s + size.height * c)
    }

    /// The crop to apply under the stack's CURRENT rotation.
    ///
    /// A crop is stored relative to the bounding box of the rotation it was
    /// drawn under (`cropBasisDegrees`). If the angle changed since, the crop's
    /// centre is turned with the image around the box centre and its size in
    /// pixels is kept, so it stays on the same subject. Clamped to the box.
    public static func effectiveCrop(for stack: EditStack, sourceSize: CGSize) -> CropRect? {
        guard let c = stack.crop else { return nil }
        let delta = stack.rotateDegrees - stack.cropBasisDegrees
        guard abs(delta) > 0.0001,
              sourceSize.width > 0, sourceSize.height > 0 else { return c }

        let b0 = rotatedSize(sourceSize, degrees: stack.cropBasisDegrees)
        let b1 = rotatedSize(sourceSize, degrees: stack.rotateDegrees)

        // Centre relative to the box centre, in pixels, y down. In y-down
        // coordinates the standard rotation matrix turns clockwise on screen,
        // which is the direction of a positive `rotateDegrees`.
        let px = (c.x + c.width / 2) * b0.width - b0.width / 2
        let py = (c.y + c.height / 2) * b0.height - b0.height / 2
        let rad = delta * .pi / 180
        let qx = px * cos(rad) - py * sin(rad)
        let qy = px * sin(rad) + py * cos(rad)

        let w = min(1, c.width * b0.width / b1.width)
        let h = min(1, c.height * b0.height / b1.height)
        let x = (qx + b1.width / 2) / b1.width - w / 2
        let y = (qy + b1.height / 2) / b1.height - h / 2
        return CropRect(x: min(max(0, x), 1 - w),
                        y: min(max(0, y), 1 - h),
                        width: w, height: h)
    }

    /// Integer pixel size the resize step produces from an image of `size`.
    public static func resizedSize(_ spec: ResizeSpec, from size: CGSize) -> CGSize {
        let tw = CGFloat(max(1, spec.width)), th = CGFloat(max(1, spec.height))
        guard spec.keepsAspect, size.width > 0, size.height > 0 else {
            return CGSize(width: tw, height: th)
        }
        let scale = min(tw / size.width, th / size.height)
        return CGSize(width: max(1, (size.width * scale).rounded()),
                      height: max(1, (size.height * scale).rounded()))
    }

    /// Pixel size of the image the stack produces, before any resize.
    public static func sizeBeforeResize(for stack: EditStack, sourceSize: CGSize) -> CGSize {
        let box = rotatedSize(sourceSize, degrees: stack.rotateDegrees)
        guard let c = effectiveCrop(for: stack, sourceSize: sourceSize) else {
            return CGSize(width: box.width.rounded(), height: box.height.rounded())
        }
        return CGSize(width: (c.width * box.width).rounded(),
                      height: (c.height * box.height).rounded())
    }

    /// Pixel size of the final rendered image.
    public static func outputSize(for stack: EditStack, sourceSize: CGSize) -> CGSize {
        let pre = sizeBeforeResize(for: stack, sourceSize: sourceSize)
        guard let r = stack.resize else { return pre }
        return resizedSize(r, from: pre)
    }
}
