import AVFoundation
import SwiftUI
import UIKit

extension Color {
    /// The app's accent (teal), used for active state like the original.
    static let accentTeal = Color(red: 0.27, green: 0.78, blue: 0.86)
}

/// Shows the live, already-cropped frames the engine renders for one output.
/// Several views may show the same format at once (e.g. during a layout animation).
struct SampleBufferView: UIViewRepresentable {
    let kind: OutputKind
    let engine: CaptureEngine

    func makeUIView(context: Context) -> DisplayView {
        let view = DisplayView()
        view.displayLayer.videoGravity = .resizeAspectFill
        engine.addPreviewSink(view.displayLayer, for: kind)
        return view
    }

    func updateUIView(_ view: DisplayView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(kind: kind, engine: engine) }

    static func dismantleUIView(_ view: DisplayView, coordinator: Coordinator) {
        coordinator.engine.removePreviewSink(view.displayLayer, for: coordinator.kind)
    }

    final class Coordinator {
        let kind: OutputKind
        let engine: CaptureEngine
        init(kind: OutputKind, engine: CaptureEngine) {
            self.kind = kind
            self.engine = engine
        }
    }

    final class DisplayView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }
}

/// One live format: preview, overlays, caption, focus tap.
struct FormatTile: View {
    let kind: OutputKind
    @ObservedObject var model: CameraModel
    @ObservedObject var motion: LevelMotion
    var isPrimary = true
    var compact = false

    @State private var focusPoint: CGPoint?

    var body: some View {
        let enabled = model.config.isEnabled(kind)
        GeometryReader { geo in
            ZStack {
                SampleBufferView(kind: kind, engine: model.engine)
                    .opacity(enabled ? 1 : 0.35)
                    .blur(radius: model.isSwitching ? 18 : 0)
                    .animation(.easeOut(duration: 0.25), value: model.isSwitching)

                if !compact {
                    if model.config.showGrid { GridOverlay() }
                    if model.config.showCrosshair { CrosshairOverlay() }
                    if model.config.showLevel && isPrimary { LevelOverlay(motion: motion) }
                }

                if model.isSwitching && isPrimary {
                    ProgressView().tint(.white)
                }

                if let focusPoint {
                    FocusSquare()
                        .position(x: focusPoint.x * geo.size.width, y: focusPoint.y * geo.size.height)
                }

                VStack {
                    Spacer()
                    Text(caption(enabled: enabled))
                        .font(.system(size: compact ? 10 : 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(.bottom, compact ? 4 : 8)
                }
            }
            .contentShape(Rectangle())
            // Compact windows leave taps to their parent (swap); full tiles tap to focus.
            .gesture(SpatialTapGesture().onEnded { value in
                guard enabled else { return }
                let point = CGPoint(x: value.location.x / geo.size.width, y: value.location.y / geo.size.height)
                model.focus(at: point, in: kind)
                withAnimation(.easeOut(duration: 0.15)) { focusPoint = point }
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    withAnimation { if focusPoint == point { focusPoint = nil } }
                }
            }, including: compact ? .none : .all)
        }
        .aspectRatio(kind.uprightAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 10 : 16, style: .continuous)
                .strokeBorder(model.isRecording && enabled ? Color.red.opacity(0.9) : Color.white.opacity(0.18),
                              lineWidth: model.isRecording && enabled ? 2 : 1)
        )
    }

    private func caption(enabled: Bool) -> String {
        guard enabled else { return "\(kind.shortLabel) desligado" }
        guard !compact, let size = model.outputSize(for: kind) else { return kind.shortLabel }
        return "\(kind.shortLabel) · \(Int(size.width))×\(Int(size.height))"
    }
}

struct FocusSquare: View {
    @State private var scale: CGFloat = 1.4

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.yellow, lineWidth: 1.5)
            .frame(width: 64, height: 64)
            .scaleEffect(scale)
            .onAppear { withAnimation(.spring(duration: 0.3)) { scale = 1 } }
            .allowsHitTesting(false)
    }
}

