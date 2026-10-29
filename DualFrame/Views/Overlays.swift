import SwiftUI

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3, y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}

struct CrosshairOverlay: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 28, weight: .ultraLight))
            .foregroundStyle(.white.opacity(0.85))
            .allowsHitTesting(false)
    }
}

struct LevelOverlay: View {
    @ObservedObject var motion: LevelMotion

    var body: some View {
        let level = abs(motion.deviation) < 0.8
        let color: Color = level ? .green : .white
        ZStack {
            // Fixed reference ticks.
            HStack(spacing: 150) {
                Rectangle().frame(width: 18, height: 1.5)
                Rectangle().frame(width: 18, height: 1.5)
            }
            .foregroundStyle(.white.opacity(0.6))
            // Horizon line counter-rotates with the tilt.
            Rectangle()
                .frame(width: 120, height: level ? 2 : 1.5)
                .foregroundStyle(color)
                .rotationEffect(.degrees(-motion.deviation))
            Text(String(format: "%.1f°", motion.deviation))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .offset(y: 16)
        }
        .animation(.linear(duration: 0.08), value: motion.deviation)
        .allowsHitTesting(false)
    }
}

struct HistogramView: View {
    let values: [Float]

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let barWidth = size.width / CGFloat(values.count)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in values.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(i) * barWidth, y: size.height * (1 - CGFloat(v))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.white.opacity(0.75)))
        }
        .frame(width: 96, height: 44)
        .padding(4)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }
}

struct AudioMeter: View {
    /// dBFS, roughly -60...0.
    let level: Float

    var body: some View {
        let normalized = CGFloat(max(0, min(1, (level + 60) / 60)))
        let color: Color = level > -3 ? .red : (level > -12 ? .yellow : .green)
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(color).frame(height: geo.size.height * normalized)
            }
        }
        .frame(width: 5, height: 70)
        .animation(.linear(duration: 0.08), value: normalized)
        .allowsHitTesting(false)
    }
}
