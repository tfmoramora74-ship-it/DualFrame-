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
        let engine = self.engine
        view.onLayout = { layer, pixels in engine.setPreviewSinkSize(layer, pixels: pixels) }
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
        var onLayout: ((AVSampleBufferDisplayLayer, CGSize) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            let scale = window?.screen.scale ?? 3
            onLayout?(displayLayer, CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }
    }
}

/// One live format: preview, overlays, caption, tap to focus, long press to lock AE/AF.
struct FormatTile: View {
    let kind: OutputKind
    @ObservedObject var model: CameraModel
    let motion: LevelMotion
    var isPrimary = true
    var compact = false
    /// Fills its whole frame (aspect fill) instead of showing the exact format.
    var fullBleed = false

    @State private var focusPoint: CGPoint?
    @State private var pressStart: Date?
    /// The current touch began on the selfie window: it drags the window instead of focusing.
    @State private var draggingSelfie = false

    private var cornerRadius: CGFloat { fullBleed ? 0 : (compact ? 10 : 16) }

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
                    FocusSquare(locked: model.aeafLocked)
                        .position(x: focusPoint.x * geo.size.width, y: focusPoint.y * geo.size.height)
                }

                if !fullBleed {
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
            }
            .contentShape(Rectangle())
            // One gesture for everything: drag the selfie window, tap to focus, hold to lock AE/AF.
            // Compact windows leave touches to their parent (swap / resize).
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if pressStart == nil {
                        pressStart = Date()
                        draggingSelfie = model.overlayContains(contentPoint(value.startLocation, in: geo.size), in: kind)
                    }
                    if draggingSelfie {
                        model.moveOverlay(to: contentPoint(value.location, in: geo.size), done: false)
                    }
                }
                .onEnded { value in
                    let held = Date().timeIntervalSince(pressStart ?? Date())
                    pressStart = nil
                    let moved = hypot(value.translation.width, value.translation.height) >= 12
                    if draggingSelfie {
                        draggingSelfie = false
                        model.moveOverlay(to: contentPoint(value.location, in: geo.size), done: true)
                        if moved { return }
                    }
                    guard enabled, !moved else { return }
                    let lock = held >= 0.5
                    let point = CGPoint(x: value.location.x / geo.size.width, y: value.location.y / geo.size.height)
                    model.focus(at: contentPoint(value.location, in: geo.size), in: kind, lock: lock)
                    withAnimation(.easeOut(duration: 0.15)) { focusPoint = point }
                    if !lock {
                        Task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            withAnimation { if focusPoint == point, !model.aeafLocked { focusPoint = nil } }
                        }
                    }
                }, including: compact ? .none : .all)
        }
        .keepingAspect(fullBleed ? nil : CGFloat(kind.uprightAspect))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(model.isRecording && enabled ? Color.red.opacity(0.9) : Color.white.opacity(fullBleed ? 0 : 0.18),
                              lineWidth: model.isRecording && enabled ? 2 : 1)
        )
        .onChange(of: model.aeafLocked) { _, locked in
            if !locked { withAnimation { focusPoint = nil } }
        }
    }

    /// Maps a touch in the view to 0...1 of the format's frame, undoing aspect-fill cropping.
    private func contentPoint(_ location: CGPoint, in size: CGSize) -> CGPoint {
        let aspect = CGFloat(kind.uprightAspect)
        let contentWidth = max(size.width, size.height * aspect)
        let contentHeight = max(size.height, size.width / aspect)
        let x = (location.x + (contentWidth - size.width) / 2) / contentWidth
        let y = (location.y + (contentHeight - size.height) / 2) / contentHeight
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    private func caption(enabled: Bool) -> String {
        guard enabled else { return "\(kind.shortLabel) desligado" }
        guard !compact, let size = model.outputSize(for: kind) else { return kind.shortLabel }
        return "\(kind.shortLabel) · \(Int(size.width))×\(Int(size.height))"
    }
}

struct FocusSquare: View {
    var locked = false
    @State private var scale: CGFloat = 1.4

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.yellow, lineWidth: locked ? 2 : 1.5)
            .frame(width: 64, height: 64)
            .overlay(alignment: .top) {
                if locked {
                    Text("AE/AF")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.yellow, in: RoundedRectangle(cornerRadius: 3))
                        .offset(y: -14)
                }
            }
            .scaleEffect(scale)
            .onAppear { withAnimation(.spring(duration: 0.3)) { scale = 1 } }
            .allowsHitTesting(false)
    }
}

/// The live preview area: both formats side by side / stacked, or the corner window of the other format.
struct PreviewStage: View {
    @ObservedObject var model: CameraModel
    let motion: LevelMotion
    @State private var pinchStart: CGFloat?

