import AVFoundation
import SwiftUI
import UIKit

extension Color {
    /// The app's accent (teal), used for active state like the original.
    static let accentTeal = Color(red: 0.27, green: 0.78, blue: 0.86)
}

/// Shows the live, already-cropped frames the engine renders for one output.
struct SampleBufferView: UIViewRepresentable {
    let kind: OutputKind
    let engine: CaptureEngine

    func makeUIView(context: Context) -> DisplayView {
        let view = DisplayView()
        view.displayLayer.videoGravity = .resizeAspectFill
        engine.setPreviewSink(view.displayLayer, for: kind)
        return view
    }

    func updateUIView(_ view: DisplayView, context: Context) {
        engine.setPreviewSink(view.displayLayer, for: kind)
    }

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

/// One live format: preview, overlays, label, focus tap.
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

                if !compact {
                    if model.config.showGrid { GridOverlay() }
                    if model.config.showCrosshair { CrosshairOverlay() }
                    if model.config.showLevel && isPrimary { LevelOverlay(motion: motion) }
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
            .onTapGesture { location in
                guard !compact, enabled else { return }
                let point = CGPoint(x: location.x / geo.size.width, y: location.y / geo.size.height)
                model.focus(at: point, in: kind)
                withAnimation(.easeOut(duration: 0.15)) { focusPoint = point }
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    withAnimation { if focusPoint == point { focusPoint = nil } }
                }
            }
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

/// The live preview area: both formats side by side, or one big with the other floating.
struct PreviewStage: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var motion: LevelMotion
    @State private var pipOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var pinchStart: CGFloat?

    private var shownKinds: [OutputKind] {
        let pair: [OutputKind] = [.vertical, .horizontal]
        let enabledPair = pair.filter(model.config.isEnabled)
        if enabledPair.isEmpty { return model.config.isEnabled(.full) ? [.full] : pair }
        if model.isFront { return pair }
        return pair
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if shownKinds == [.full] {
                    FormatTile(kind: .full, model: model, motion: motion)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.config.layout == .split {
                    split(in: geo.size)
                } else {
                    pip(in: geo.size)
                }
                overlayHUD
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .gesture(
            MagnificationGesture()
                .onChanged { scale in
                    if pinchStart == nil { pinchStart = model.zoomDisplay }
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

    private func pip(in size: CGSize) -> some View {
        let primary = model.config.pipPrimary == .horizontal ? OutputKind.horizontal : OutputKind.vertical
        let secondary: OutputKind = primary == .vertical ? .horizontal : .vertical
        let smallWidth: CGFloat = secondary == .horizontal ? size.width * 0.42 : size.width * 0.26
        return ZStack(alignment: .bottom) {
            FormatTile(kind: primary, model: model, motion: motion)
                .frame(maxWidth: size.width - 16, maxHeight: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            FormatTile(kind: secondary, model: model, motion: motion, isPrimary: false, compact: true)
                .frame(width: smallWidth)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .padding(5)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                        .padding(5)
                }
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                .offset(x: pipOffset.width + dragOffset.width, y: pipOffset.height + dragOffset.height)
                .padding(.bottom, 24)
                .onTapGesture {
                    withAnimation(.spring(duration: 0.35)) {
                        model.config.pipPrimary = secondary
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { dragOffset = $0.translation }
                        .onEnded { value in
                            pipOffset.width += value.translation.width
                            pipOffset.height += value.translation.height
                            dragOffset = .zero
                        }
                )
        }
    }

    private var overlayHUD: some View {
        VStack {
            HStack(alignment: .top) {
                if model.config.showHistogram { HistogramView(values: model.histogram) }
                Spacer()
            }
            .overlay(alignment: .top) {
                if model.isRecording || (model.isBusy && model.config.mode == .video) { recordingBadge }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .overlay(alignment: .trailing) {
            if model.config.audioMeter && model.config.mode == .video {
                AudioMeter(level: model.audioLevel).padding(.trailing, 4)
            }
        }
        .allowsHitTesting(false)
    }

    private var recordingBadge: some View {
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
