import AVKit
import SwiftUI

struct CameraScreen: View {
    @StateObject private var model = CameraModel()
    @StateObject private var motion = LevelMotion()
    @StateObject private var store = TakeStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFormatPanel = false
    @State private var showPro = false
    @State private var proControl: ManualControl?
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var flashOpacity = 0.0

    var body: some View {
        ZStack {
            Color(white: 0.11).ignoresSafeArea()

            if model.denied {
                permissionView
            } else {
                VStack(spacing: 0) {
                    topBar
                    PreviewStage(model: model, motion: motion)
                        .padding(.top, 8)
                    lensRow
                        .padding(.top, 10)
                    if showPro {
                        ManualControlsView(model: model, selected: $proControl)
                            .padding(.top, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    shutterRow
                        .padding(.top, 14)
                    modePicker
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                }
            }

            if showFormatPanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showFormatPanel = false } }
                VStack {
                    FormatPanel(model: model)
                        .padding(.horizontal, 12)
                        .padding(.top, 58)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Color.white.opacity(flashOpacity).ignoresSafeArea().allowsHitTesting(false)

            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 210)
                }
                .transition(.opacity)
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { model.toast = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.accentTeal)
        .animation(.easeOut(duration: 0.2), value: showPro)
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
        .onChange(of: model.flashTrigger) { _, _ in
            flashOpacity = 0.85
            withAnimation(.easeOut(duration: 0.35)) { flashOpacity = 0 }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView(store: store)
        }
        .background(ShutterButtonInteraction { model.shutterPressed() })
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showFormatPanel.toggle() }
            } label: {
                HStack(spacing: 12) {
                    chipValue(model.config.mode == .photo ? "FOTO" : primaryResolutionLabel, sub: "RES")
                    if model.config.mode == .video {
                        chipValue("\(Int(model.state.fps))", sub: model.state.hdrActive ? "HDR" : "FPS")
                    }
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.accentTeal)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(.black.opacity(0.55), in: Capsule())
            }
            .disabled(model.isRecording)
            .accessibilityLabel("Resolução e quadros por segundo")

            Spacer()

            HStack(spacing: 18) {
                if model.hasTorch {
                    toolbarIcon(model.torchOn ? "bolt.fill" : "bolt.slash", active: model.torchOn,
                                label: "Lanterna") { model.toggleTorch() }
                }
                toolbarIcon("camera.aperture", active: showPro, label: "Controles manuais") {
                    showPro.toggle()
                    if !showPro { proControl = nil }
                }
                toolbarIcon("arrow.triangle.2.circlepath.camera", active: false, label: "Virar câmera") {
                    model.flipCamera()
                }
                .disabled(model.isRecording)
                toolbarIcon("gearshape.fill", active: false, label: "Ajustes") { showSettings = true }
                    .disabled(model.isRecording)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private var primaryResolutionLabel: String {
        let kinds = model.config.outputs
        let labels = Set(kinds.map { model.config.resolution(for: $0).label })
        if labels.count == 1, let only = labels.first { return only }
        return labels.contains("4K") ? "4K" : (labels.contains("Nativa") ? "MAX" : "HD")
    }

    private func chipValue(_ value: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold))
            Text(sub).font(.system(size: 8, weight: .bold)).foregroundStyle(Color.accentTeal).offset(y: 1)
        }
        .foregroundStyle(.white)
    }

    private func toolbarIcon(_ name: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(active ? Color.accentTeal : Color.white)
                .frame(width: 26, height: 44)
        }
        .accessibilityLabel(label)
    }

    // MARK: Lens row

    private var lensRow: some View {
        HStack(spacing: 6) {
            ForEach(model.lensButtons) { button in
                let active = model.isActive(button)
                Button {
                    model.select(button)
                } label: {
                    Text(active ? zoomLabel(model.zoomDisplay) : button.label)
                        .font(.system(size: active ? 13 : 12, weight: .bold))
                        .foregroundStyle(active ? Color.accentTeal : Color.white)
                        .frame(width: active ? 42 : 36, height: active ? 42 : 36)
                        .background(Color.black.opacity(active ? 0.7 : 0.35), in: Circle())
                }
                .accessibilityLabel("Zoom \(button.label)")
            }
        }
        .animation(.spring(duration: 0.25), value: model.zoomDisplay)
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        if value < 1 { return String(format: ",%d×", Int((value * 10).rounded())) }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))×" : String(format: "%.1f×", rounded)
    }

    // MARK: Shutter row

    private var shutterRow: some View {
        HStack {
            Button {
                showGallery = true
            } label: {
                Group {
                    if let thumb = model.lastThumbnail {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 20)).foregroundStyle(.white)
                    }
                }
                .frame(width: 52, height: 52)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25)))
            }
            .disabled(model.isRecording)
            .accessibilityLabel("Gravações")

            Spacer()

            ShutterButton(mode: model.config.mode, isRecording: model.isRecording, isBusy: model.isBusy) {
                model.shutterPressed()
            }

            Spacer()

            Button {
                withAnimation(.spring(duration: 0.35)) {
                    model.config.layout = model.config.layout == .split ? .pip : .split
                }
            } label: {
                Image(systemName: model.config.layout == .split ? "pip" : "rectangle.split.1x2")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.accentTeal)
                    .frame(width: 52, height: 52)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel(model.config.layout == .split ? "Prévia em janela flutuante" : "Prévias separadas")
        }
        .padding(.horizontal, 26)
    }

    // MARK: Mode picker

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases) { mode in
                let selected = model.config.mode == mode
                Button {
                    guard !model.isRecording else { return }
                    withAnimation(.spring(duration: 0.3)) { model.config.mode = mode }
                } label: {
                    Text(mode.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.75))
                        .frame(width: 96, height: 38)
                        .background(selected ? Color.accentTeal : Color.clear, in: Capsule())
                }
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
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

struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(mode == .video ? Color.accentTeal : Color.white, lineWidth: 5)
                    .frame(width: 84, height: 84)
                if mode == .photo {
                    Circle().fill(Color.white).frame(width: 66, height: 66)
                        .scaleEffect(isBusy ? 0.85 : 1)
                } else {
                    RoundedRectangle(cornerRadius: isRecording ? 8 : 33, style: .continuous)
                        .fill(isBusy ? Color.gray : Color.red)
                        .frame(width: isRecording ? 32 : 66, height: isRecording ? 32 : 66)
                }
            }
            .animation(.spring(duration: 0.25), value: isRecording)
            .animation(.spring(duration: 0.15), value: isBusy)
        }
        .disabled(isBusy && !isRecording)
        .accessibilityLabel(mode == .photo ? "Tirar foto" : (isRecording ? "Parar gravação" : "Gravar"))
    }
}

/// Volume buttons (and Camera Control) fire the shutter while the camera is on screen.
struct ShutterButtonInteraction: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = true
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .ended { context.coordinator.action() }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }
}

/// Drop-down panel under the resolution chip: per-format resolution, frame rate and HDR.
struct FormatPanel: View {
    @ObservedObject var model: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(OutputKind.allCases) { kind in
                row(kind.menuTitle) {
                    let enabled = model.config.isEnabled(kind)
                    let current = model.config.resolution(for: kind)
                    ForEach(OutputResolution.allCases) { resolution in
                        option(resolution.label, selected: enabled && current == resolution) {
                            model.config.setResolution(resolution, for: kind)
                            model.config.setEnabled(kind, true)
                        }
                    }
                    option("Off", selected: !enabled) { model.config.setEnabled(kind, false) }
                }
            }
            if model.config.mode == .video {
                Divider().overlay(Color.white.opacity(0.1))
                row("FRAME RATE") {
                    ForEach([24, 25, 30, 60], id: \.self) { fps in
                        option("\(fps)", selected: model.config.fps == fps) { model.config.fps = fps }
                    }
                }
                row("HDR") {
                    option("SDR", selected: !model.config.hdr) { model.config.hdr = false }
                    option("HLG 10-bit", selected: model.config.hdr) { model.config.hdr = true }
                }
            }
            if !model.state.notes.isEmpty {
                ForEach(model.state.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 100, alignment: .leading)
            HStack(spacing: 4) { content() }
        }
    }

    private func option(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Circle().fill(Color.accentTeal).frame(width: 5, height: 5) }
                Text(label)
                    .font(.system(size: 15, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? Color.accentTeal : Color.white)
            }
            .frame(minWidth: 52, minHeight: 32)
        }
    }
}
