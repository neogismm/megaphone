import SwiftUI

/// The small engine badge shown in the recording overlay: a laptop for
/// Apple's on-device model, the provider's own mark for cloud engines.
///
/// Brand marks are drawn as vector `Shape`s rather than bundled images so
/// they tint like SF Symbols, stay crisp at any size, and need no resource
/// plumbing in the `swiftc`-only build.
struct TranscriptionEngineMark: View {
    let engine: TranscriptionEngine
    /// Matches the point size the SF Symbol variant is rendered at.
    let size: CGFloat
    let tint: Color

    var body: some View {
        switch engine {
        case .appleOnDevice:
            Image(systemName: "laptopcomputer")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
        case .openAI:
            OpenAIMarkShape()
                .fill(tint, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        case .gemini:
            GeminiMarkShape()
                .fill(tint, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        }
    }
}

/// Maps a point in a 24×24 icon viewBox into `rect`, preserving aspect ratio.
private func iconPointMapper(in rect: CGRect) -> (CGFloat, CGFloat) -> CGPoint {
    let scale = min(rect.width, rect.height) / 24
    let originX = rect.midX - 12 * scale
    let originY = rect.midY - 12 * scale
    return { x, y in CGPoint(x: originX + x * scale, y: originY + y * scale) }
}

// Path data below is generated from the MIT-licensed `@lobehub/icons`
// SVGs (openai.svg, gemini.svg; 24×24 viewBox, even-odd fill), with SVG arcs
// converted to cubic Béziers. The marks themselves are trademarks of their
// owners and are used only to say which service is transcribing.

/// OpenAI's logomark.
struct OpenAIMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let p = iconPointMapper(in: rect)
        var path = Path()
        path.move(to: p(9.205, 8.658))
        path.addLine(to: p(9.205, 6.398))
        path.addCurve(to: p(9.443, 5.97), control1: p(9.205, 6.208), control2: p(9.277, 6.065))
        path.addLine(to: p(13.986, 3.354))
        path.addCurve(to: p(16.103, 2.831), control1: p(14.605, 2.997), control2: p(15.342, 2.831))
        path.addCurve(to: p(20.765, 7.397), control1: p(18.957, 2.831), control2: p(20.765, 5.043))
        path.addCurve(to: p(20.741, 7.944), control1: p(20.765, 7.564), control2: p(20.765, 7.754))
        path.addLine(to: p(16.031, 5.185))
        path.addCurve(to: p(15.175, 5.185), control1: p(15.77, 5.019), control2: p(15.436, 5.019))
        path.addLine(to: p(9.205, 8.658))
        path.addLine(to: p(9.205, 8.658))
        path.closeSubpath()
        path.move(to: p(19.814, 17.458))
        path.addLine(to: p(19.814, 12.06))
        path.addCurve(to: p(19.385, 11.323), control1: p(19.814, 11.727), control2: p(19.671, 11.49))
        path.addLine(to: p(13.415, 7.85))
        path.addLine(to: p(15.365, 6.732))
        path.addCurve(to: p(15.841, 6.732), control1: p(15.509, 6.637), control2: p(15.697, 6.637))
        path.addLine(to: p(20.384, 9.349))
        path.addCurve(to: p(22.573, 13.297), control1: p(21.693, 10.109), control2: p(22.573, 11.727))
        path.addCurve(to: p(19.813, 17.46), control1: p(22.573, 15.105), control2: p(21.503, 16.77))
        path.addLine(to: p(19.814, 17.458))
        path.closeSubpath()
        path.move(to: p(7.802, 12.703))
        path.addLine(to: p(5.852, 11.561))
        path.addCurve(to: p(5.613, 11.133), control1: p(5.685, 11.466), control2: p(5.613, 11.323))
        path.addLine(to: p(5.613, 5.899))
        path.addCurve(to: p(10.204, 1.427), control1: p(5.613, 3.354), control2: p(7.563, 1.427))
        path.addCurve(to: p(12.916, 2.355), control1: p(11.204, 1.427), control2: p(12.131, 1.76))
        path.addLine(to: p(8.23, 5.067))
        path.addCurve(to: p(7.802, 5.804), control1: p(7.945, 5.233), control2: p(7.802, 5.471))
        path.addLine(to: p(7.802, 12.702))
        path.addLine(to: p(7.802, 12.703))
        path.closeSubpath()
        path.move(to: p(12, 15.128))
        path.addLine(to: p(9.205, 13.558))
        path.addLine(to: p(9.205, 10.228))
        path.addLine(to: p(12, 8.658))
        path.addLine(to: p(14.795, 10.228))
        path.addLine(to: p(14.795, 13.558))
        path.addLine(to: p(12, 15.128))
        path.closeSubpath()
        path.move(to: p(13.796, 22.358))
        path.addCurve(to: p(11.084, 21.431), control1: p(12.796, 22.358), control2: p(11.869, 22.026))
        path.addLine(to: p(15.77, 18.719))
        path.addCurve(to: p(16.198, 17.982), control1: p(16.055, 18.553), control2: p(16.198, 18.315))
        path.addLine(to: p(16.198, 11.084))
        path.addLine(to: p(18.172, 12.226))
        path.addCurve(to: p(18.41, 12.654), control1: p(18.339, 12.321), control2: p(18.41, 12.464))
        path.addLine(to: p(18.41, 17.887))
        path.addCurve(to: p(13.796, 22.359), control1: p(18.41, 20.432), control2: p(16.436, 22.359))
        path.addLine(to: p(13.796, 22.358))
        path.closeSubpath()
        path.move(to: p(8.159, 17.055))
        path.addLine(to: p(3.615, 14.438))
        path.addCurve(to: p(1.427, 10.49), control1: p(2.307, 13.677), control2: p(1.427, 12.06))
        path.addCurve(to: p(4.21, 6.327), control1: p(1.421, 8.669), control2: p(2.525, 7.017))
        path.addLine(to: p(4.21, 11.75))
        path.addCurve(to: p(4.638, 12.488), control1: p(4.21, 12.083), control2: p(4.353, 12.321))
        path.addLine(to: p(10.585, 15.937))
        path.addLine(to: p(8.635, 17.055))
        path.addCurve(to: p(8.159, 17.055), control1: p(8.491, 17.15), control2: p(8.303, 17.15))
        path.addLine(to: p(8.159, 17.055))
        path.closeSubpath()
        path.move(to: p(7.897, 20.955))
        path.addCurve(to: p(3.235, 16.436), control1: p(5.209, 20.955), control2: p(3.235, 18.934))
        path.addCurve(to: p(3.282, 15.866), control1: p(3.235, 16.246), control2: p(3.259, 16.056))
        path.addLine(to: p(7.968, 18.576))
        path.addCurve(to: p(8.824, 18.576), control1: p(8.254, 18.743), control2: p(8.539, 18.743))
        path.addLine(to: p(14.794, 15.128))
        path.addLine(to: p(14.794, 17.388))
        path.addCurve(to: p(14.557, 17.816), control1: p(14.794, 17.578), control2: p(14.724, 17.721))
        path.addLine(to: p(10.014, 20.432))
        path.addCurve(to: p(7.897, 20.955), control1: p(9.395, 20.789), control2: p(8.658, 20.955))
        path.addLine(to: p(7.897, 20.955))
        path.closeSubpath()
        path.move(to: p(13.796, 23.785))
        path.addCurve(to: p(19.623, 19.029), control1: p(16.611, 23.785), control2: p(19.059, 21.787))
        path.addCurve(to: p(24, 13.296), control1: p(22.287, 18.339), control2: p(24, 15.84))
        path.addCurve(to: p(22.002, 8.848), control1: p(24, 11.631), control2: p(23.287, 10.014))
        path.addCurve(to: p(22.192, 7.35), control1: p(22.121, 8.348), control2: p(22.192, 7.849))
        path.addCurve(to: p(16.246, 1.403), control1: p(22.192, 3.949), control2: p(19.433, 1.403))
        path.addCurve(to: p(14.366, 1.713), control1: p(15.604, 1.403), control2: p(14.986, 1.498))
        path.addCurve(to: p(10.205, 0), control1: p(13.256, 0.621), control2: p(11.762, 0.006))
        path.addCurve(to: p(4.378, 4.757), control1: p(7.39, 0), control2: p(4.941, 1.999))
        path.addCurve(to: p(0, 10.49), control1: p(1.713, 5.447), control2: p(0, 7.945))
        path.addCurve(to: p(1.998, 14.938), control1: p(0, 12.156), control2: p(0.713, 13.773))
        path.addCurve(to: p(1.808, 16.437), control1: p(1.879, 15.438), control2: p(1.808, 15.938))
        path.addCurve(to: p(7.754, 22.383), control1: p(1.808, 19.838), control2: p(4.567, 22.383))
        path.addCurve(to: p(9.634, 22.074), control1: p(8.396, 22.383), control2: p(9.014, 22.288))
        path.addCurve(to: p(13.796, 23.787), control1: p(10.744, 23.167), control2: p(12.239, 23.782))
        path.addLine(to: p(13.796, 23.785))
        path.closeSubpath()
        return path
    }
}

