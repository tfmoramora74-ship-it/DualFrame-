import AVFoundation
import Photos
import SwiftUI
import UIKit

enum ManualControl: String, CaseIterable, Identifiable {
    case exposureBias, iso, shutter, whiteBalance, focus
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exposureBias: return "EV"
        case .iso: return "ISO"
        case .shutter: return "S"
        case .whiteBalance: return "WB"
        case .focus: return "FOCO"
        }
    }
}

/// One of the round zoom buttons above the shutter (".5", "1×", "2", "3").
struct LensButton: Identifiable, Equatable {
    let lens: LensChoice
    /// videoZoomFactor on that device.
    let factor: CGFloat
    /// Zoom as shown to the user, relative to the 1× wide lens.
    let display: CGFloat
    var id: String { "\(lens.rawValue)-\(display)" }

    var label: String {
        if display < 1 { return String(format: ",%d", Int((display * 10).rounded())) }
        return display == display.rounded() ? "\(Int(display))" : String(format: "%.1f", display)
    }
}

/// UI-facing camera state. Device mutations are forwarded to the engine's session queue.
@MainActor
final class CameraModel: ObservableObject {
    @Published var config: CaptureConfig {
        didSet {
            config.save()
            engine.wantsHistogram = config.showHistogram
            if config.sessionKey != oldValue.sessionKey { reconfigure() }
            updatePreviewSpec()
        }
    }
    @Published private(set) var state = SessionState()
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var histogram: [Float] = []
    @Published private(set) var audioLevel: Float = -160
    @Published private(set) var bufferSize = CGSize.zero
    @Published private(set) var flashTrigger = 0
    @Published var toast: String?
    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    @Published private(set) var lastThumbnail: UIImage?

    // Live device readouts.
    @Published private(set) var iso: Float = 0
    @Published private(set) var shutter: Double = 0
    @Published private(set) var temperature: Float = 5000
    @Published private(set) var lensPosition: Float = 0.5
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var zoomDisplay: CGFloat = 1
    @Published private(set) var manualExposure = false
    @Published private(set) var manualWB = false
    @Published private(set) var manualFocus = false
    @Published private(set) var torchOn = false
    @Published private(set) var lensButtons: [LensButton] = []

    let engine = CaptureEngine()
    private let rearLenses = CaptureEngine.rearLenses()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var deviceRotation: Double = 90
    private var lockedRotation: Double?
    private var pollTimer: Timer?
    private var recordTimer: Timer?
    private var recordStart = Date()
    private var zoomBase: CGFloat = 1
    private var pendingFactor: CGFloat?

    init() {
        config = CaptureConfig.load()
        engine.wantsHistogram = config.showHistogram
        engine.onHistogram = { [weak self] values in
            Task { @MainActor in self?.histogram = values }
        }
        engine.onAudioLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        engine.onBufferSize = { [weak self] size in
            Task { @MainActor in self?.bufferSize = size }
        }
        engine.onError = { [weak self] message in
            Task { @MainActor in self?.toast = message }
        }
        loadLastThumbnail()
    }

    // MARK: Lifecycle

    func start() async {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        authorized = video
        denied = !video
        guard video else { return }
        reconfigure(startAfter: true)
        startPolling()
    }

    func resume() {
        guard authorized else { return }
        engine.sessionQueue.async { [engine] in engine.start() }
    }

    func suspend() {
        if isRecording { stopRecording() }
        engine.sessionQueue.async { [engine] in engine.stop() }
    }

    func reconfigure(startAfter: Bool = false) {
        guard authorized, !isRecording else { return }
        let config = self.config
        engine.sessionQueue.async { [engine] in
            let newState = engine.configure(config)
            if startAfter { engine.start() }
            Task { @MainActor [weak self] in self?.apply(newState) }
        }
    }

    private func apply(_ newState: SessionState) {
        state = newState
        guard let device = newState.device else {
            toast = newState.notes.first
            return
        }
        setupRotation(device: device)
        buildLensButtons(device: device)
        torchOn = false
        if !config.keepManualControls {
            manualExposure = false
            manualWB = false
            manualFocus = false
        }
        if let factor = pendingFactor {
            pendingFactor = nil
            setZoomFactor(factor, animated: false)
        }
        updatePreviewSpec()
    }

    var isFront: Bool { state.device?.position == .front }

    // MARK: Rotation

