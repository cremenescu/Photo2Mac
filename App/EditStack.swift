// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import CoreGraphics

/// Non-destructive edit description for a single image.
/// Persisted (eventually) as JSON inside the file's XMP metadata.
public struct EditStack: Codable, Equatable {
    public var crop: CropRect? = nil
    public var rotateDegrees: Int = 0          // 0, 90, 180, 270 (clockwise)
    public var flipHorizontal: Bool = false
    public var flipVertical: Bool = false
    public var adjustments: Adjustments = Adjustments()

    public init() {}

    public var isNeutral: Bool {
        crop == nil
            && rotateDegrees == 0
            && !flipHorizontal && !flipVertical
            && adjustments.isNeutral
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

    public var isNeutral: Bool {
        brightness == 0 && contrast == 0 && saturation == 0 && exposure == 0
    }

    public mutating func reset() {
        self = Adjustments()
    }
}

public struct CropRect: Codable, Equatable {
    /// Normalized rect (0...1) over original image, after rotate/flip applied.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
