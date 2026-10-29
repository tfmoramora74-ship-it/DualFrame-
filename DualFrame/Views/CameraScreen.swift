import SwiftUI

struct CameraScreen: View {
    @StateObject private var model = CameraModel()
    @StateObject private var motion = LevelMotion()
    @StateObject private var store = TakeStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedControl: ManualControl?
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var showFormatMenu = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.denied {
                permissionView
            } else {
                VStack(spacing: 10) {
                    topBar
                    previewArea
                    infoLine
                    zoomRow
                    ManualControlsView(model: model, selected: $selectedControl)
                        .disabled(model.isFinishing)
                    bottomBar
                }
            }
            if let toast = model.toast {
                VStack {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 60)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { model.toast = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            await model.start()
            motion.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.resume(); motion.start()
            case .background: model.suspend(); motion.stop()
            default: break
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showGallery) {
            GalleryView(store: store)
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                showFormatMenu.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(model.config.resolution.label).font(.system(size: 15, weight: .bold))
                    Text("\(Int(model.state.fps))").font(.system(size: 15, weight: .bold))
                    + Text(" FPS").font(.system(size: 9, weight: .bold)).foregroundColor(.cyan)
                    if model.state.hdrActive {
                        Text("HDR").font(.system(size: 10, weight: .heavy)).foregroundStyle(.orange)
                    }
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.cyan)
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .popover(isPresented: $showFormatMenu) {
                QuickFormatMenu(model: model)
                    .presentationCompactAdaptation(.popover)
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(OutputKind.allCases) { kind in
                    let on = model.config.outputs.contains(kind)
                    Button {
                        toggleOutput(kind)
                    } label: {
                        Text(kind.shortLabel)
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 40, height: 30)
                            .background(on ? Color(kind.color).opacity(0.85) : Color.white.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(on ? Color.black : Color.white.opacity(0.7))
                    }
                }
            }
            .disabled(model.isRecording)

            if model.hasTorch {
                iconButton(model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                           tint: model.torchOn ? .yellow : .white) { model.toggleTorch() }
            }
            iconButton("gearshape.fill") { showSettings = true }
                .disabled(model.isRecording)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private func toggleOutput(_ kind: OutputKind) {
        var outputs = model.config.outputs
        if let index = outputs.firstIndex(of: kind) {
            outputs.remove(at: index)
        } else {
            outputs.append(kind)
            outputs.sort { OutputKind.allCases.firstIndex(of: $0)! < OutputKind.allCases.firstIndex(of: $1)! }
        }
        model.config.outputs = outputs
    }

    private func iconButton(_ name: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.12), in: Circle())
        }
    }

    // MARK: Preview

    private var previewArea: some View {
        ZStack {
            PreviewView(model: model)
            if model.config.showGrid { GridOverlay() }
            if model.config.showCrosshair { CrosshairOverlay() }
            if model.config.showLevel { LevelOverlay(motion: motion) }

            VStack {
                HStack(alignment: .top) {
                    if model.config.showHistogram { HistogramView(values: model.histogram) }
                    Spacer()
                    if model.isRecording || model.isFinishing { recordingBadge }
                }
                Spacer()
                HStack {
                    Spacer()
                    AudioMeter(level: model.audioLevel)
                }
            }
            .padding(8)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(model.isRecording ? Color.red : Color.white.opacity(0.15), lineWidth: model.isRecording ? 2 : 1)
        )
        .padding(.horizontal, 8)
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(model.isFinishing ? Color.orange : Color.red).frame(width: 8, height: 8)
            Text(model.isFinishing ? "Salvando…" : formatDuration(model.elapsed))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var infoLine: some View {
        VStack(spacing: 2) {
            Text(model.outputSummary)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            if let format = model.state.activeFormat {
                Text("Sensor \(format.width)×\(format.height) · \(model.config.codec.label) · estab. \(model.state.stabilizationActive)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 12)
    }

    private var zoomRow: some View {
        HStack(spacing: 10) {
            ForEach(model.zoomPresets, id: \.self) { preset in
                let active = abs(model.zoomDisplay - preset) < 0.05
                Button {
                    model.setZoom(display: preset, animated: true)
                } label: {
                    Text(active ? String(format: "%.1f×", model.zoomDisplay) : zoomLabel(preset))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(active ? Color.cyan : Color.white)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(active ? 0.2 : 0.08), in: Circle())
                }
            }
        }
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        value < 1 ? String(format: ".%d", Int((value * 10).rounded())) : (value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value))
    }

    // MARK: Bottom

    private var bottomBar: some View {
        HStack {
            Button {
                showGallery = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 20))
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .disabled(model.isRecording)

            Spacer()

            Button {
                model.toggleRecording()
            } label: {
                ZStack {
                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 78, height: 78)
                    RoundedRectangle(cornerRadius: model.isRecording ? 8 : 32)
                        .fill(model.isFinishing ? Color.gray : Color.red)
                        .frame(width: model.isRecording ? 32 : 64, height: model.isRecording ? 32 : 64)
                }
                .animation(.spring(duration: 0.25), value: model.isRecording)
            }
            .disabled(model.isFinishing)

            Spacer()

            Button {
                guard !model.isRecording else { return }
                model.config.lens = model.config.lens == .front ? .auto : .front
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 20))
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .disabled(model.isRecording)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash").font(.system(size: 44))
            Text("O DualFrame precisa de acesso à câmera e ao microfone.")
                .multilineTextAlignment(.center)
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}

/// The resolution / frame-rate chip menu (like the original's top-left chip).
struct QuickFormatMenu: View {
    @ObservedObject var model: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("RESOLUÇÃO") {
                ForEach(OutputResolution.allCases) { res in
                    option(res.label, selected: model.config.resolution == res) { model.config.resolution = res }
                }
            }
            row("FPS") {
                ForEach([24, 25, 30, 48, 50, 60], id: \.self) { fps in
                    option("\(fps)", selected: model.config.fps == fps) { model.config.fps = fps }
                }
            }
            row("HDR") {
                option("SDR", selected: !model.config.hdr) { model.config.hdr = false }
                option("HDR HLG", selected: model.config.hdr) { model.config.hdr = true }
            }
        }
        .padding(16)
        .frame(minWidth: 300)
        .disabled(model.isRecording)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            HStack(spacing: 6) { content() }
        }
    }

    private func option(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? Color.cyan : Color.secondary.opacity(0.2), in: Capsule())
                .foregroundStyle(selected ? Color.black : Color.primary)
        }
    }
}
