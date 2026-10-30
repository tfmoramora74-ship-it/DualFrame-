import AVFoundation
import CoreImage
import CoreMedia
import Photos
import QuartzCore
import VideoToolbox

/// A sensor format the user can pick by hand.
struct FormatInfo: Identifiable, Hashable {
    let id: String
    let width: Int
    let height: Int
    let maxFPS: Double
    let subtype: String
    let binned: Bool
    let hdr: Bool
    let log: Bool
    let stabilization: String

    var label: String {
        var parts = ["\(width)×\(height)", "até \(Int(maxFPS.rounded())) fps", "estab. \(stabilization)"]
        if log { parts.append("Log") } else if hdr { parts.append("HDR") }
        if binned { parts.append("binned") }
        return parts.joined(separator: " · ")
    }
}

struct SessionState {
    var device: AVCaptureDevice?
    var formats: [FormatInfo] = []
    var activeFormat: FormatInfo?
    var fps: Double = 30
    var dynamicRange: DynamicRange = .sdr
    var stabilizationRequested = "Desligada"
    var rawAvailable = false
    var appleLogAvailable = false
    /// Front + back capture is running.
    var dualActive = false
    var notes: [String] = []
}

/// What the live previews should show; set from the main thread, read per frame.
struct PreviewSpec {
    var rotationDegrees: Double = 90
    var mirror = false
    var zebra = false
    var peaking = false
    /// A sheet covers the camera: skip preview rendering entirely.
    var paused = false
    /// Front + back: where the selfie window goes, and how to turn the front frames upright.
    var overlay: OverlaySpec?
    var frontRotation: Double = 0
    var frontMirror = true
}

private final class WeakLayer {
    weak var layer: AVSampleBufferDisplayLayer?
    /// On-screen size in pixels; previews are rendered no bigger than this.
    var pixelSize = CGSize(width: 1080, height: 1920)
    init(_ layer: AVSampleBufferDisplayLayer) { self.layer = layer }
}

/// Camera heat as AVFoundation reports it (`systemPressureState`), mapped to how much to shed.
enum ThermalLoad: Int {
    case normal, high, critical
}

/// Owns the AVCaptureSession and the capture pipeline. Not main-actor bound:
/// configuration runs on `sessionQueue`, frames arrive on `outputQueue`.
final class CaptureEngine: NSObject, @unchecked Sendable {
    /// Swapped for an AVCaptureMultiCamSession while front + back is on.
    private(set) var session = AVCaptureSession()
    private var shouldRun = false
    let sessionQueue = DispatchQueue(label: "dualframe.session")
    private let outputQueue = DispatchQueue(label: "dualframe.output", qos: .userInitiated)
    private let photoQueue = DispatchQueue(label: "dualframe.photo", qos: .userInitiated)
    private let frontQueue = DispatchQueue(label: "dualframe.front", qos: .userInitiated)
    private let frontLock = NSLock()
    // Outputs are replaced together with the session: iOS does not reliably accept an output
    // that already belonged to another (configured) session — reusing them crashed the app.
    private var videoOutput = AVCaptureVideoDataOutput()
    private var audioOutput = AVCaptureAudioDataOutput()
    private var photoOutput = AVCapturePhotoOutput()
    private var frontOutput = AVCaptureVideoDataOutput()
    private var frontInput: AVCaptureDeviceInput?
    /// Newest selfie frame (front + back); only the latest is kept so the pool keeps flowing.
    private var latestFront: CVPixelBuffer?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var outputsAdded = false
    private var photoOutputAdded = false
    private(set) var device: AVCaptureDevice?
    let renderer = FrameRenderer()

    // Shared with the main thread.
    private let lock = NSLock()
    private var previewSinks: [OutputKind: [WeakLayer]] = [:]
    private var previewSpec = PreviewSpec()

    // Output-queue state.
    private var pendingTake: PendingTake?
    private var writer: TakeWriter?
    private var stack: (request: LongExposureRequest, stacker: FrameStacker?, start: CMTime,
                        completion: @Sendable (TakeResult) -> Void)?
    private var burst: (request: BurstRequest, frames: [CVPixelBuffer], completion: @Sendable (TakeResult) -> Void)?
    private var awaitingFirstFrame = false
    private var stats = Stats()
    private var frameCount = 0
    private var audioCount = 0
    private var lastBufferSize = CGSize.zero
    var wantsHistogram = false
    /// Hardware scaler that shrinks each sensor frame once for all previews.
    private var previewScaler: VTPixelTransferSession?
    private var pressureObservation: NSKeyValueObservation?
    private(set) var thermalLoad: ThermalLoad = .normal
    var onThermalLoad: (@Sendable (ThermalLoad) -> Void)?

    // Photo-queue state.
    private var photoJobs: [Int64: PhotoJob] = [:]

