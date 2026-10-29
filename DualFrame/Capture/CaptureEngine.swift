import AVFoundation
import CoreImage
import CoreMedia
import Photos

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
    var notes: [String] = []
}

/// What the live previews should show; set from the main thread, read per frame.
struct PreviewSpec {
    var rotationDegrees: Double = 90
    var mirror = false
}

private final class WeakLayer {
    weak var layer: AVSampleBufferDisplayLayer?
    init(_ layer: AVSampleBufferDisplayLayer) { self.layer = layer }
}

/// Owns the AVCaptureSession and the capture pipeline. Not main-actor bound:
/// configuration runs on `sessionQueue`, frames arrive on `outputQueue`.
final class CaptureEngine: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "dualframe.session")
    private let outputQueue = DispatchQueue(label: "dualframe.output", qos: .userInitiated)
    private let photoQueue = DispatchQueue(label: "dualframe.photo", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
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
    private var frameCount = 0
    private var audioCount = 0
    private var lastBufferSize = CGSize.zero
    var wantsHistogram = false

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
                           object: session)
        center.addObserver(self, selector: #selector(sessionProblem(_:)),
                           name: AVCaptureSession.interruptionEndedNotification, object: session)
    }

    @objc private func sessionProblem(_ note: Notification) {
        sessionQueue.async { self.restart() }
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

    func setPreviewSpec(_ spec: PreviewSpec) {
        lock.lock()
        previewSpec = spec
        lock.unlock()
    }

    private func pushPreviews(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        lock.lock()
        let sinks = previewSinks.mapValues { $0.compactMap(\.layer) }.filter { !$0.value.isEmpty }
        let spec = previewSpec
        lock.unlock()
        guard !sinks.isEmpty else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let rotation = CropMath.normalizedRotation(spec.rotationDegrees)
        let verticalIsBufferX = rotation == 90 || rotation == 270
        let source = FrameRenderer.source(pixelBuffer, colorManaged: true)
        for (kind, layers) in sinks {
            let crop = CropMath.region(kind: kind, width: width, height: height, verticalIsBufferX: verticalIsBufferX)
            let upright = CropMath.uprightSize(crop.size, rotationDegrees: Double(rotation))
            let scale = min(1, 960 / max(upright.width, upright.height))
            let size = CGSize(width: CropMath.even(upright.width * scale), height: CropMath.even(upright.height * scale))
            let image = renderer.image(from: source, crop: crop, rotation: rotation, mirror: spec.mirror, size: size)
            guard let frame = renderer.render(image, size: size, format: kCVPixelFormatType_32BGRA,
                                              colorSpace: FrameRenderer.displaySpace, tagsFrom: nil),
                  let sample = Self.displaySample(frame, time: time) else { continue }
            for layer in layers {
                let sink = layer.sampleBufferRenderer
                if sink.status == .failed || sink.requiresFlushToResumeDecoding { sink.flush() }
                sink.enqueue(sample)
            }
        }
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
        var state = SessionState()
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
            photoOutput.maxPhotoQualityPrioritization = .quality
            photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported && config.rawPhoto
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
        if !session.isRunning { session.startRunning() }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
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
            let rawType = self.photoOutput.isAppleProRAWEnabled
                ? rawTypes.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat)
                : rawTypes.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
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
            settings.photoQualityPrioritization = request.raw ? .speed : .quality

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
            let bigEnough = pool.filter { Int(dimensions($0).width) >= config.requiredFormatWidth }
            if !bigEnough.isEmpty {
                pool = bigEnough
            } else {
                let best = pool.map(area).max() ?? 0
                pool = pool.filter { area($0) == best }
                notes.append("A \(config.fps) fps o sensor entrega no máximo \(dimensions(pool[0]).width)×\(dimensions(pool[0]).height) em 4:3.")
            }
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
            for mode in stabilizationModes(for: config.stabilization) where mode != .off {
                let stable = pool.filter { $0.isVideoStabilizationModeSupported(mode) }
                if !stable.isEmpty {
                    pool = stable
                    break
                }
            }
        }
        return pool.sorted { a, b in
            if area(a) != area(b) {
                // Stills: biggest. Video: smallest that qualifies (cooler, fewer pixels to move).
                return video ? area(a) < area(b) : area(a) > area(b)
            }
            if a.isVideoBinned != b.isVideoBinned { return !a.isVideoBinned }
            return subtype(a) == "420f"
        }.first
    }
}

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
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
            writer?.appendVideo(sampleBuffer, pixelBuffer: pixelBuffer)
            if stack != nil { stackFrame(pixelBuffer, time: time) }
            if burst != nil { collectBurst(pixelBuffer) }
            pushPreviews(pixelBuffer, time: time)

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