/// The live preview area: both formats stacked, or one big with the other in a corner window.
struct PreviewStage: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var motion: LevelMotion
    @State private var pinchStart: CGFloat?

    private var onlyFull: Bool {
        !model.config.isEnabled(.vertical) && !model.config.isEnabled(.horizontal) && model.config.isEnabled(.full)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if onlyFull {
                    FormatTile(kind: .full, model: model, motion: motion)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.config.layout == .split {
                    split(in: geo.size)
                } else {
                    pip(in: geo.size)
                }
                PreviewHUD(model: model, meters: model.meters)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .gesture(
            MagnificationGesture()
                .onChanged { scale in
                    if pinchStart == nil { pinchStart = model.readouts.zoomDisplay }
                    let range = model.zoomRange
                    let value = min(max((pinchStart ?? 1) * scale, range.lowerBound), range.upperBound)
                    model.setZoom(display: value)
                }
                .onEnded { _ in pinchStart = nil }
        )
    }

    private func split(in size: CGSize) -> some View {
        let spacing: CGFloat = 12
        let horizontalWidth = size.width - 24
        let horizontalHeight = horizontalWidth * 9 / 16
        let verticalHeight = max(120, size.height - horizontalHeight - spacing - 8)
        let verticalWidth = min(size.width - 24, verticalHeight * 9 / 16)
        return VStack(spacing: spacing) {
            FormatTile(kind: .vertical, model: model, motion: motion)
                .frame(width: verticalWidth, height: verticalWidth * 16 / 9)
            FormatTile(kind: .horizontal, model: model, motion: motion, isPrimary: false)
                .frame(width: horizontalWidth, height: horizontalHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The secondary format sits in a fixed spot at the bottom; its button makes it bigger or smaller.
    /// Tapping the window swaps which format is the big one.
    private func pip(in size: CGSize) -> some View {
        let primary = model.config.pipPrimary == .horizontal ? OutputKind.horizontal : OutputKind.vertical
        let secondary: OutputKind = primary == .vertical ? .horizontal : .vertical
        let large = model.config.pipLarge
        let smallWidth: CGFloat = secondary == .horizontal
            ? size.width * (large ? 0.72 : 0.42)
            : size.width * (large ? 0.42 : 0.24)
        return ZStack(alignment: .bottom) {
            FormatTile(kind: primary, model: model, motion: motion)
                .frame(maxWidth: size.width - 16, maxHeight: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            FormatTile(kind: secondary, model: model, motion: motion, isPrimary: false, compact: true)
                .frame(width: smallWidth)
                .onTapGesture {
                    withAnimation(.spring(duration: 0.35)) { model.config.pipPrimary = secondary }
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        withAnimation(.spring(duration: 0.3)) { model.config.pipLarge.toggle() }
                    } label: {
                        Image(systemName: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.55), in: Circle())
                            .contentShape(Circle())
                    }
                    .padding(4)
                    .accessibilityLabel(large ? "Diminuir janela" : "Aumentar janela")
                }
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                .padding(.bottom, 20)
        }
    }
}

/// Histogram, audio meter and recording / long-exposure badge. Observes only the fast meters.
private struct PreviewHUD: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var meters: LiveMeters

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                if model.config.showHistogram { HistogramView(values: meters.histogram) }
                Spacer()
            }
            .overlay(alignment: .top) { badge }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .overlay(alignment: .trailing) {
            if model.config.audioMeter && model.config.mode == .video {
                AudioMeter(level: meters.audioLevel).padding(.trailing, 4)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var badge: some View {
        if let progress = model.stackProgress {
            HStack(spacing: 8) {
                ProgressView(value: progress).progressViewStyle(.circular).tint(.accentTeal)
                Text(progress <= 0 ? "Estabilizando exposição…"
                     : "Expondo \(Int(Double(model.config.longExposureSeconds) * (1 - progress)))s · não mexa no celular")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
        } else if model.isRecording || (model.isBusy && model.config.mode == .video) {
            HStack(spacing: 6) {
                Circle().fill(model.isBusy ? Color.orange : Color.red).frame(width: 8, height: 8)
                Text(model.isBusy ? "Salvando…" : formatDuration(model.elapsed))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
        }
    }
}
