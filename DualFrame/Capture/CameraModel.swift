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

/// One of the round zoom buttons above the shutter (",5", "1×", "2", "3").
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

/// High-frequency values (meters). Kept apart so only the tiny views that draw them re-render.
@MainActor
final class LiveMeters: ObservableObject {
    @Published var histogram: [Float] = []
    @Published var audioLevel: Float = -160
}

/// Device readouts polled a few times per second; observed only by the zoom row and pro controls.
@MainActor
final class DeviceReadouts: ObservableObject {
    @Published var iso: Float = 0
    @Published var shutter: Double = 0
    @Published var temperature: Float = 5000
    @Published var lensPosition: Float = 0.5
    @Published var exposureBias: Float = 0
    @Published var zoomDisplay: CGFloat = 1
    @Published var activeStabilization = "—"
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
    /// The sensor is being reconfigured (lens / mode / format change); previews are frozen.
    @Published private(set) var isSwitching = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var stackProgress: Double?
    @Published private(set) var bufferSize = CGSize.zero
    @Published private(set) var flashTrigger = 0
    @Published var toast: String?
    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    @Published private(set) var lastThumbnail: UIImage?
    @Published private(set) var manualExposure = false
    @Published private(set) var manualWB = false
    @Published private(set) var manualFocus = false
    @Published private(set) var torchOn = false
    @Published private(set) var lensButtons: [LensButton] = []
    /// Focus and exposure held at a point (long press); cleared by a normal tap.
    @Published private(set) var aeafLocked = false
    /// Seconds left on the self-timer, nil when idle.
    @Published private(set) var countdown: Int?
    /// "2 h 10 min" of recording left on this setup, or photos left.
    @Published private(set) var remainingLabel = ""
    @Published private(set) var thermalWarning: String?
    @Published private(set) var previewsPaused = false

    let meters = LiveMeters()
    let motion = LevelMotion()
    private var countdownTask: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?
    let readouts = DeviceReadouts()
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
    private var reconfigureGeneration = 0
    private var pollTick = 0

