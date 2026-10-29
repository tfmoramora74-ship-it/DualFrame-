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

            if !model.denied, model.config.layout == .pip, !fullOnly {
                FullScreenPrimary(model: model, motion: motion)
                // Keeps the controls legible over a bright scene.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 120)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 260)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            if model.denied {
                permissionView
            } else {
                VStack(spacing: 0) {
                    topBar
                    PreviewStage(model: model, motion: motion)
                        .padding(.top, 8)
                    LensRow(model: model, readouts: model.readouts)
                        .padding(.top, 10)
                    if model.config.mode == .longExposure {
                        LongExposurePanel(model: model)
                            .padding(.top, 10)
                    }
                    if showPro {
                        ManualControlsView(model: model, readouts: model.readouts, selected: $proControl)
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
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 210)
                }
                .transition(.opacity)
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation { model.toast = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.accentTeal)
        .animation(.easeOut(duration: 0.2), value: showPro)
        .animation(.easeOut(duration: 0.2), value: model.config.mode)
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
            SettingsView(model: model, readouts: model.readouts)
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
                    switch model.config.mode {
                    case .video:
                        chipValue(primaryResolutionLabel, sub: "RES")
                        chipValue("\(Int(model.state.fps))", sub: rangeBadge)
                    case .photo:
                        chipValue(photoChip, sub: model.config.photoProcessing == .apple && model.config.rawPhoto ? "RAW" : "FOTO")
                    case .longExposure:
                        chipValue("\(model.config.longExposureSeconds)s", sub: "EXP")
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
                .disabled(model.isRecording || model.isSwitching)
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

    private var photoChip: String {
        switch model.config.photoProcessing {
        case .apple: return "APPLE"
        case .fusion: return "HDR+"
        case .superResolution: return "27MP"
        }
    }

    /// Only the 4:3 file is on: a single framed preview, no window layout.
    private var fullOnly: Bool {
        !model.config.isEnabled(.vertical) && !model.config.isEnabled(.horizontal) && model.config.isEnabled(.full)
    }

    private var rangeBadge: String {
        switch model.state.dynamicRange {
        case .sdr: return "FPS"
        case .hdr: return "HDR"
        case .log: return "LOG"
        }
    }

    private var primaryResolutionLabel: String {
        let labels = Set(model.config.outputs.map { model.config.resolution(for: $0).label })
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
            .disabled(model.isRecording || model.stackProgress != nil)
            .accessibilityLabel("Gravações")

            Spacer()

            ShutterButton(mode: model.config.mode, isRecording: model.isRecording,
                          isBusy: model.isBusy, stackProgress: model.stackProgress) {
                model.shutterPressed()
            }
            .disabled(model.isSwitching)

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
            .accessibilityLabel(model.config.layout == .split ? "Uma prévia grande com janela" : "Prévias separadas")
        }
        .padding(.horizontal, 26)
    }

    // MARK: Mode picker

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(CaptureMode.allCases) { mode in
                let selected = model.config.mode == mode
                Button {
                    guard !model.isRecording, model.stackProgress == nil, !model.isSwitching else { return }
                    model.config.mode = mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.75))
                        .frame(width: 98, height: 38)
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

/// The round zoom buttons. Observes only the device readouts.
private struct LensRow: View {
    @ObservedObject var model: CameraModel
    @ObservedObject var readouts: DeviceReadouts

    var body: some View {
        HStack(spacing: 6) {
            ForEach(model.lensButtons) { button in
                let active = model.isActive(button, zoom: readouts.zoomDisplay)
                Button {
                    model.select(button)
                } label: {
                    Text(active ? zoomLabel(readouts.zoomDisplay) : button.label)
                        .font(.system(size: active ? 13 : 12, weight: .bold))
                        .foregroundStyle(active ? Color.accentTeal : Color.white)
                        .frame(width: active ? 42 : 36, height: active ? 42 : 36)
                        .background(Color.black.opacity(active ? 0.7 : 0.35), in: Circle())
                }
                .accessibilityLabel("Zoom \(button.label)")
            }
        }
        .disabled(model.isSwitching)
        .animation(.spring(duration: 0.25), value: readouts.zoomDisplay)
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        if value < 1 { return String(format: ",%d×", Int((value * 10).rounded())) }
        return value == value.rounded() ? "\(Int(value))×" : String(format: "%.1f×", value)
    }
}

/// Duration, blend and focus for long exposures.
private struct LongExposurePanel: View {
    @ObservedObject var model: CameraModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach([2, 5, 10, 20, 30, 60], id: \.self) { seconds in
                    let selected = model.config.longExposureSeconds == seconds
                    Button { model.config.longExposureSeconds = seconds } label: {
                        Text("\(seconds)s")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(selected ? Color.accentTeal : Color.black.opacity(0.45), in: Capsule())
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(StackBlend.allCases) { blend in
                    let selected = model.config.longExposureBlend == blend
                    Button { model.config.longExposureBlend = blend } label: {
                        Text(blend.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Color.black : Color.white)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(selected ? Color.accentTeal : Color.black.opacity(0.45), in: Capsule())
                    }
                }
                Button { model.config.longExposureInfinityFocus.toggle() } label: {
                    Label("∞", systemImage: model.config.longExposureInfinityFocus ? "checkmark" : "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.config.longExposureInfinityFocus ? Color.black : Color.white)
                        .frame(width: 64, height: 32)
                        .background(model.config.longExposureInfinityFocus ? Color.accentTeal : Color.black.opacity(0.45),
                                    in: Capsule())
                }
                .accessibilityLabel("Foco no infinito")
            }
            Text("Apoie o celular (tripé). Cada quadro expõe até 1 s e todos são empilhados para reduzir o ruído.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .disabled(model.stackProgress != nil)
    }
}

struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let isBusy: Bool
    let stackProgress: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(mode == .video ? Color.accentTeal : Color.white.opacity(0.9), lineWidth: 5)
                    .frame(width: 84, height: 84)
                switch mode {
                case .photo:
                    Circle().fill(Color.white).frame(width: 66, height: 66)
                        .scaleEffect(isBusy ? 0.85 : 1)
                case .video:
                    RoundedRectangle(cornerRadius: isRecording ? 8 : 33, style: .continuous)
                        .fill(isBusy ? Color.gray : Color.red)
                        .frame(width: isRecording ? 32 : 66, height: isRecording ? 32 : 66)
                case .longExposure:
                    if let stackProgress {
                        Circle()
                            .trim(from: 0, to: stackProgress)
                            .stroke(Color.accentTeal, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 84, height: 84)
                        RoundedRectangle(cornerRadius: 6).fill(Color.white).frame(width: 26, height: 26)
                    } else {
                        Circle().fill(Color.white).frame(width: 66, height: 66)
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.black)
                    }
                }
            }
            .animation(.spring(duration: 0.25), value: isRecording)
            .animation(.spring(duration: 0.15), value: isBusy)
        }
        .disabled(isBusy && !isRecording && stackProgress == nil)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch mode {
        case .photo: return "Tirar foto"
        case .video: return isRecording ? "Parar gravação" : "Gravar"
        case .longExposure: return stackProgress == nil ? "Iniciar longa exposição" : "Cancelar longa exposição"
        }
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

