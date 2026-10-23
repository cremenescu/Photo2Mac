// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import CoreGraphics

/// Non-destructive edit description for a single image.
/// Persisted as JSON inside the file's XMP metadata, in `.p2m` sidecars and in
/// the autosave store.
///
/// Decoding is tolerant: every field is optional on the wire, so a stack
/// written by an older version (which lacks newer fields) still opens, and one
/// written by a newer version loses only what this version does not know.
public struct EditStack: Codable, Equatable {
    public var crop: CropRect? = nil {
        didSet {
            // The basis only means something while there is a crop. Resetting
            // it keeps "no crop" stacks equal to each other, so undo history
            // and dirty tracking do not see phantom differences.
            if crop == nil { cropBasisDegrees = 0 }
        }
    }
    /// The rotation that was in effect when `crop` was drawn. The crop is
    /// stored relative to the bounding box of THAT rotation; when the angle is
    /// changed afterwards, `EditGeometry.effectiveCrop` moves the crop with the
    /// subject instead of keeping the same fraction of a box that changed shape.
    public var cropBasisDegrees: Double = 0
    /// Clockwise rotation in degrees. Now Double so the inspector slider can
    /// nudge by 0.01 for precise straightening (not just 90-degree presets).
    public var rotateDegrees: Double = 0
    /// Flips of the SOURCE, applied before rotation. The UI flips what the
    /// user sees through `flipDisplayHorizontal` / `flipDisplayVertical`,
    /// which translate a flip of the rotated image into these flags.
    public var flipHorizontal: Bool = false
    public var flipVertical: Bool = false
    public var adjustments: Adjustments = Adjustments()
    /// Final scaling, applied after everything else.
    public var resize: ResizeSpec? = nil

    public init() {}

    public var isNeutral: Bool {
        crop == nil
            && abs(rotateDegrees) < 0.0001
            && !flipHorizontal && !flipVertical
            && adjustments.isNeutral
            && resize == nil
    }