    private func setupRotation(device: AVCaptureDevice) {
        rotationObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = Double(coordinator.videoRotationAngleForHorizonLevelCapture)
            Task { @MainActor in
                guard let self else { return }
                self.deviceRotation = angle
                self.updatePreviewSpec()
            }
        }
    }

    /// Degrees that turn the delivered buffer upright for files and previews.
    var captureRotation: Double {
        if let lockedRotation { return lockedRotation }
        if isFront { return 0 } // the front buffer is already turned upright by the connection
        return config.followDeviceRotation ? deviceRotation : 90
    }

    private func updatePreviewSpec() {
        engine.setPreviewSpec(PreviewSpec(rotationDegrees: captureRotation, mirror: isFront))
    }

    /// Output sizes of the current setup, for the info line.
    func outputSize(for kind: OutputKind) -> CGSize? {
        guard bufferSize.width > 0 else { return nil }
        let plan = CropMath.plans(kinds: [kind], resolutions: [kind: config.resolution(for: kind)],
                                  bufferWidth: Int(bufferSize.width), bufferHeight: Int(bufferSize.height),
                                  rotationDegrees: captureRotation)[0]
        if config.mode == .photo {
            return CropMath.uprightSize(plan.crop.size, rotationDegrees: captureRotation)
        }
        return CropMath.uprightSize(plan.size, rotationDegrees: captureRotation)
    }

    // MARK: Capture

    func shutterPressed() {
        config.mode == .photo ? takePhoto() : toggleRecording()
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func newTakeName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "DF_" + formatter.string(from: Date())
    }

    func startRecording() {
        guard !isRecording, !isBusy else { return }
        guard !config.outputs.isEmpty else {
            toast = "Ligue pelo menos um formato."
            return
        }
        let name = newTakeName()
        let rotation = captureRotation
        lockedRotation = rotation
        var resolutions: [OutputKind: OutputResolution] = [:]
        for kind in OutputKind.allCases { resolutions[kind] = config.resolution(for: kind) }
        let take = PendingTake(outputs: config.outputs, resolutions: resolutions, codec: config.codec,
                               quality: config.quality, fps: state.fps, hdr: state.hdrActive,
                               rotationDegrees: rotation, mirror: isFront && config.mirrorFront,
                               folder: TakeStore.root.appendingPathComponent(name), baseName: name)
        engine.startRecording(take)
        isRecording = true
        recordStart = Date()
        elapsed = 0
        UIApplication.shared.isIdleTimerDisabled = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.recordStart)
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        isBusy = true
        recordTimer?.invalidate()
        recordTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        engine.stopRecording { [weak self] result in
            Task { @MainActor in self?.finished(result, noun: "vídeo") }
        }
    }

    func takePhoto() {
        guard !isBusy, !isRecording else { return }
        guard !config.outputs.isEmpty else {
            toast = "Ligue pelo menos um formato."
            return
        }
        isBusy = true
        flashTrigger += 1
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        let name = newTakeName()
        let request = PhotoRequest(outputs: config.outputs, rotationDegrees: captureRotation,
                                   mirror: isFront && config.mirrorFront,
                                   folder: TakeStore.root.appendingPathComponent(name), baseName: name)
        engine.capturePhoto(request) { [weak self] result in
            Task { @MainActor in self?.finished(result, noun: "foto") }
        }
    }

    private func finished(_ result: TakeResult, noun: String) {
        isBusy = false
        lockedRotation = nil
        updatePreviewSpec()
        if let error = result.error {
            toast = error
        } else if result.droppedFrames > 0 {
            toast = "\(result.urls.count) arquivos · \(result.droppedFrames) quadros perdidos"
        }
        NotificationCenter.default.post(name: TakeStore.didChange, object: nil)
        loadLastThumbnail()
        if config.saveToPhotos, !result.urls.isEmpty {
            PhotoSaver.save(result.urls) { [weak self] message in
                Task { @MainActor in self?.toast = message }
            }
        }
    }

    private func loadLastThumbnail() {
        Task {
            let latest = TakeStore.latestFile()
            guard let latest else { lastThumbnail = nil; return }
            lastThumbnail = await Thumbnailer.image(for: latest)
        }
    }

    // MARK: Lenses & zoom

    private func buildLensButtons(device: AVCaptureDevice) {
        zoomBase = 1
        var buttons: [LensButton] = []
        switch config.lens {
        case .front:
            buttons = [LensButton(lens: .front, factor: 1, display: 1), LensButton(lens: .front, factor: 2, display: 2)]
        case .auto:
            let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            let types = device.constituentDevices.map(\.deviceType)
            if types.contains(.builtInUltraWideCamera) {
                zoomBase = switchOvers.first ?? 2
                buttons.append(LensButton(lens: .auto, factor: 1, display: 1 / zoomBase))
            }
            buttons.append(LensButton(lens: .auto, factor: zoomBase, display: 1))
            buttons.append(LensButton(lens: .auto, factor: zoomBase * 2, display: 2))
            if types.contains(.builtInTelephotoCamera), let tele = switchOvers.last {
                buttons.append(LensButton(lens: .auto, factor: tele, display: (tele / zoomBase * 2).rounded() / 2))
            }
        default:
            for (lens, multiplier) in rearLenses {
                buttons.append(LensButton(lens: lens, factor: 1, display: multiplier))
                if lens == .wide, !rearLenses.contains(where: { $0.1 == 2 }) {
                    buttons.append(LensButton(lens: .wide, factor: 2, display: 2))
                }
            }
        }
        lensButtons = buttons
    }

    /// Zoom of the current lens relative to the 1× wide lens.
    private var lensMultiplier: CGFloat {
        switch config.lens {
        case .ultraWide, .telephoto: return rearLenses.first(where: { $0.0 == config.lens })?.1 ?? 1
        case .auto: return 1 / zoomBase
        default: return 1
        }
    }

    func select(_ button: LensButton) {
        guard !isRecording else {
            if button.lens == config.lens { setZoomFactor(button.factor, animated: true) }
            return
        }
        if button.lens != config.lens {
            pendingFactor = button.factor
            config.lens = button.lens
        } else {
            setZoomFactor(button.factor, animated: true)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func isActive(_ button: LensButton) -> Bool {
        guard button.lens == config.lens else { return false }
        let others = lensButtons.filter { $0.lens == button.lens }
        let nearest = others.min { abs($0.display - zoomDisplay) < abs($1.display - zoomDisplay) }
        return nearest == button
    }

    func flipCamera() {
        guard !isRecording else { return }
        config.lens = isFront ? .wide : .front
    }

    /// Pinch / slider zoom in user units (1 = wide lens).
    func setZoom(display: CGFloat) {
        setZoomFactor(display / lensMultiplier, animated: false)
    }

    private func setZoomFactor(_ factor: CGFloat, animated: Bool) {
        withDevice { device in
            let maxZoom = min(device.maxAvailableVideoZoomFactor, 20)
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), maxZoom)
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 16)
            } else {
                device.videoZoomFactor = clamped
            }
        }
    }

    var zoomRange: ClosedRange<CGFloat> {
        guard let device = state.device else { return 1...10 }
        let low = device.minAvailableVideoZoomFactor * lensMultiplier
        let high = min(device.maxAvailableVideoZoomFactor, 20) * lensMultiplier
        return low...max(low + 0.1, high)
    }

    // MARK: Focus / exposure / white balance

    /// `point` is normalized (0...1, top-left) inside the upright preview tile of `kind`.
    func focus(at point: CGPoint, in kind: OutputKind) {
        guard bufferSize.width > 0 else { return }
        let w = Int(bufferSize.width), h = Int(bufferSize.height)
        let rotation = CropMath.normalizedRotation(captureRotation)
        let crop = CropMath.region(kind: kind, width: w, height: h, verticalIsBufferX: rotation == 90 || rotation == 270)
        let u = isFront ? 1 - point.x : point.x, v = point.y
        let local: CGPoint
        switch rotation {
        case 90: local = CGPoint(x: v, y: 1 - u)
        case 180: local = CGPoint(x: 1 - u, y: 1 - v)
        case 270: local = CGPoint(x: 1 - v, y: u)
        default: local = CGPoint(x: u, y: v)
        }
        var devicePoint = CGPoint(x: (crop.minX + local.x * crop.width) / CGFloat(w),
                                  y: (crop.minY + local.y * crop.height) / CGFloat(h))
        if isFront {
            // The front buffer was turned upright by the connection; go back to sensor space.
            devicePoint = CGPoint(x: devicePoint.y, y: 1 - devicePoint.x)
        }
        let lockFocus = manualFocus, lockExposure = manualExposure
        withDevice { device in
            if !lockFocus, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .continuousAutoFocus
            }
            if !lockExposure, device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    private func withDevice(_ body: @escaping @Sendable (AVCaptureDevice) -> Void) {
        engine.sessionQueue.async { [engine] in
            guard let device = engine.device, (try? device.lockForConfiguration()) != nil else { return }
            body(device)
            device.unlockForConfiguration()
        }
    }

    func setISO(_ value: Float) {
        manualExposure = true
        withDevice { device in
            guard device.isExposureModeSupported(.custom) else { return }
            let format = device.activeFormat
            let iso = min(max(value, format.minISO), format.maxISO)
            device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: iso)
        }
    }

    func setShutter(_ seconds: Double) {
        manualExposure = true
        withDevice { device in
            guard device.isExposureModeSupported(.custom) else { return }
            let format = device.activeFormat
            let low = format.minExposureDuration.seconds
            let high = min(format.maxExposureDuration.seconds, device.activeVideoMaxFrameDuration.seconds)
            let clamped = min(max(seconds, low), high)
            device.setExposureModeCustom(duration: CMTime(seconds: clamped, preferredTimescale: 1_000_000),
                                         iso: AVCaptureDevice.currentISO)
        }
    }

    func setExposureAuto() {
        manualExposure = false
        withDevice { device in
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        }
    }

    func setExposureBias(_ value: Float) {
        withDevice { device in
            device.setExposureTargetBias(min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias))
        }
    }

    func setWhiteBalance(temperature: Float) {
        manualWB = true
        withDevice { device in
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            var gains = device.deviceWhiteBalanceGains(for: .init(temperature: temperature, tint: 0))
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            device.setWhiteBalanceModeLocked(with: gains)
        }
    }

    func setWhiteBalanceAuto() {
        manualWB = false
        withDevice { device in
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    func setFocus(_ position: Float) {
        manualFocus = true
        withDevice { device in
            guard device.isLockingFocusWithCustomLensPositionSupported else { return }
            device.setFocusModeLocked(lensPosition: min(max(position, 0), 1))
        }
    }

    func setFocusAuto() {
        manualFocus = false
        withDevice { device in
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }
    }

    func resetManual() {
        setExposureAuto()
        setWhiteBalanceAuto()
        setFocusAuto()
        setExposureBias(0)
    }

    func toggleTorch() {
        let on = !torchOn
        torchOn = on
        withDevice { device in
            guard device.hasTorch else { return }
            if on {
                try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            } else {
                device.torchMode = .off
            }
        }
    }

    var supportsManualFocus: Bool { state.device?.isLockingFocusWithCustomLensPositionSupported ?? false }
    var supportsManualWB: Bool { state.device?.isLockingWhiteBalanceWithCustomDeviceGainsSupported ?? false }
    var supportsManualExposure: Bool { state.device?.isExposureModeSupported(.custom) ?? false }
    var hasTorch: Bool { state.device?.hasTorch ?? false }

    var isoRange: ClosedRange<Float> {
        guard let format = state.device?.activeFormat else { return 25...3200 }
        return format.minISO...max(format.minISO + 1, format.maxISO)
    }

    var shutterRange: ClosedRange<Double> {
        guard let device = state.device else { return 1.0 / 8000...1.0 / 30 }
        let low = device.activeFormat.minExposureDuration.seconds
        let high = min(device.activeFormat.maxExposureDuration.seconds, 1.0 / max(1, state.fps))
        return low...max(low * 2, high)
    }

    var biasRange: ClosedRange<Float> {
        guard let device = state.device else { return -8...8 }
        return max(-4, device.minExposureTargetBias)...min(4, device.maxExposureTargetBias)
    }

    // MARK: Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let device = state.device else { return }
        iso = device.iso
        shutter = device.exposureDuration.seconds
        lensPosition = device.lensPosition
        exposureBias = device.exposureTargetBias
        zoomDisplay = device.videoZoomFactor * lensMultiplier
        let gains = device.deviceWhiteBalanceGains
        let maxGain = device.maxWhiteBalanceGain
        if gains.redGain >= 1, gains.greenGain >= 1, gains.blueGain >= 1,
           gains.redGain <= maxGain, gains.greenGain <= maxGain, gains.blueGain <= maxGain {
            temperature = device.temperatureAndTintValues(for: gains).temperature
        }
    }
}

enum PhotoSaver {
    static func save(_ urls: [URL], completion: @escaping @Sendable (String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion("Sem permissão para salvar no Fotos.")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for url in urls {
                    if TakeStore.isPhoto(url) {
                        PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                    } else {
                        PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }
                }
            }) { success, error in
                completion(success ? "Salvo no Fotos" : "Falha ao salvar no Fotos: \(error?.localizedDescription ?? "")")
            }
        }
    }
}

func formatShutter(_ seconds: Double) -> String {
    guard seconds > 0 else { return "—" }
    if seconds >= 0.5 { return String(format: "%.1fs", seconds) }
    return "1/\(Int((1 / seconds).rounded()))"
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    if total >= 3600 {
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
    return String(format: "%02d:%02d", total / 60, total % 60)
}