/// Drop-down panel under the resolution chip.
struct FormatPanel: View {
    @ObservedObject var model: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(OutputKind.allCases) { kind in
                row(kind.menuTitle) {
                    let enabled = model.config.isEnabled(kind)
                    if model.config.mode == .video {
                        let current = model.config.resolution(for: kind)
                        ForEach(OutputResolution.allCases) { resolution in
                            option(resolution.label, selected: enabled && current == resolution) {
                                model.config.setResolution(resolution, for: kind)
                                model.config.setEnabled(kind, true)
                            }
                        }
                    } else {
                        option("On", selected: enabled) { model.config.setEnabled(kind, true) }
                    }
                    option("Off", selected: !enabled) { model.config.setEnabled(kind, false) }
                }
            }
            Divider().overlay(Color.white.opacity(0.1))
            switch model.config.mode {
            case .video:
                row("FRAME RATE") {
                    ForEach([24, 25, 30, 60], id: \.self) { fps in
                        option("\(fps)", selected: model.config.fps == fps) { model.config.fps = fps }
                    }
                }
                row("COR") {
                    ForEach(DynamicRange.allCases) { range in
                        option(range.label, selected: model.config.dynamicRange == range) {
                            model.config.dynamicRange = range
                        }
                    }
                }
            case .photo:
                row("PROCESSO") {
                    ForEach(PhotoProcessing.allCases) { processing in
                        option(processing.label, selected: model.config.photoProcessing == processing) {
                            model.config.photoProcessing = processing
                        }
                    }
                }
                if model.config.photoProcessing == .apple {
                    row("RAW") {
                        option("Off", selected: !model.config.rawPhoto) { model.config.rawPhoto = false }
                        option("DNG", selected: model.config.rawPhoto) { model.config.rawPhoto = true }
                    }
                }
                Text(processingHelp)
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            case .longExposure:
                Text("Duração e modo ficam logo acima do disparador.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            ForEach(model.state.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var processingHelp: String {
        switch model.config.photoProcessing {
        case .apple: return "Processamento do iPhone (Deep Fusion / Smart HDR). Único com opção RAW (DNG do sensor inteiro)."
        case .fusion: return "Rajada de 8 quadros alinhados e fundidos: menos ruído, sombras abertas e altas luzes preservadas."
        case .superResolution: return "Rajada de 10 quadros com micro-deslocamentos da mão fundidos numa grade 1,5×: ~27 MP e mais detalhe. Segure firme ~0,5 s."
        }
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
            .frame(minWidth: 48, minHeight: 32)
        }
    }
}