    var onHistogram: (@Sendable ([Float]) -> Void)?
    var onAudioLevel: (@Sendable (Float) -> Void)?
    var onBufferSize: (@Sendable (CGSize) -> Void)?
    var onFirstFrame: (@Sendable () -> Void)?
    var onStackProgress: (@Sendable (Double) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionProblem(_:)), name: AVCaptureSession.runtimeErrorNotification,
                           object: nil)
        center.addObserver(self, selector: #selector(sessionProblem(_:)),
                           name: AVCaptureSession.interruptionEndedNotification, object: nil)
    }

    @objc private func sessionProblem(_ note: Notification) {
        sessionQueue.async {
            guard (note.object as AnyObject?) === self.session else { return }
            self.restart()
        }
    }

    /// Configures, then (re)starts the session if the camera is supposed to be on.
    func configureAndRun(_ config: CaptureConfig, start: Bool) -> SessionState {
        if start { shouldRun = true }
        let state = configure(config)
        if shouldRun, !session.isRunning { session.startRunning() }
        return state
    }

    /// Recovers a session that stopped delivering frames (runtime error, interruption, stuck reconfiguration).
    func restart() {
        if session.isRunning { session.stopRunning() }
        outputQueue.sync { awaitingFirstFrame = true }
        session.startRunning()
    }

    // MARK: Previews

    func addPreviewSink(_ layer: AVSampleBufferDisplayLayer, for kind: OutputKind) {
        lock.lock()
        var list = (previewSinks[kind] ?? []).filter { $0.layer != nil && $0.layer !== layer }
        list.append(WeakLayer(layer))
        previewSinks[kind] = list
        lock.unlock()
    }

    func removePreviewSink(_ layer: AVSampleBufferDisplayLayer, for kind: OutputKind) {
        lock.lock()
        previewSinks[kind] = (previewSinks[kind] ?? []).filter { $0.layer != nil && $0.layer !== layer }
        lock.unlock()
    }

    /// Called from the view's layout: lets small windows get small (cheap) previews.
    func setPreviewSinkSize(_ layer: AVSampleBufferDisplayLayer, pixels: CGSize) {
        guard pixels.width > 1, pixels.height > 1 else { return }
        lock.lock()
        for list in previewSinks.values {
            for sink in list where sink.layer === layer { sink.pixelSize = pixels }
        }
        lock.unlock()
    }

    func setPreviewSpec(_ spec: PreviewSpec) {
        lock.lock()
        previewSpec = spec
        lock.unlock()
    }

    private func pushPreviews(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        lock.lock()
        let sinks = previewSinks.mapValues { $0.filter { $0.layer != nil } }.filter { !$0.value.isEmpty }
        let spec = previewSpec
        lock.unlock()
        guard !sinks.isEmpty, !spec.paused else { return }

        // Previews never need more than 30 fps; when the phone is hot, drop to 15 or 10.
        let fps = device.map { 1 / max($0.activeVideoMinFrameDuration.seconds, 0.001) } ?? 30
        var every = max(1, Int((fps / 30).rounded()))
        if thermalLoad == .high { every *= 2 }
        if thermalLoad == .critical { every *= 3 }
        guard frameCount % every == 0 else { return }

        let rotation = CropMath.normalizedRotation(spec.rotationDegrees)
        let verticalIsBufferX = rotation == 90 || rotation == 270

        // One hardware downscale per frame (dedicated scaler, nearly free) instead of
        // filtering the full 12 MP frame on the GPU for every preview.
        let largestWanted = sinks.values.flatMap { $0 }.map { max($0.pixelSize.width, $0.pixelSize.height) }.max() ?? 1920
        let base = previewBase(pixelBuffer, longestNeeded: min(largestWanted, thermalLoad == .normal ? 1920 : 1280))
        let width = CVPixelBufferGetWidth(base), height = CVPixelBufferGetHeight(base)
        let source = FrameRenderer.source(base, colorManaged: true)
        let effects = thermalLoad == .normal
        var selfie = frontOverlay(spec: spec)
        selfie?.showGrip = true

        for (kind, entries) in sinks {
            let crop = CropMath.region(kind: kind, width: width, height: height, verticalIsBufferX: verticalIsBufferX)
            let upright = CropMath.uprightSize(crop.size, rotationDegrees: Double(rotation))
            // Big enough to cover the largest view showing this format (aspect fill), never upscaled.
            let cover = entries.map { max($0.pixelSize.width / upright.width, $0.pixelSize.height / upright.height) }.max() ?? 1
            let scale = min(1, cover)
            let size = CGSize(width: CropMath.even(upright.width * scale), height: CropMath.even(upright.height * scale))
            var image = renderer.image(from: source, crop: crop, rotation: rotation, mirror: spec.mirror, size: size)
            if effects, spec.peaking { image = Self.peaking(image) }
            image = OverlayCompositor.compose(image, size: size, overlay: selfie)
            if effects, spec.zebra { image = Self.zebra(image) }
            guard let frame = renderer.render(image, size: size, format: kCVPixelFormatType_32BGRA,
                                              colorSpace: FrameRenderer.displaySpace, tagsFrom: nil, preview: true),
                  let sample = Self.displaySample(frame, time: time) else { continue }
            for entry in entries {
                guard let layer = entry.layer else { continue }
                let sink = layer.sampleBufferRenderer
                if sink.status == .failed || sink.requiresFlushToResumeDecoding { sink.flush() }
                sink.enqueue(sample)
            }
        }
    }

    /// The sensor frame shrunk by the hardware scaler to roughly what the previews need
    /// (half or quarter size), or the frame itself when it is already small.
    private func previewBase(_ pixelBuffer: CVPixelBuffer, longestNeeded: CGFloat) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let longest = CGFloat(max(width, height))
        var factor = 1
        while longest / CGFloat(factor * 2) >= longestNeeded { factor *= 2 }
        guard factor > 1 else { return pixelBuffer }
        if previewScaler == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            previewScaler = session
        }
        let size = CGSize(width: CropMath.even(Double(width / factor)), height: CropMath.even(Double(height / factor)))
        guard let scaler = previewScaler,
              let small = renderer.emptyBuffer(size: size, format: CVPixelBufferGetPixelFormatType(pixelBuffer)) else {
            return pixelBuffer
        }
        CVBufferPropagateAttachments(pixelBuffer, small)
        CVBufferRemoveAttachment(small, kCVImageBufferCleanApertureKey)
        return VTPixelTransferSessionTransferImage(scaler, from: pixelBuffer, to: small) == noErr ? small : pixelBuffer
    }

    /// Sends an already rendered (YUV) frame straight to the preview layers; the layer scales it.
    private func showRecordedFrame(_ frame: CVPixelBuffer, kind: OutputKind, time: CMTime, spec: PreviewSpec) -> Bool {
        lock.lock()
        let layers = (previewSinks[kind] ?? []).compactMap(\.layer)
        lock.unlock()
        guard !spec.paused, !layers.isEmpty, let sample = Self.displaySample(frame, time: time) else { return false }
        for layer in layers {
            let sink = layer.sampleBufferRenderer
            if sink.status == .failed || sink.requiresFlushToResumeDecoding { sink.flush() }
            sink.enqueue(sample)
        }
        return true
    }

    // MARK: Diagnostics

    /// Frames per second actually delivered, average processing time and drops (output queue only).
    struct Stats {
        var frames = 0
        var dropped = 0
        var busy: Double = 0
        var windowStart: CFTimeInterval = 0

        mutating func frame(processing: Double, at now: CFTimeInterval) {
            if windowStart == 0 { windowStart = now }
            frames += 1
            busy += processing
        }
    }

    struct Diagnostics: Equatable {
        var fps: Double = 0
        var processingMs: Double = 0
        var dropped = 0
        var hardwareCost: Double = 0
    }

    var onDiagnostics: (@Sendable (Diagnostics) -> Void)?

    private func publishStatsIfDue() {
        let now = CACurrentMediaTime()
        guard stats.windowStart > 0, now - stats.windowStart >= 1 else { return }
        let elapsed = now - stats.windowStart
        var diagnostics = Diagnostics()
        diagnostics.fps = Double(stats.frames) / elapsed
        diagnostics.processingMs = stats.frames > 0 ? stats.busy / Double(stats.frames) * 1000 : 0
        diagnostics.dropped = stats.dropped
        if let multi = session as? AVCaptureMultiCamSession { diagnostics.hardwareCost = Double(multi.hardwareCost) }
        stats = Stats()
        onDiagnostics?(diagnostics)
    }

    // MARK: Heat

    /// Watches the camera's own heat/power report and sheds work before iOS has to throttle us.
    private func observePressure(of device: AVCaptureDevice) {
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            let level = device.systemPressureState.level
            let load: ThermalLoad
            switch level {
            case .serious: load = .high
            case .critical, .shutdown: load = .critical
            default: load = .normal
            }
            guard let self else { return }
            self.outputQueue.async {
                guard self.thermalLoad != load else { return }
                self.thermalLoad = load
                self.onThermalLoad?(load)
            }
            // Apple's advice: lower the frame rate under pressure (only when not recording).
            if load == .critical {
                self.sessionQueue.async { self.capFrameRate(24) }
            }
        }
    }

    private func capFrameRate(_ fps: Double) {
        guard let device, writer == nil, (try? device.lockForConfiguration()) != nil else { return }
        let current = 1 / max(device.activeVideoMinFrameDuration.seconds, 0.001)
        if current > fps {
            let duration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
            device.activeVideoMinFrameDuration = duration
            if device.activeVideoMaxFrameDuration < duration { device.activeVideoMaxFrameDuration = duration }
        }
        device.unlockForConfiguration()
    }

    /// Diagonal stripes where the picture is about to clip (≈ 95 % luma).
    private static func zebra(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let mask = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.9])
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.85),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35),
            "inputWidth": 5,
            "inputSharpness": 1,
        ])?.outputImage?
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .cropped(to: extent) ?? image
        return stripes.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }

    /// Paints sharp (in-focus) edges in the accent colour.
    private static func peaking(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let mask = image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 5])
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.22])
            .cropped(to: extent)
        let color = CIImage(color: CIColor(red: 0.27, green: 0.9, blue: 1)).cropped(to: extent)
        return color.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }

    private static func displaySample(_ buffer: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    // MARK: Configuration (call on sessionQueue)

    func configure(_ config: CaptureConfig) -> SessionState {
        outputQueue.sync { awaitingFirstFrame = true }
        let wantsDual = config.frontOverlay && config.mode == .video && AVCaptureMultiCamSession.isMultiCamSupported
        if wantsDual != (session is AVCaptureMultiCamSession) {
            rebuildSession(multiCam: wantsDual)
        }
        if wantsDual, let multi = session as? AVCaptureMultiCamSession {
            return configureDual(config, session: multi)
        }

        var state = SessionState()
        if config.frontOverlay && config.mode == .video {
            state.notes.append("Este iPhone não grava com as duas câmeras ao mesmo tempo.")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        if session.canSetSessionPreset(.inputPriority) { session.sessionPreset = .inputPriority }

        guard let device = Self.device(for: config.lens) else {
            state.notes.append("Nenhuma câmera disponível.")
            return state
        }
        if device.uniqueID != videoInput?.device.uniqueID {
            if let videoInput { session.removeInput(videoInput) }
            guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                state.notes.append("Não foi possível abrir a câmera.")
                return state
            }
            session.addInput(input)
            videoInput = input
        }
        self.device = device
        state.device = device
        observePressure(of: device)

        if audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        if !outputsAdded {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            outputsAdded = true
        }
        // Microphone samples are only needed while filming.
        audioOutput.connection(with: .audio)?.isEnabled = config.mode == .video
        // The photo output only lives in photo mode: it limits formats and costs bandwidth otherwise.
        if config.mode == .photo, !photoOutputAdded, session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutputAdded = true
        } else if config.mode != .photo, photoOutputAdded {
            session.removeOutput(photoOutput)
            photoOutputAdded = false
        }

        let candidates = device.formats.filter(Self.isFourByThree)
        var seen = Set<String>()
        state.formats = candidates.map(Self.info).filter { seen.insert($0.id).inserted }.sorted {
            ($0.width, $0.maxFPS) > ($1.width, $1.maxFPS)
        }
        state.appleLogAvailable = candidates.contains { $0.supportedColorSpaces.contains(.appleLog) }

        let chosen: AVCaptureDevice.Format?
        if let override = config.formatOverride,
           let match = candidates.first(where: { Self.info($0).id == override }) {
            chosen = match
        } else {
            chosen = Self.pickFormat(candidates, config: config, notes: &state.notes)
        }

        // Dynamic range: Log → Apple Log where the sensor has it, otherwise HLG (the flattest curve available).
        var range: DynamicRange = config.mode == .video ? config.dynamicRange : .sdr
        let spaces = chosen?.supportedColorSpaces ?? []
        if range == .log && !spaces.contains(.appleLog) {
            state.notes.append("Este iPhone não tem Apple Log (só iPhone 15 Pro ou mais novo). Gravando em HLG 10-bit, o perfil mais plano disponível.")
            range = .hdr
        }
        if range == .hdr && !spaces.contains(.HLG_BT2020) {
            state.notes.append("Este formato do sensor não grava HDR; gravando em SDR.")
            range = .sdr
        }
        state.dynamicRange = range

        do {
            try device.lockForConfiguration()
            if let chosen {
                device.activeFormat = chosen
                let maxFPS = Self.maxFPS(chosen)
                let fps = config.mode.isStill ? min(30, maxFPS) : min(Double(config.fps), maxFPS)
                if fps < Double(config.fps), config.mode == .video {
                    state.notes.append("Este formato chega a \(Int(maxFPS)) fps; usando \(Int(fps)) fps.")
                }
                device.activeVideoMinFrameDuration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
                if config.mode == .longExposure {
                    // Let exposures run as long as the sensor allows (the frame rate drops to match).
                    let longest = min(chosen.maxExposureDuration.seconds, 1)
                    device.activeVideoMaxFrameDuration = CMTime(seconds: max(longest, 1 / fps), preferredTimescale: 1_000_000)
                } else {
                    device.activeVideoMaxFrameDuration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
                }
                state.fps = fps
                state.activeFormat = Self.info(chosen)
            }
            let colorSpace: AVCaptureColorSpace
            switch range {
            case .log: colorSpace = .appleLog
            case .hdr: colorSpace = .HLG_BT2020
            case .sdr: colorSpace = .sRGB
            }
            if device.activeFormat.supportedColorSpaces.contains(colorSpace) {
                device.activeColorSpace = colorSpace
            }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
            device.videoZoomFactor = 1
            device.unlockForConfiguration()
        } catch {
            state.notes.append("Câmera ocupada: \(error.localizedDescription)")
        }

        let available = videoOutput.availableVideoPixelFormatTypes
        let preferred: [OSType] = range != .sdr
            ? [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
            : [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        if let pixelFormat = preferred.first(where: available.contains) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        }

        if let connection = videoOutput.connection(with: .video) {
            // Rear: keep the sensor's native landscape buffer; files get an upright transform.
            // Front: the ISP turns the buffer upright, mirroring is ours to apply.
            let angle: CGFloat = device.position == .front ? 90 : 0
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            state.stabilizationRequested = applyStabilization(config.mode == .video ? config.stabilization : .off,
                                                              connection: connection, format: device.activeFormat)
        }

        if photoOutputAdded {
            if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
                photoOutput.maxPhotoDimensions = largest
            }
            // .balanced keeps Deep Fusion / Smart HDR but not the always-on zero-lag buffers of .quality.
            photoOutput.maxPhotoQualityPrioritization = .balanced
            // Bayer DNG needs no special pipeline, so RAW on/off costs nothing until a photo is taken.
            if photoOutput.isAppleProRAWEnabled { photoOutput.isAppleProRAWEnabled = false }
            state.rawAvailable = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
            if config.rawPhoto && !state.rawAvailable {
                state.notes.append("Esta lente/formato não oferece RAW.")
            }
        }
        return state
    }

    static func stabilizationModes(for choice: StabilizationChoice) -> [AVCaptureVideoStabilizationMode] {
        var modes: [AVCaptureVideoStabilizationMode]
        switch choice {
        case .off: return [.off]
        case .standard: modes = [.standard]
        case .cinematic: modes = [.cinematic, .standard]
        case .cinematicExtended: modes = [.cinematicExtended, .cinematic, .standard]
        case .maximum: modes = [.cinematicExtended, .cinematic, .standard]
        }
        if choice == .maximum, #available(iOS 18.0, *) {
            modes.insert(.cinematicExtendedEnhanced, at: 0)
        }
        return modes
    }

    static func label(for mode: AVCaptureVideoStabilizationMode) -> String {
        if #available(iOS 18.0, *), mode == .cinematicExtendedEnhanced { return "Máxima" }
        switch mode {
        case .off: return "Desligada"
        case .standard: return "Padrão"
        case .cinematic: return "Cinemática"
        case .cinematicExtended: return "Cinemática estendida"
        case .auto: return "Automática"
        default: return "Ativa"
        }
    }

    private func applyStabilization(_ choice: StabilizationChoice, connection: AVCaptureConnection,
                                    format: AVCaptureDevice.Format) -> String {
        guard connection.isVideoStabilizationSupported else { return "Indisponível" }
        let mode = Self.stabilizationModes(for: choice)
            .first(where: { $0 == .off || format.isVideoStabilizationModeSupported($0) }) ?? .off
        connection.preferredVideoStabilizationMode = mode
        if mode == .off && choice != .off { return "Não suportada neste formato" }
        return Self.label(for: mode)
    }

    /// What the hardware is actually doing right now.
    var activeStabilization: String {
        guard let connection = videoOutput.connection(with: .video) else { return "—" }
        return Self.label(for: connection.activeVideoStabilizationMode)
    }

    func start() {
        shouldRun = true
        if !session.isRunning { session.startRunning() }
    }

    func stop() {
        shouldRun = false
        if session.isRunning { session.stopRunning() }
    }

    // MARK: Front + back (multi-cam)

    /// A session can't change type, so switching to/from multi-cam moves every input and output
    /// to a fresh session object.
    private func rebuildSession(multiCam: Bool) {
        let old = session
        if old.isRunning { old.stopRunning() }
        // Release the cameras and microphone; the old outputs are simply dropped with the old session.
        old.beginConfiguration()
        old.inputs.forEach { old.removeInput($0) }
        old.commitConfiguration()
        // Swap on the output queue so no frame callback is mid-flight comparing against them.
        outputQueue.sync {
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            frontOutput.setSampleBufferDelegate(nil, queue: nil)
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            videoOutput = AVCaptureVideoDataOutput()
            audioOutput = AVCaptureAudioDataOutput()
            photoOutput = AVCapturePhotoOutput()
            frontOutput = AVCaptureVideoDataOutput()
        }
        frontLock.lock()
        latestFront = nil
        frontLock.unlock()
        session = multiCam ? AVCaptureMultiCamSession() : AVCaptureSession()
        videoInput = nil
        audioInput = nil
        frontInput = nil
        outputsAdded = false
        photoOutputAdded = false
    }

    private func configureDual(_ config: CaptureConfig, session multi: AVCaptureMultiCamSession) -> SessionState {
        var state = SessionState()
        state.dualActive = true
        multi.beginConfiguration()
        defer { multi.commitConfiguration() }

        let backLens: LensChoice = (config.lens == .front || config.lens == .auto) ? .wide : config.lens
        guard let back = Self.device(for: backLens),
              let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            state.notes.append("Câmeras não disponíveis para frente + trás.")
            return state
        }

        // Inputs without automatic connections: multi-cam needs explicit port → output wiring.
        func attach(_ device: AVCaptureDevice, current: AVCaptureDeviceInput?) -> AVCaptureDeviceInput? {
            if let current, current.device.uniqueID == device.uniqueID { return current }
            if let current { multi.removeInput(current) }
            guard let input = try? AVCaptureDeviceInput(device: device), multi.canAddInput(input) else { return nil }
            multi.addInputWithNoConnections(input)
            return input
        }
        videoInput = attach(back, current: videoInput)
        frontInput = attach(front, current: frontInput)
        if audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let mic = AVCaptureDevice.default(for: .audio) {
            audioInput = attach(mic, current: nil)
        }
        guard let backInput = videoInput, let selfieInput = frontInput else {
            state.notes.append("Não foi possível abrir as duas câmeras.")
            return state
        }
        device = back
        state.device = back
        observePressure(of: back)

        if !outputsAdded {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            frontOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            frontOutput.setSampleBufferDelegate(self, queue: frontQueue)
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
            for output in [videoOutput, frontOutput, audioOutput] as [AVCaptureOutput] where multi.canAddOutput(output) {
                multi.addOutputWithNoConnections(output)
            }
            outputsAdded = true
        }

        func connect(_ input: AVCaptureDeviceInput, _ type: AVMediaType, position: AVCaptureDevice.Position,
                     to output: AVCaptureOutput) -> AVCaptureConnection? {
            if let existing = output.connections.first(where: { $0.inputPorts.contains { $0.input === input } }) {
                return existing
            }
            let ports = input.ports(for: type, sourceDeviceType: type == .video ? input.device.deviceType : nil,
                                    sourceDevicePosition: type == .video ? position : .unspecified)
            guard let port = ports.first ?? input.ports.first(where: { $0.mediaType == type }) else { return nil }
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard multi.canAddConnection(connection) else { return nil }
            multi.addConnection(connection)
            return connection
        }
        // Drop links to inputs that were replaced (lens change).
        for output in [videoOutput, frontOutput] as [AVCaptureOutput] {
            for connection in output.connections where !connection.inputPorts.contains(where: { $0.input === backInput || $0.input === selfieInput }) {
                multi.removeConnection(connection)
            }
        }
        let backConnection = connect(backInput, .video, position: .back, to: videoOutput)
        let frontConnection = connect(selfieInput, .video, position: .front, to: frontOutput)
        if let audioInput { _ = connect(audioInput, .audio, position: .unspecified, to: audioOutput) }

        // Biggest 4:3 back format that fits the shared hardware budget, with a modest selfie format.
        let fps = min(Double(config.fps), 30)
        // 1920×1440 gives an exact 1080×1920 vertical with no scaling; bigger modes cost bandwidth
        // and heat for no gain at HD, so they come last.
        let backFormats = back.formats
            .filter { $0.isMultiCamSupported && Self.isFourByThree($0) && Self.maxFPS($0) >= fps }
            .sorted {
                let a = Int(Self.dimensions($0).width), b = Int(Self.dimensions($1).width)
                let aFits = a <= 1920, bFits = b <= 1920
                if aFits != bFits { return aFits }
                return a > b
            }
        let frontFormats = front.formats
            .filter { $0.isMultiCamSupported && Self.isFourByThree($0) && Self.maxFPS($0) >= fps }
            .sorted { Self.dimensions($0).width < Self.dimensions($1).width }
        let duration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
        // Selfie: HD = smallest format ≥ 1280 wide; Máx = largest, stepping down until both fit.
        let hdFront = frontFormats.first { Self.dimensions($0).width >= 1280 } ?? frontFormats.last
        let frontChoices: [AVCaptureDevice.Format] = config.frontResolution == .hd
            ? [hdFront].compactMap { $0 }
            : Array(frontFormats.reversed())

        func apply(_ format: AVCaptureDevice.Format, to device: AVCaptureDevice) {
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.activeFormat = format
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.videoZoomFactor = 1
            device.unlockForConfiguration()
        }
        // The back camera has priority: for each back format (largest first) try the selfie
        // formats until the pair fits the shared hardware budget.
        var fitted = false
        search: for backFormat in backFormats {
            apply(backFormat, to: back)
            state.activeFormat = Self.info(backFormat)
            for frontFormat in frontChoices {
                apply(frontFormat, to: front)
                if multi.hardwareCost <= 1 {
                    fitted = true
                    let d = Self.dimensions(frontFormat)
                    state.notes.append("Selfie em \(d.width)×\(d.height).")
                    break search
                }
            }
        }
        if !fitted, let smallest = frontFormats.first { apply(smallest, to: front) }
        state.fps = fps
        if config.fps > 30 { state.notes.append("Com as duas câmeras o limite é 30 fps.") }
        if config.dynamicRange != .sdr { state.notes.append("Com as duas câmeras a gravação é em SDR.") }
        if multi.hardwareCost > 1 { state.notes.append("As duas câmeras passam do limite de hardware deste iPhone.") }

        for output in [videoOutput, frontOutput] {
            if output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            }
        }
        if let backConnection {
            if backConnection.isVideoRotationAngleSupported(0) { backConnection.videoRotationAngle = 0 }
            state.stabilizationRequested = applyStabilization(config.stabilization, connection: backConnection,
                                                              format: back.activeFormat)
        }
        if let frontConnection {
            // Selfie frames arrive upright for a phone held upright; mirroring is applied when compositing.
            if frontConnection.isVideoRotationAngleSupported(90) { frontConnection.videoRotationAngle = 90 }
            if frontConnection.isVideoMirroringSupported {
                frontConnection.automaticallyAdjustsVideoMirroring = false
                frontConnection.isVideoMirrored = false
            }
        }
        state.formats = []
        return state
    }

    /// The newest selfie frame, upright for the way the phone is held, as a compositing layer.
    /// `managed: false` keeps the selfie's encoded values (for files composed without colour conversion).
    private func frontOverlay(spec: PreviewSpec, managed: Bool = true) -> FrontOverlay? {
        frontLock.lock()
        let latest = latestFront
        frontLock.unlock()
        guard let overlay = spec.overlay, let front = latest else { return nil }
        var image = FrameRenderer.source(front, colorManaged: managed)
        if let orientation = FrameRenderer.orientation(for: CropMath.normalizedRotation(spec.frontRotation)) {
            image = image.oriented(orientation)
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if spec.frontMirror {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0))
        }
        return FrontOverlay(image: image, spec: overlay)
    }

    // MARK: Recording

    func startRecording(_ take: PendingTake) {
        outputQueue.async { self.pendingTake = take }
    }

    func stopRecording(completion: @escaping @Sendable (TakeResult) -> Void) {
        outputQueue.async {
            self.pendingTake = nil
            guard let writer = self.writer else {
                completion(TakeResult(folder: nil, urls: [], droppedFrames: 0, error: "Nenhum quadro foi gravado."))
                return
            }
            self.writer = nil
            writer.finish(completion: completion)
        }
    }

    // MARK: Photos (AVCapturePhotoOutput: full-quality HEIC crops + optional DNG)

    private final class PhotoJob {
        let request: PhotoRequest
        let completion: @Sendable (TakeResult) -> Void
        var urls: [URL] = []
        var error: String?
        init(request: PhotoRequest, completion: @escaping @Sendable (TakeResult) -> Void) {
            self.request = request
            self.completion = completion
        }
    }

    func capturePhoto(_ request: PhotoRequest, completion: @escaping @Sendable (TakeResult) -> Void) {
        sessionQueue.async {
            guard self.photoOutputAdded else {
                completion(TakeResult(folder: nil, urls: [], droppedFrames: 0, error: "Câmera de foto não está pronta."))
                return
            }
            let settings: AVCapturePhotoSettings
            let rawTypes = self.photoOutput.availableRawPhotoPixelFormatTypes
            let rawType = rawTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
            if request.raw, let rawType {
                let processed: [String: Any]? = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                    ? [AVVideoCodecKey: AVVideoCodecType.hevc] : nil
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: processed)
            } else if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = request.raw ? .speed : .balanced

            if let connection = self.photoOutput.connection(with: .video) {
                let front = self.device?.position == .front
                let angle = CGFloat(front ? 90 : request.rotationDegrees)
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = front && request.mirror
                }
            }
            let job = PhotoJob(request: request, completion: completion)
            self.photoQueue.sync { self.photoJobs[settings.uniqueID] = job }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Writes one HEIC per requested format, cropped from the upright processed photo.
    private func writeCrops(of upright: CIImage, request: PhotoRequest, suffix: String = "") throws -> [URL] {
        try FileManager.default.createDirectory(at: request.folder, withIntermediateDirectories: true)
        let width = Int(upright.extent.width), height = Int(upright.extent.height)
        let normalized = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX,
                                                                    y: -upright.extent.minY))
        var urls: [URL] = []
        for kind in request.outputs {
            let crop = CropMath.region(kind: kind, width: width, height: height, verticalIsBufferX: false)
            let image = renderer.image(from: normalized, crop: crop, rotation: 0, size: crop.size)
            let url = request.folder.appendingPathComponent("\(request.baseName)_\(kind.fileSuffix)\(suffix).heic")
            try renderer.writeHEIC(image, to: url)
            urls.append(url)
        }
        return urls
    }

    // MARK: Burst photos (multi-frame fusion / super resolution)

    func captureBurst(_ request: BurstRequest, completion: @escaping @Sendable (TakeResult) -> Void) {
        outputQueue.async {
            self.burst = (request, [], completion)
        }
    }

    private func collectBurst(_ pixelBuffer: CVPixelBuffer) {
        guard var current = burst else { return }
        // Copy: capture buffers come from a small pool that must keep flowing.
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let source = FrameRenderer.source(pixelBuffer, colorManaged: false)
        if let copy = renderer.render(source, size: size, format: CVPixelBufferGetPixelFormatType(pixelBuffer),
                                      colorSpace: nil, tagsFrom: pixelBuffer) {
            current.frames.append(copy)
        }
        burst = current
        guard current.frames.count >= current.request.processing.frameCount else { return }
        burst = nil

        let request = current.request
        let frames = current.frames
        let completion = current.completion
        let context = renderer.context
        photoQueue.async {
            guard let fused = PhotoFusion.fuse(frames: frames, upscale: request.processing.upscale,
                                               toneMap: request.processing == .fusion, context: context) else {
                completion(TakeResult(folder: nil, urls: [], droppedFrames: 0, error: "Não foi possível fundir os quadros."))
                return
            }
            do {
                let urls = try self.writeCrops(of: Self.upright(fused.image, request: request.photo), request: request.photo)
                completion(TakeResult(folder: request.photo.folder, urls: urls, droppedFrames: 0, error: nil))
            } catch {
                completion(TakeResult(folder: request.photo.folder, urls: [], droppedFrames: 0,
                                      error: error.localizedDescription))
            }
        }
    }

    /// Turns a sensor-orientation still upright (and mirrors it for the front camera if asked).
    private static func upright(_ image: CIImage, request: PhotoRequest) -> CIImage {
        var image = image
        if let orientation = FrameRenderer.orientation(for: CropMath.normalizedRotation(request.rotationDegrees)) {
            image = image.oriented(orientation)
        }
        if request.mirror {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0))
        }
        return image
    }

    // MARK: Long exposure (frame stacking)

    func startLongExposure(_ request: LongExposureRequest, completion: @escaping @Sendable (TakeResult) -> Void) {
        outputQueue.async {
            self.stack = (request, nil, .invalid, completion)
        }
    }

    func cancelLongExposure() {
        outputQueue.async {
            guard let stack = self.stack else { return }
            self.stack = nil
            stack.completion(TakeResult(folder: nil, urls: [], droppedFrames: 0, error: "Longa exposição cancelada."))
        }
    }

    private func stackFrame(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        guard var current = stack else { return }
        if current.stacker == nil {
            current.stacker = FrameStacker(renderer: renderer, width: CVPixelBufferGetWidth(pixelBuffer),
                                           height: CVPixelBufferGetHeight(pixelBuffer), blend: current.request.blend)
            current.start = time
            guard current.stacker != nil else {
                stack = nil
                current.completion(TakeResult(folder: nil, urls: [], droppedFrames: 0, error: "Memória insuficiente para a longa exposição."))
                return
            }
        }
        current.stacker?.add(pixelBuffer)
        let elapsed = (time - current.start).seconds
        let progress = min(1, elapsed / current.request.seconds)
        onStackProgress?(progress)
        stack = current
        guard progress >= 1, let stacker = current.stacker else { return }
        stack = nil

        let request = current.request.photo
        let image = Self.upright(stacker.result(), request: request)
        let frames = stacker.count
        let completion = current.completion
        photoQueue.async {
            do {
                let urls = try self.writeCrops(of: image, request: request)
                completion(TakeResult(folder: request.folder, urls: urls, droppedFrames: 0,
                                      error: nil))
                self.onError?("\(frames) quadros empilhados")
            } catch {
                completion(TakeResult(folder: request.folder, urls: [], droppedFrames: 0, error: error.localizedDescription))
            }
        }
    }

    // MARK: Device helpers

    static func device(for lens: LensChoice) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        var position = AVCaptureDevice.Position.back
        switch lens {
        case .auto: types = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        case .wide: types = [.builtInWideAngleCamera]
        case .ultraWide: types = [.builtInUltraWideCamera, .builtInWideAngleCamera]
        case .telephoto: types = [.builtInTelephotoCamera, .builtInWideAngleCamera]
        case .front:
            types = [.builtInWideAngleCamera, .builtInTrueDepthCamera]
            position = .front
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) { return device }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Rear physical lenses and their zoom relative to the 1× wide lens (from field of view).
    static func rearLenses() -> [(LensChoice, CGFloat)] {
        guard let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return [] }
        func multiplier(_ device: AVCaptureDevice) -> CGFloat {
            let wideFOV = Double(wide.activeFormat.videoFieldOfView) * .pi / 180
            let fov = Double(device.activeFormat.videoFieldOfView) * .pi / 180
            guard fov > 0 else { return 1 }
            let raw = tan(wideFOV / 2) / tan(fov / 2)
            return CGFloat((raw * 2).rounded() / 2)
        }
        var lenses: [(LensChoice, CGFloat)] = []
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            lenses.append((.ultraWide, 0.5))
        }
        lenses.append((.wide, 1))
        if let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) {
            lenses.append((.telephoto, max(2, multiplier(tele))))
        }
        return lenses
    }

    static func dimensions(_ format: AVCaptureDevice.Format) -> CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    static func isFourByThree(_ format: AVCaptureDevice.Format) -> Bool {
        let d = dimensions(format)
        guard d.height > 0 else { return false }
        return abs(Double(d.width) / Double(d.height) - 4.0 / 3.0) < 0.01
    }

    static func maxFPS(_ format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
    }

    static func subtype(_ format: AVCaptureDevice.Format) -> String {
        let code = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(code)"
    }

    /// Strongest stabilization the format supports.
    static func bestStabilization(_ format: AVCaptureDevice.Format) -> AVCaptureVideoStabilizationMode {
        for mode in stabilizationModes(for: .maximum) where format.isVideoStabilizationModeSupported(mode) {
            return mode
        }
        return .off
    }

    static func info(_ format: AVCaptureDevice.Format) -> FormatInfo {
        let d = dimensions(format)
        let fps = maxFPS(format)
        let hdr = format.supportedColorSpaces.contains(.HLG_BT2020)
        let log = format.supportedColorSpaces.contains(.appleLog)
        let id = "\(d.width)x\(d.height)@\(Int(fps))\(format.isVideoBinned ? "-b" : "")\(hdr ? "-h" : "")\(log ? "-l" : "")"
        return FormatInfo(id: id, width: Int(d.width), height: Int(d.height), maxFPS: fps, subtype: subtype(format),
                          binned: format.isVideoBinned, hdr: hdr, log: log,
                          stabilization: label(for: bestStabilization(format)))
    }

    /// Resolution first (ContentCam's rule: largest-enough 4:3 format), then dynamic range,
    /// then the strongest stabilization the user asked for.
    static func pickFormat(_ formats: [AVCaptureDevice.Format], config: CaptureConfig,
                           notes: inout [String]) -> AVCaptureDevice.Format? {
        guard !formats.isEmpty else {
            notes.append("Esta câmera não tem formato 4:3; usando o padrão.")
            return nil
        }
        func area(_ f: AVCaptureDevice.Format) -> Int {
            let d = dimensions(f)
            return Int(d.width) * Int(d.height)
        }
        let video = config.mode == .video
        let wantsFPS = video ? Double(config.fps) : 30
        var pool = formats.filter { maxFPS($0) >= wantsFPS }
        if pool.isEmpty {
            notes.append("Nenhum formato 4:3 chega a \(config.fps) fps.")
            pool = formats
        }
        if video {
            let space: AVCaptureColorSpace? = config.dynamicRange == .log ? .appleLog
                : (config.dynamicRange == .hdr ? .HLG_BT2020 : nil)
            if let space {
                var matching = pool.filter { $0.supportedColorSpaces.contains(space) }
                if matching.isEmpty, space == .appleLog {
                    matching = pool.filter { $0.supportedColorSpaces.contains(.HLG_BT2020) }
                }
                if !matching.isEmpty { pool = matching }
            } else {
                let sdr = pool.filter { subtype($0) != "x420" }
                if !sdr.isEmpty { pool = sdr }
            }

            func stabilized(_ formats: [AVCaptureDevice.Format]) -> [AVCaptureDevice.Format] {
                for mode in stabilizationModes(for: config.stabilization) where mode != .off {
                    let matching = formats.filter { $0.isVideoStabilizationModeSupported(mode) }
                    if !matching.isEmpty { return matching }
                }
                return []
            }
            let big = pool.filter { Int(dimensions($0).width) >= config.requiredFormatWidth }
            let wantsBig = config.outputs.contains { config.resolution(for: $0) != .hd }
            if config.stabilization != .off {
                let bigStable = stabilized(big)
                let anyStable = stabilized(pool)
                if !bigStable.isEmpty {
                    pool = bigStable
                } else if config.preferStabilization, !wantsBig, !anyStable.isEmpty {
                    // The user chose steadiness over detail: largest sensor mode that stabilizes.
                    pool = anyStable
                    if !big.isEmpty {
                        let d = dimensions(anyStable.max(by: { area($0) < area($1) })!)
                        notes.append("Prioridade estabilização: sensor \(d.width)×\(d.height), menos nitidez que o sensor completo.")
                    }
                } else if !big.isEmpty {
                    pool = big
                    notes.append(wantsBig || anyStable.isEmpty
                        ? "Neste iPhone o sensor completo (4K) não estabiliza. Use HD com prioridade Estabilização para filmar na mão."
                        : "Sensor completo (mais nítido) sem estabilização. Para filmar na mão, mude a prioridade para Estabilização.")
                }
            } else if !big.isEmpty {
                pool = big
            }
            if pool.allSatisfy({ Int(dimensions($0).width) < config.requiredFormatWidth }), wantsBig {
                let best = pool.max(by: { area($0) < area($1) }).map(dimensions)
                if let best { notes.append("A \(config.fps) fps o sensor entrega no máximo \(best.width)×\(best.height) em 4:3.") }
            }
        }
        // Largest qualifying format: full sensor detail for the crops.
        return pool.sorted { a, b in
            if area(a) != area(b) { return area(a) > area(b) }
            if a.isVideoBinned != b.isVideoBinned { return !a.isVideoBinned }
            return subtype(a) == "420f"
        }.first
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput { stats.dropped += 1 }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === frontOutput {
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            frontLock.lock()
            latestFront = buffer
            frontLock.unlock()
            return
        }
        if output === videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if awaitingFirstFrame {
                awaitingFirstFrame = false
                onFirstFrame?()
            }
            let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
            let size = CGSize(width: width, height: height)
            if size != lastBufferSize {
                lastBufferSize = size
                onBufferSize?(size)
            }
            if let take = pendingTake {
                pendingTake = nil
                do {
                    let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                    writer = try TakeWriter(pending: take, bufferWidth: width, bufferHeight: height,
                                            audioSettings: audioInput == nil ? nil : audioSettings,
                                            renderer: renderer)
                } catch {
                    onError?(error.localizedDescription)
                }
            }
            let started = CACurrentMediaTime()
            var previewDone = false
            if let writer {
                lock.lock()
                let spec = previewSpec
                lock.unlock()
                let rendered = writer.appendVideo(sampleBuffer, pixelBuffer: pixelBuffer,
                                                  overlay: frontOverlay(spec: spec, managed: false))
                // Front + back while recording: show the frame that was just written instead of
                // rendering the same picture a second time.
                if spec.overlay != nil, let frame = rendered[.vertical] {
                    previewDone = showRecordedFrame(frame, kind: .vertical, time: time, spec: spec)
                }
            }
            if stack != nil { stackFrame(pixelBuffer, time: time) }
            if burst != nil { collectBurst(pixelBuffer) }
            if !previewDone { pushPreviews(pixelBuffer, time: time) }
            stats.frame(processing: CACurrentMediaTime() - started, at: started)
            publishStatsIfDue()

            frameCount += 1
            if wantsHistogram, frameCount % 6 == 0, let onHistogram {
                onHistogram(Histogram.compute(pixelBuffer))
            }
        } else if output === audioOutput {
            writer?.appendAudio(sampleBuffer)
            audioCount += 1
            if audioCount % 4 == 0, let onAudioLevel, let channel = connection.audioChannels.first {
                onAudioLevel(channel.averagePowerLevel)
            }
        }
    }
}

extension CaptureEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        photoQueue.async {
            guard let job = self.photoJobs[id] else { return }
            if let error {
                job.error = error.localizedDescription
                return
            }
            guard let data = photo.fileDataRepresentation() else {
                job.error = "A foto veio vazia."
                return
            }
            let request = job.request
            do {
                if photo.isRawPhoto {
                    try FileManager.default.createDirectory(at: request.folder, withIntermediateDirectories: true)
                    let url = request.folder.appendingPathComponent("\(request.baseName)_RAW.dng")
                    try data.write(to: url)
                    job.urls.append(url)
                } else if let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                    job.urls.append(contentsOf: try self.writeCrops(of: image, request: request))
                }
            } catch {
                job.error = error.localizedDescription
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        let id = resolvedSettings.uniqueID
        photoQueue.async {
            guard let job = self.photoJobs.removeValue(forKey: id) else { return }
            job.completion(TakeResult(folder: job.request.folder, urls: job.urls, droppedFrames: 0,
                                      error: job.error ?? error?.localizedDescription))
        }
    }
}