    var onlyFull: Bool {
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
        .simultaneousGesture(
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

    @ViewBuilder private func split(in size: CGSize) -> some View {
        let spacing: CGFloat = 12
        if size.width > size.height {
            // Landscape: side by side, both as tall as possible.
            let height = size.height - 8
            let verticalWidth = height * 9 / 16
            let horizontalWidth = min(size.width - verticalWidth - spacing - 16, height * 16 / 9)
            HStack(spacing: spacing) {
                FormatTile(kind: .vertical, model: model, motion: motion, isPrimary: false)
                    .frame(width: verticalWidth, height: height)
                FormatTile(kind: .horizontal, model: model, motion: motion)
                    .frame(width: horizontalWidth, height: horizontalWidth * 9 / 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let horizontalWidth = size.width - 24
            let horizontalHeight = horizontalWidth * 9 / 16
            let verticalHeight = max(120, size.height - horizontalHeight - spacing - 8)
            let verticalWidth = min(size.width - 24, verticalHeight * 9 / 16)
            VStack(spacing: spacing) {
                FormatTile(kind: .vertical, model: model, motion: motion)
                    .frame(width: verticalWidth, height: verticalWidth * 16 / 9)
                FormatTile(kind: .horizontal, model: model, motion: motion, isPrimary: false)
                    .frame(width: horizontalWidth, height: horizontalHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The secondary format sits in a fixed spot at the bottom; its button makes it bigger or smaller.
    /// Tapping the window swaps which format is the big one.
    private func pip(in size: CGSize) -> some View {
        let landscape = size.width > size.height
        let primary = model.config.pipMain(landscape: landscape)
        let secondary: OutputKind = primary == .vertical ? .horizontal : .vertical
        let large = model.config.pipLarge
        let base = min(size.width, size.height * (size.width > size.height ? 1.6 : 1))
        let smallWidth: CGFloat = secondary == .horizontal
            ? base * (large ? 0.86 : 0.46)
            : base * (large ? 0.44 : 0.26)
        // Landscape keeps the bottom centre free for the zoom buttons.
        return ZStack(alignment: landscape ? .bottomTrailing : .bottom) {
            Color.clear.allowsHitTesting(false)

            FormatTile(kind: secondary, model: model, motion: motion, isPrimary: false, compact: true)
                .frame(width: smallWidth)
                .onTapGesture {
                    withAnimation(.spring(duration: 0.35)) {
                        model.config.pipPrimary = model.config.pipPrimary == .horizontal ? .vertical : .horizontal
                    }
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
                .padding(.bottom, 8)
                .padding(.trailing, landscape ? 8 : 0)
        }
    }
}

/// Histogram, audio meter, timers and status badges. Observes only the fast meters.
private struct PreviewHUD: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var meters: LiveMeters

    var body: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    if model.config.showHistogram { HistogramView(values: meters.histogram) }
                    Spacer()
                    if model.aeafLocked {
                        Text("AE/AF TRAVADO")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.yellow, in: Capsule())
                    }
                }
                .overlay(alignment: .top) { badge }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            if let countdown = model.countdown {
                Text("\(countdown)")
                    .font(.system(size: 96, weight: .thin).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: countdown)
            }
        }
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
        } else if model.isBusy && model.config.mode == .photo {
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Processando foto…").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
        }
    }
}

/// In the window layout the main format fills the whole screen behind the controls, like the original.
struct FullScreenPrimary: View {
    @ObservedObject var model: CameraModel
    let motion: LevelMotion
    @State private var pinchStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let primary = model.config.pipMain(landscape: landscape)
            // Fill edge to edge when the format matches the screen's shape; otherwise show it whole.
            let fills = (primary == .vertical) != landscape
            Group {
                if fills {
                    FormatTile(kind: primary, model: model, motion: motion, fullBleed: true)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    FormatTile(kind: primary, model: model, motion: motion)
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        if pinchStart == nil { pinchStart = model.readouts.zoomDisplay }
                        let range = model.zoomRange
                        model.setZoom(display: min(max((pinchStart ?? 1) * scale, range.lowerBound), range.upperBound))
                    }
                    .onEnded { _ in pinchStart = nil }
            )
        }
        .ignoresSafeArea()
    }
}

private extension View {
    /// Locks the aspect ratio, or leaves the view free to fill its frame when `ratio` is nil.
    @ViewBuilder func keepingAspect(_ ratio: CGFloat?) -> some View {
        if let ratio {
            aspectRatio(ratio, contentMode: .fit)
        } else {
            self
        }
    }
}
