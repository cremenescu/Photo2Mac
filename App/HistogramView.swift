// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Razvan Cremenescu

import SwiftUI
import AppKit
import CoreImage

struct HistogramView: View {
    let histogram: Histogram
    let mode: HistogramMode

    var body: some View {
        Canvas { ctx, size in
            // Dark background.
            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(white: 0.15))
            )
            guard histogram.binCount > 0 else { return }

            // Inline everything — even nested functions seem to lose
            // access to the Canvas's drawing surface in this SwiftUI build.
            let w = size.width
            let h = size.height
            let K: Double = 200
            let denom = log1p(K)
            let bc = histogram.binCount
            let barW = w / CGFloat(bc)

            let channels: [(bins: [Double], color: Color, scale: Double, blend: GraphicsContext.BlendMode)]
            switch mode {
            case .luminance:
                channels = [(histogram.luminance, .white, histogram.luminance.max() ?? 0, .normal)]
            case .red:
                channels = [(histogram.red, Color(red: 1, green: 0.3, blue: 0.3), histogram.red.max() ?? 0, .normal)]
            case .green:
                channels = [(histogram.green, Color(red: 0.3, green: 1, blue: 0.3), histogram.green.max() ?? 0, .normal)]
            case .blue:
                channels = [(histogram.blue, Color(red: 0.45, green: 0.55, blue: 1), histogram.blue.max() ?? 0, .normal)]
            case .rgb:
                let s = scaleFor(histogram.red, histogram.green, histogram.blue)
                channels = [
                    (histogram.red,   Color(red: 1, green: 0.25, blue: 0.25), s, .plusLighter),
                    (histogram.green, Color(red: 0.25, green: 1, blue: 0.25), s, .plusLighter),
                    (histogram.blue,  Color(red: 0.4, green: 0.5, blue: 1),   s, .plusLighter),
                ]
            }

            for channel in channels {
                guard channel.scale > 0 else { continue }
                ctx.blendMode = channel.blend
                for (i, v) in channel.bins.enumerated() {
                    let n = min(max(v / channel.scale, 0), 1)
                    if n <= 0 { continue }
                    let compressed = log1p(n * K) / denom
                    let barH = CGFloat(compressed) * h
                    let rect = CGRect(x: CGFloat(i) * barW,
                                      y: h - barH,
                                      width: max(barW, 1),
                                      height: barH)
                    ctx.fill(Path(rect), with: .color(channel.color))
                }
            }
            ctx.blendMode = .normal
        }
        .frame(height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func scaleFor(_ a: [Double], _ b: [Double], _ c: [Double]) -> Double {
        let m = max(a.max() ?? 0, b.max() ?? 0, c.max() ?? 0)
        return m > 0 ? m : 1
    }

}
