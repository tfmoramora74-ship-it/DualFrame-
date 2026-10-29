import AVFoundation
import Photos
import SwiftUI
import UIKit

enum ManualControl: String, CaseIterable, Identifiable {
    case iso, shutter, whiteBalance, focus, exposureBias, zoom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iso: return "ISO"
        case .shutter: return "S"
        case .whiteBalance: return "WB"
        case .focus: return "F"
        case .exposureBias: return "EV"
        case .zoom: return "ZOOM"
        }
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
            refreshGuides()
        }
    }
    @Published private(set) var state = SessionState()
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var histogram: [Float] = []
    @Published private(set) var audioLevel: Float = -160
    @Published private(set) var bufferSize = CGSize.zero
    @Published private(set) var guides: [(kind: OutputKind, rect: CGRect)] = []
    @Published private(set) var captureRotation: Double = 90
    @Published var toast: String?
    @Published private(set) var authorized = false
    @Published private(set) var denied = false

    // Live device readouts.
    @Published private(set) var iso: Float = 0
    @Published private(set) var shutter: Double = 0
    @Published private(set) var temperature: Float = 5000
    @Published private(set) var tint: Float = 0
    @Published private(set) var lensPosition: Float = 0.5
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var zoomDisplay: CGFloat = 1
    @Published private(set) var manualExposure = false
    @Published private(set) var manualWB = false
    @Published private(set) var manualFocus = false
    @Published private(set) var torchOn = false
    @Published private(set) var zoomPresets: [CGFloat] = [1]

    let engine = CaptureEngine()
    let previewLayer = AVCaptureVideoPreviewLayer()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    private var pollTimer: Timer?
    private var recordTimer: Timer?
    private var recordStart = Date()
    private var zoomBase: CGFloat = 1
    private var lockedRotation: Double?

    init() {
        config = CaptureConfig.load()
        previewLayer.session = engine.session
        previewLayer.videoGravity = .resizeAspect
        engine.wantsHistogram = config.showHistogram
        engine.onHistogram = { [weak self] values in
            Task { @MainActor in self?.histogram = values }
        }
        engine.onAudioLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        engine.onBufferSize = { [weak self] size in
            Task { @MainActor in
                self?.bufferSize = size
                self?.refreshGuides()
            }
        }
        engine.onError = { [weak self] message in
            Task { @MainActor in self?.toast = message }
        }
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
            Task { @MainActor [weak self] in
                self?.apply(newState)
            }
        }
    }

    private func apply(_ newState: SessionState) {
        state = newState
        if let warning = newState.warnings.first { toast = warning }
        guard let device = newState.device else { return }
        setupRotation(device: device)
        computeZoomPresets(device: device)
        torchOn = false
        manualExposure = false
        manualWB = false
        manualFocus = false
        refreshGuides()
    }

    // MARK: Rotation

    private func setupRotation(device: AVCaptureDevice) {
        rotationObservations.removeAll()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor in
                guard let connection = self?.previewLayer.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        })
        rotationObservations.append(coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = Double(coordinator.videoRotationAngleForHorizonLevelCapture)
            Task { @MainActor in
                guard let self, self.lockedRotation == nil else { return }
                self.captureRotation = angle
                self.refreshGuides()
            }
        })
    }

    func refreshGuides() {
        guard bufferSize.width > 0 else { guides = []; return }
        let w = Int(bufferSize.width), h = Int(bufferSize.height)
        let plans = CropMath.plans(kinds: config.outputs, bufferWidth: w, bufferHeight: h,
                                   rotationDegrees: lockedRotation ?? captureRotation, resolution: config.resolution)
        guides = plans.map { ($0.kind, $0.normalizedCrop(bufferWidth: w, bufferHeight: h)) }
    }

    /// Output sizes of the current setup, for the info line.
    var outputSummary: String {
        guard bufferSize.width > 0 else { return "" }
        let plans = CropMath.plans(kinds: config.outputs, bufferWidth: Int(bufferSize.width),
                                   bufferHeight: Int(bufferSize.height),
                                   rotationDegrees: captureRotation, resolution: config.resolution)
        return plans.map { plan in
            let upright = CropMath.normalizedRotation(captureRotation) % 180 == 90
            let w = Int(upright ? plan.size.height : plan.size.width)
            let h = Int(upright ? plan.size.width : plan.size.height)
            return "\(plan.kind.shortLabel) \(w)×\(h)"
        }.joined(separator: "  ·  ")
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording, !isFinishing else { return }
        guard !config.outputs.isEmpty else {
            toast = "Escolha pelo menos uma saída."
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "DF_" + formatter.string(from: Date())
        let rotation = captureRotation
        lockedRotation = rotation
        let take = PendingTake(outputs: config.outputs, resolution: config.resolution, codec: config.codec,
                               quality: config.quality, fps: state.fps, hdr: state.hdrActive,
                               rotationDegrees: rotation, folder: TakeStore.root.appendingPathComponent(name),
                               baseName: name)
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
        isFinishing = true
        recordTimer?.invalidate()
        recordTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let saveToPhotos = config.saveToPhotos
        engine.stopRecording { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isFinishing = false
                self.lockedRotation = nil
                self.refreshGuides()
                if let error = result.error {
                    self.toast = error
                } else {
                    var message = "\(result.urls.count) arquivo(s) salvos"
                    if result.droppedFrames > 0 { message += " · \(result.droppedFrames) quadros perdidos" }
                    self.toast = message
                }
                NotificationCenter.default.post(name: TakeStore.didChange, object: nil)
                if saveToPhotos, !result.urls.isEmpty {
                    PhotoSaver.save(result.urls) { [weak self] message in
                        Task { @MainActor in self?.toast = message }
                    }
                }
            }
        }
    }

    // MARK: Device controls

    private func withDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        engine.sessionQueue.async { [engine] in
            guard let device = engine.device, (try? device.lockForConfiguration()) != nil else { return }
            body(device)
            device.unlockForConfiguration()
        }
    }

    private func computeZoomPresets(device: AVCaptureDevice) {
        var presets: [CGFloat] = [1, 2]
        zoomBase = 1
        if device.isVirtualDevice {
            let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            let types = device.constituentDevices.map(\.deviceType)
            let hasUltraWide = types.contains(.builtInUltraWideCamera)
            if hasUltraWide { zoomBase = switchOvers.first ?? 2 }
            presets = []
            if hasUltraWide { presets.append(1 / zoomBase) }
            presets.append(contentsOf: [1, 2])
            if types.contains(.builtInTelephotoCamera), let tele = switchOvers.last {
                let value = (tele / zoomBase * 10).rounded() / 10
                if value > 2 { presets.append(value) }
            }
        }
        zoomPresets = presets
        setZoom(display: 1, animated: false)
    }

    func setZoom(display: CGFloat, animated: Bool) {
        let base = zoomBase
        withDevice { device in
            let maxZoom = min(device.maxAvailableVideoZoomFactor, base * 25)
            let factor = min(max(display * base, device.minAvailableVideoZoomFactor), maxZoom)
            if animated {
                device.ramp(toVideoZoomFactor: factor, withRate: 12)
            } else {
                device.videoZoomFactor = factor
            }
        }
    }

    var zoomRange: ClosedRange<CGFloat> {
        guard let device = state.device else { return 1...10 }
        let low = device.minAvailableVideoZoomFactor / zoomBase
        let high = min(device.maxAvailableVideoZoomFactor, zoomBase * 25) / zoomBase
        return low...max(low + 0.1, high)
    }

    func focusAndExpose(at devicePoint: CGPoint) {
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
            device.isSubjectAreaChangeMonitoringEnabled = false
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

    func setWhiteBalance(temperature: Float, tint: Float) {
        manualWB = true
        withDevice { device in
            guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            var gains = device.deviceWhiteBalanceGains(for: .init(temperature: temperature, tint: tint))
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

    func resetAll() {
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
        return device.minExposureTargetBias...device.maxExposureTargetBias
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
        zoomDisplay = device.videoZoomFactor / zoomBase
        let gains = device.deviceWhiteBalanceGains
        let maxGain = device.maxWhiteBalanceGain
        if gains.redGain >= 1, gains.greenGain >= 1, gains.blueGain >= 1,
           gains.redGain <= maxGain, gains.greenGain <= maxGain, gains.blueGain <= maxGain {
            let values = device.temperatureAndTintValues(for: gains)
            temperature = values.temperature
            tint = values.tint
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
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
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
    return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
}