    private enum CodingKeys: String, CodingKey {
        case crop, cropBasisDegrees, rotateDegrees, flipHorizontal, flipVertical
        case adjustments, resize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop)
        cropBasisDegrees = try c.decodeIfPresent(Double.self, forKey: .cropBasisDegrees) ?? 0
        rotateDegrees = try c.decodeIfPresent(Double.self, forKey: .rotateDegrees) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        adjustments = try c.decodeIfPresent(Adjustments.self, forKey: .adjustments) ?? Adjustments()
        resize = try c.decodeIfPresent(ResizeSpec.self, forKey: .resize)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(crop, forKey: .crop)
        if crop != nil { try c.encode(cropBasisDegrees, forKey: .cropBasisDegrees) }
        try c.encode(rotateDegrees, forKey: .rotateDegrees)
        try c.encode(flipHorizontal, forKey: .flipHorizontal)
        try c.encode(flipVertical, forKey: .flipVertical)
        try c.encode(adjustments, forKey: .adjustments)
        try c.encodeIfPresent(resize, forKey: .resize)
    }

    // MARK: - Geometry operations as the user sees them

    /// Set a crop drawn on the image as it currently looks.
    public mutating func setCrop(_ rect: CropRect) {
        crop = rect
        cropBasisDegrees = rotateDegrees
    }

    /// Rotate a quarter turn. An existing crop turns with the image, so it
    /// keeps framing the same subject.
    public mutating func rotateQuarter(clockwise: Bool) {
        let step: Double = clockwise ? 90 : -90
        rotateDegrees = Self.wrap(rotateDegrees + step)
        guard var c = crop else { return }
        if clockwise {
            c = CropRect(x: 1 - c.y - c.height, y: c.x, width: c.height, height: c.width)
        } else {
            c = CropRect(x: c.y, y: 1 - c.x - c.width, width: c.height, height: c.width)
        }
        crop = c
        cropBasisDegrees = Self.wrap(cropBasisDegrees + step)
    }

    /// Mirror the image left-right as it is displayed.
    ///
    /// The flips are applied to the source BEFORE rotation, so toggling
    /// `flipHorizontal` on a photo rotated by 90° mirrors it top-bottom on
    /// screen. Mirroring the displayed image is the same as mirroring the
    /// source and negating the angle (Fh · R(θ) = R(−θ) · Fh).
    public mutating func flipDisplayHorizontal() {
        flipHorizontal.toggle()
        rotateDegrees = Self.wrap(-rotateDegrees)
        guard var c = crop else { return }
        c.x = 1 - c.x - c.width
        crop = c
        cropBasisDegrees = Self.wrap(-cropBasisDegrees)
    }

    /// Mirror the image top-bottom as it is displayed. See
    /// `flipDisplayHorizontal`.
    public mutating func flipDisplayVertical() {
        flipVertical.toggle()
        rotateDegrees = Self.wrap(-rotateDegrees)
        guard var c = crop else { return }
        c.y = 1 - c.y - c.height
        crop = c
        cropBasisDegrees = Self.wrap(-cropBasisDegrees)
    }

    /// Undo the rotation, quarter turns first so a crop keeps its shape.
    public mutating func resetRotation() {
        while rotateDegrees > 45 { rotateQuarter(clockwise: false) }
        while rotateDegrees < -45 { rotateQuarter(clockwise: true) }
        rotateDegrees = 0
    }

    /// Back to the image as it was opened, keeping a crop on its subject.
    public mutating func resetGeometry() {
        if flipHorizontal { flipDisplayHorizontal() }
        if flipVertical { flipDisplayVertical() }
        resetRotation()
    }

    /// Toggle one SOURCE flip flag and leave the angle alone — what removing
    /// a flip from the edits list means.
    ///
    /// On screen that is a reflection about the source's flipped axis as it
    /// is currently rotated (Fh · R(−θ) conjugated by R(θ)), so the crop's
    /// centre is reflected about that axis through the box centre. The crop
    /// keeps its size, which is exact for straight and quarter-turn angles.
    public mutating func toggleSourceFlip(horizontal: Bool, sourceSize: CGSize) {
        let current = EditGeometry.effectiveCrop(for: self, sourceSize: sourceSize)
        if horizontal { flipHorizontal.toggle() } else { flipVertical.toggle() }
        guard let c = current else { return }
        let box = EditGeometry.rotatedSize(sourceSize, degrees: rotateDegrees)
        // Axis of the reflection, y down: the source's vertical axis for a
        // horizontal flip, its horizontal axis for a vertical one, turned by θ.
        let rad = rotateDegrees * .pi / 180
        let axis = horizontal ? CGPoint(x: -sin(rad), y: cos(rad))
                              : CGPoint(x: cos(rad), y: sin(rad))
        let px = (c.x + c.width / 2) * box.width - box.width / 2
        let py = (c.y + c.height / 2) * box.height - box.height / 2
        let dot = px * axis.x + py * axis.y
        let qx = 2 * dot * axis.x - px
        let qy = 2 * dot * axis.y - py
        let x = (qx + box.width / 2) / box.width - c.width / 2
        let y = (qy + box.height / 2) / box.height - c.height / 2
        crop = CropRect(x: min(max(0, x), 1 - c.width),
                        y: min(max(0, y), 1 - c.height),
                        width: c.width, height: c.height)
        cropBasisDegrees = rotateDegrees
    }

    /// Wrap an angle into (-180, 180].
    static func wrap(_ degrees: Double) -> Double {
        var r = degrees
        while r > 180 { r -= 360 }
        while r <= -180 { r += 360 }
        return r
    }
}

/// User-facing adjustments, all in symmetric -1 ... 1 range
/// (except exposure which is in EV stops, -3 ... 3).
public struct Adjustments: Codable, Equatable {
    public var brightness: Double = 0.0  // -1 ... 1 (UI), mapped to -0.5...0.5 in CI
    public var contrast: Double = 0.0    // -1 ... 1, mapped to 0.5 ... 1.5 in CI
    public var saturation: Double = 0.0  // -1 ... 1, mapped to 0 ... 2 in CI
    public var exposure: Double = 0.0    // -3 ... 3 EV stops, used as-is in CI

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
    }

    public var isNeutral: Bool {
        brightness == 0 && contrast == 0 && saturation == 0 && exposure == 0
    }

    public mutating func reset() {
        self = Adjustments()
    }
}

public struct CropRect: Codable, Equatable {
    /// Normalized rect (0...1), origin top-left, over the bounding box of the
    /// image after flip + rotation by `EditStack.cropBasisDegrees`.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Target size of the final image.
public struct ResizeSpec: Codable, Equatable {
    public var width: Int
    public var height: Int
    /// True: the result fits inside `width` x `height` and keeps its
    /// proportions, so a later crop of a different shape does not stretch it.
    /// False: the result is exactly `width` x `height`.
    public var keepsAspect: Bool

    public init(width: Int, height: Int, keepsAspect: Bool = true) {
        self.width = width; self.height = height; self.keepsAspect = keepsAspect
    }
}