/// Gemini's four-point sparkle.
struct GeminiMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let p = iconPointMapper(in: rect)
        var path = Path()
        path.move(to: p(20.616, 10.835))
        path.addCurve(to: p(16.166, 7.834), control1: p(18.955, 10.128), control2: p(17.444, 9.109))
        path.addCurve(to: p(12.488, 1.382), control1: p(14.386, 6.05), control2: p(13.116, 3.822))
        path.addCurve(to: p(12, 1.003), control1: p(12.432, 1.16), control2: p(12.23, 1.003))
        path.addCurve(to: p(11.513, 1.382), control1: p(11.771, 1.003), control2: p(11.569, 1.16))
        path.addCurve(to: p(7.834, 7.834), control1: p(10.884, 3.822), control2: p(9.613, 6.05))
        path.addCurve(to: p(3.384, 10.835), control1: p(6.556, 9.109), control2: p(5.045, 10.128))
        path.addCurve(to: p(1.382, 11.513), control1: p(2.734, 11.115), control2: p(2.066, 11.34))
        path.addCurve(to: p(1, 12.001), control1: p(1.158, 11.568), control2: p(1, 11.77))
        path.addCurve(to: p(1.382, 12.488), control1: p(1, 12.231), control2: p(1.158, 12.433))
        path.addCurve(to: p(3.384, 13.165), control1: p(2.066, 12.66), control2: p(2.732, 12.885))
        path.addCurve(to: p(7.834, 16.166), control1: p(5.045, 13.872), control2: p(6.556, 14.891))
        path.addCurve(to: p(11.513, 22.619), control1: p(9.614, 17.95), control2: p(10.885, 20.178))
        path.addCurve(to: p(12, 23.001), control1: p(11.568, 22.843), control2: p(11.77, 23.001))
        path.addCurve(to: p(12.488, 22.619), control1: p(12.231, 23.001), control2: p(12.433, 22.843))
        path.addCurve(to: p(13.165, 20.616), control1: p(12.66, 21.934), control2: p(12.885, 21.268))
        path.addCurve(to: p(16.166, 16.166), control1: p(13.872, 18.955), control2: p(14.891, 17.444))
        path.addCurve(to: p(22.619, 12.488), control1: p(17.95, 14.386), control2: p(20.178, 13.116))
        path.addCurve(to: p(22.998, 12), control1: p(22.841, 12.432), control2: p(22.998, 12.23))
        path.addCurve(to: p(22.619, 11.513), control1: p(22.998, 11.771), control2: p(22.841, 11.569))
        path.addCurve(to: p(20.616, 10.835), control1: p(21.934, 11.341), control2: p(21.265, 11.114))
        path.addLine(to: p(20.616, 10.835))
        path.closeSubpath()
        return path
    }
}