    init() {
        config = CaptureConfig.load()
        engine.wantsHistogram = config.showHistogram
        let meters = self.meters
        engine.onHistogram = { values in
            Task { @MainActor in meters.histogram = values }
        }
        engine.onAudioLevel = { level in
            Task { @MainActor in
                if abs(meters.audioLevel - level) > 0.5 { meters.audioLevel = level }
            }
        }
        engine.onBufferSize = { [weak self] size in
            Task { @MainActor in self?.bufferSize = size }
        }
        engine.onFirstFrame = { [weak self] in
            Task { @MainActor in self?.isSwitching = false }
        }
        engine.onStackProgress = { [weak self] progress in
            Task { @MainActor in self?.stackProgress = progress }
        }
        engine.onError = { [weak self] message in
            Task { @MainActor in self?.toast = message }
        }
        loadLastThumbnail()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateThermal() }
        }
        updateThermal()
    }

    private func updateThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .serious: thermalWarning = "iPhone quente: pode reduzir a qualidade ou parar gravações longas."
        case .critical: thermalWarning = "iPhone muito quente: pare de gravar e deixe esfriar."
        default: thermalWarning = nil
        }
        if let thermalWarning { toast = thermalWarning }
    }

    /// Recording time (video) or photo count left on the device for the current setup.
    func updateRemaining() {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage, free > 0 else { remainingLabel = ""; return }
        if config.mode == .video {
            var bitsPerSecond = 256_000.0 * Double(config.outputs.count)
            for kind in config.outputs {
                guard let size = outputSize(for: kind) else { continue }
                let pixelsPerSecond = Double(size.width * size.height) * state.fps
                switch config.codec {
                case .hevc: bitsPerSecond += pixelsPerSecond * config.quality.bitsPerPixel
                case .h264: bitsPerSecond += pixelsPerSecond * config.quality.bitsPerPixel * 1.6
                case .prores: bitsPerSecond += pixelsPerSecond * 1.9
                }
            }
            let seconds = Double(free) * 8 / max(bitsPerSecond, 1)
            let hours = Int(seconds / 3600), minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            remainingLabel = hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
        } else {
            let perShot = config.photoProcessing == .superResolution ? 9_000_000.0 : 4_000_000.0
            let raw = config.rawPhoto && config.photoProcessing == .apple ? 25_000_000.0 : 0
            let shots = Int(Double(free) / (perShot * Double(max(1, config.outputs.count)) + raw))
            remainingLabel = "\(shots) fotos"
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
        motion.start()
    }

    func resume() {
        guard authorized else { return }
        engine.sessionQueue.async { [engine] in engine.start() }
        if !previewsPaused { motion.start() }
    }

    func suspend() {
        if isRecording { stopRecording() }
        cancelCountdown()
        engine.sessionQueue.async { [engine] in engine.stop() }
        motion.stop()
    }

    /// A sheet covers the camera: stop drawing previews and the level so the sheet stays smooth.
    func setPreviewsPaused(_ paused: Bool) {
        previewsPaused = paused
        if paused { motion.stop() } else { motion.start() }
        updatePreviewSpec()
    }

    func reconfigure(startAfter: Bool = false) {
        guard authorized, !isRecording else { return }
        isSwitching = true
        reconfigureGeneration += 1
        let generation = reconfigureGeneration
        let config = self.config
        engine.sessionQueue.async { [engine] in
            let newState = engine.configure(config)
            if startAfter { engine.start() }
            Task { @MainActor [weak self] in self?.apply(newState, generation: generation) }
        }
        // Watchdog: if no frame arrives, restart the session instead of leaving a black screen.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, self.isSwitching, generation == self.reconfigureGeneration else { return }
            self.engine.sessionQueue.async { [engine = self.engine] in engine.restart() }
        }
    }

    private func apply(_ newState: SessionState, generation: Int) {
        // A newer reconfiguration is queued; its state wins.
        guard generation == reconfigureGeneration else { return }
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
        aeafLocked = false
        updatePreviewSpec()
        updateRemaining()
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
        let held = config.followDeviceRotation ? deviceRotation : 90
        // The front buffer already arrives turned upright for portrait (90°) by the connection.
        return isFront ? held - 90 : held
    }

    private func updatePreviewSpec() {
        engine.setPreviewSpec(PreviewSpec(rotationDegrees: captureRotation, mirror: isFront,
                                          zebra: config.zebra, peaking: config.focusPeaking,
                                          paused: previewsPaused))
    }

    /// Upright size of each output for the tile captions.
    func outputSize(for kind: OutputKind) -> CGSize? {
        guard bufferSize.width > 0 else { return nil }
        let plan = CropMath.plans(kinds: [kind], resolutions: [kind: config.resolution(for: kind)],
                                  bufferWidth: Int(bufferSize.width), bufferHeight: Int(bufferSize.height),
                                  rotationDegrees: captureRotation)[0]
        if config.mode.isStill {
            return CropMath.uprightSize(plan.crop.size, rotationDegrees: captureRotation)
        }
        return CropMath.uprightSize(plan.size, rotationDegrees: captureRotation)
    }

    // MARK: Capture

    func shutterPressed() {
        guard !isSwitching else { return }
        if countdown != nil {
            cancelCountdown()
            return
        }
        // The self-timer delays starts only, never stops.
        let starting = !isRecording && stackProgress == nil
        if starting, config.timerSeconds > 0 {
            startCountdown()
            return
        }
        fireShutter()
    }

    private func startCountdown() {
        countdown = config.timerSeconds
        countdownTask = Task { [weak self] in
            while let left = self?.countdown, left > 0 {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, self?.countdown != nil else { return }
                self?.countdown = left - 1
            }
            guard let self, self.countdown == 0 else { return }
            self.countdown = nil
            self.fireShutter()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func fireShutter() {
        switch config.mode {
        case .photo: takePhoto()
        case .video: toggleRecording()
        case .longExposure: stackProgress == nil ? startLongExposure() : cancelLongExposure()
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func newTakeName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "DF_" + formatter.string(from: Date())
    }

    private var hasOutputs: Bool {
        if config.outputs.isEmpty { toast = "Ligue pelo menos um formato." }
        return !config.outputs.isEmpty
    }

    func startRecording() {
        guard !isRecording, !isBusy, hasOutputs else { return }
        let name = newTakeName()
        let rotation = captureRotation
        lockedRotation = rotation
        var resolutions: [OutputKind: OutputResolution] = [:]
        for kind in OutputKind.allCases { resolutions[kind] = config.resolution(for: kind) }
        let take = PendingTake(outputs: config.outputs, resolutions: resolutions, codec: config.codec,
                               quality: config.quality, fps: state.fps, dynamicRange: state.dynamicRange,
                               rotationDegrees: rotation, mirror: isFront && config.mirrorFront,
                               folder: TakeStore.root.appendingPathComponent(name), baseName: name)
        engine.startRecording(take)
        isRecording = true
        recordStart = Date()
        elapsed = 0
        UIApplication.shared.isIdleTimerDisabled = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
            Task { @MainActor in self?.finished(result) }
        }
    }

    private func photoRequest() -> PhotoRequest {
        let name = newTakeName()
        return PhotoRequest(outputs: config.outputs, rotationDegrees: captureRotation,
                            mirror: isFront && config.mirrorFront,
                            raw: config.rawPhoto && config.photoProcessing == .apple,
                            folder: TakeStore.root.appendingPathComponent(name), baseName: name)
    }

    func takePhoto() {
        guard !isBusy, !isRecording, hasOutputs else { return }
        isBusy = true
        flashTrigger += 1
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        let processing = config.photoProcessing
        guard processing != .apple else {
            engine.capturePhoto(photoRequest()) { [weak self] result in
                Task { @MainActor in self?.finished(result) }
            }
            return
        }
        toast = processing == .superResolution ? "Segure firme… super-resolução" : "Segure firme… fundindo quadros"
        let request = BurstRequest(photo: photoRequest(), processing: processing)
        // HDR+ idea: shoot the burst a little under to protect highlights, then lift shadows after merging.
        let underexpose = processing == .fusion && !manualExposure
        let previousBias = readouts.exposureBias
        if underexpose { setExposureBias(previousBias - 0.7) }
        Task { [weak self] in
            if underexpose { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard let self else { return }
            self.engine.captureBurst(request) { [weak self] result in
                Task { @MainActor in
                    if underexpose { self?.setExposureBias(previousBias) }
                    self?.finished(result)
                }
            }
        }
    }

    // MARK: Long exposure

    func startLongExposure() {
        guard !isBusy, hasOutputs else { return }
        isBusy = true
        stackProgress = 0
        lockedRotation = captureRotation
        UIApplication.shared.isIdleTimerDisabled = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        let request = LongExposureRequest(photo: photoRequest(), seconds: Double(config.longExposureSeconds),
                                          blend: config.longExposureBlend)
        let infinity = config.longExposureInfinityFocus && !manualFocus
        let keepExposure = manualExposure
        withDevice { device in
            if infinity, device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: 1)
            }
            // Longest exposure per frame the sensor allows (≤ 1 s); ISO stays as the user set it.
            if !keepExposure, device.isExposureModeSupported(.custom) {
                let longest = min(device.activeFormat.maxExposureDuration.seconds,
                                  device.activeVideoMaxFrameDuration.seconds)
                let iso = min(max(800, device.activeFormat.minISO), device.activeFormat.maxISO)
                device.setExposureModeCustom(duration: CMTime(seconds: longest, preferredTimescale: 1_000_000), iso: iso)
            }
        }
        // Give the sensor one frame period to settle on the new exposure before stacking.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.stackProgress != nil else { return }
            self.engine.startLongExposure(request) { [weak self] result in
                Task { @MainActor in self?.finishLongExposure(result) }
            }
        }
    }

    func cancelLongExposure() {
        engine.cancelLongExposure()
    }

    private func finishLongExposure(_ result: TakeResult) {
        stackProgress = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if !manualExposure { setExposureAuto() }
        if !manualFocus { setFocusAuto() }
        finished(result)
    }

    private func finished(_ result: TakeResult) {
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
        updateRemaining()
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
        guard !isSwitching else { return }
        guard !isRecording, stackProgress == nil else {
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

    func isActive(_ button: LensButton, zoom: CGFloat) -> Bool {
        guard button.lens == config.lens else { return false }
        let others = lensButtons.filter { $0.lens == button.lens }
        let nearest = others.min { abs($0.display - zoom) < abs($1.display - zoom) }
        return nearest == button
    }

    func flipCamera() {
        guard !isRecording, !isSwitching, stackProgress == nil else { return }
        UISelectionFeedbackGenerator().selectionChanged()
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
    /// `lock`: long press holds focus and exposure (AE/AF lock); a plain tap tracks continuously.
    func focus(at point: CGPoint, in kind: OutputKind, lock: Bool = false) {
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
        let hold = lock
        aeafLocked = lock
        if lock { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        withDevice { device in
            if !lockFocus, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                // .autoFocus focuses once and then holds; continuous keeps tracking.
                device.focusMode = hold && device.isFocusModeSupported(.autoFocus) ? .autoFocus : .continuousAutoFocus
            }
            if !lockExposure, device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = hold && device.isExposureModeSupported(.autoExpose) ? .autoExpose : .continuousAutoExposure
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
        let high = min(device.activeFormat.maxExposureDuration.seconds, device.activeVideoMaxFrameDuration.seconds)
        return low...max(low * 2, high)
    }

    var biasRange: ClosedRange<Float> {
        guard let device = state.device else { return -8...8 }
        return max(-4, device.minExposureTargetBias)...min(4, device.maxExposureTargetBias)
    }

    // MARK: Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let device = state.device else { return }
        let r = readouts
        // Assign only on change so idle readouts trigger no redraws.
        let iso = device.iso.rounded()
        if r.iso != iso { r.iso = iso }
        let shutter = device.exposureDuration.seconds
        if r.shutter != shutter { r.shutter = shutter }
        let lens = (device.lensPosition * 100).rounded() / 100
        if r.lensPosition != lens { r.lensPosition = lens }
        let bias = (device.exposureTargetBias * 10).rounded() / 10
        if r.exposureBias != bias { r.exposureBias = bias }
        let zoom = ((device.videoZoomFactor * lensMultiplier) * 10).rounded() / 10
        if r.zoomDisplay != zoom { r.zoomDisplay = zoom }
        let gains = device.deviceWhiteBalanceGains
        let maxGain = device.maxWhiteBalanceGain
        if gains.redGain >= 1, gains.greenGain >= 1, gains.blueGain >= 1,
           gains.redGain <= maxGain, gains.greenGain <= maxGain, gains.blueGain <= maxGain {
            let kelvin = (device.temperatureAndTintValues(for: gains).temperature / 50).rounded() * 50
            if r.temperature != kelvin { r.temperature = kelvin }
        }
        pollTick += 1
        if pollTick % 120 == 0 { updateRemaining() }
        if pollTick % 4 == 0 {
            engine.sessionQueue.async { [engine] in
                let label = engine.activeStabilization
                Task { @MainActor in if r.activeStabilization != label { r.activeStabilization = label } }
            }
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
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: TakeStore.isPhoto(url) ? .photo : .video, fileURL: url, options: nil)
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
