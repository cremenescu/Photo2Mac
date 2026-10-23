// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

public enum HistogramMode: String, CaseIterable, Identifiable {
    case luminance, rgb, red, green, blue
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .luminance: return t("Luminanta")
        case .rgb: return "RGB"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        }
    }
}

/// Per-channel + luminance bin counts (normalized 0...1).
public struct Histogram: Equatable {
    public let red: [Double]
    public let green: [Double]
    public let blue: [Double]
    public let luminance: [Double]
    public var binCount: Int { red.count }

    public static let empty = Histogram(red: [], green: [], blue: [], luminance: [])
}

public enum HistogramComputer {

    /// Long side of the image the histogram is computed from. The shape of a
    /// histogram does not change with resolution, the cost does.
    static let sampleSide: CGFloat = 512

    /// Histogram of what an NSImage looks like on screen. Safe off the main
    /// thread.
    public static func compute(for image: NSImage) -> Histogram {
        guard let ci = ImageRenderer.makeCIImage(from: image) else { return .empty }
        return compute(from: ci) ?? .empty
    }

    /// Compute 256-bin histograms (R/G/B + luminance) from a CIImage.
    /// Returns nil on failure.
    ///
    /// Binned on sRGB-ENCODED values, like every photo editor: Core Image
    /// works in linear light, and a histogram of linear values piles a
    /// correctly exposed photo into the left third — mid-grey 128 lands near
    /// bin 55 — so the graph looks underexposed when the image is not.
    public static func compute(from source: CIImage, binCount: Int = 256) -> Histogram? {
        var image = source
        let ext = image.extent
        let longSide = max(ext.width, ext.height)
        if longSide > sampleSide {
            let k = sampleSide / longSide
            image = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        image = image.applyingFilter("CILinearToSRGBToneCurve")
        guard let rgb = areaHistogram(of: image, binCount: binCount) else { return nil }

        // Convert to luma via CIColorMatrix using Rec. 709 coefficients,
        // then take that single-channel histogram (R channel = luma).
        let luma = CIFilter.colorMatrix()
        luma.inputImage = image
        let v = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luma.rVector = v
        luma.gVector = v
        luma.bVector = v
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let lumaImg = luma.outputImage,
              let lumaHist = areaHistogram(of: lumaImg, binCount: binCount) else {
            return Histogram(red: rgb.0, green: rgb.1, blue: rgb.2, luminance: rgb.0)
        }
        return Histogram(red: rgb.0, green: rgb.1, blue: rgb.2, luminance: lumaHist.0)
    }

    /// Returns (red, green, blue) arrays of binCount Doubles in 0...1.
    private static func areaHistogram(of image: CIImage,
                                       binCount: Int)
        -> ([Double], [Double], [Double])? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }

        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = extent
        filter.count = binCount
        // Normalized to 0..1 = count / area. For a 1.5M-pixel image evenly
        // distributed across 256 bins, max bin ≈ 1/256 ≈ 0.004. Multiplying
        // scale lets us see the curve clearly. The renderer/UI side renormalizes.
        filter.scale = 50.0
        guard let out = filter.outputImage else { return nil }

        // Render the Nx1 histogram output to a Float32 RGBA buffer with NO
        // color space conversion (the values are bin counts, not colors —
        // passing sRGB or any non-linear space applies gamma and crushes
        // mid-range values to near zero).
        let ctx = ImageRenderer.sharedContext
        let rowBytes = binCount * 4 * MemoryLayout<Float32>.size
        var buf = [Float32](repeating: 0, count: binCount * 4)
        ctx.render(out,
                   toBitmap: &buf,
                   rowBytes: rowBytes,
                   bounds: out.extent,
                   format: .RGBAf,
                   colorSpace: nil)

        // CIAreaHistogram normalizes to 0...1 by dividing by extent area, so
        // we just copy out. Channels: R G B A interleaved per bin.
        var r = [Double](repeating: 0, count: binCount)
        var g = [Double](repeating: 0, count: binCount)
        var b = [Double](repeating: 0, count: binCount)
        for i in 0..<binCount {
            r[i] = Double(buf[i * 4])
            g[i] = Double(buf[i * 4 + 1])
            b[i] = Double(buf[i * 4 + 2])
        }
        return (r, g, b)
    }
}
