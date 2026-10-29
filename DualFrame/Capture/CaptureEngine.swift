import AVFoundation
import CoreImage
import CoreMedia

/// A sensor format the user can pick by hand.
struct FormatInfo: Identifiable, Hashable {
    let id: String
    let width: Int
    let height: Int
    let maxFPS: Double
    let subtype: String
    let binned: Bool
    let hdr: Bool
    let stabilization: Bool

    var label: String {
        var parts = ["\(width)×\(height)", "até \(Int(maxFPS.rounded())) fps"]
        if hdr { parts.append("HDR") }
        if binned { parts.append("binned") }
        if !stabilization { parts.append("sem estab.") }
        return parts.joined(separator: " · ")
    }
}

struct SessionState {
    var device: AVCaptureDevice?
    var formats: [FormatInfo] = []
    var activeFormat: FormatInfo?
    var fps: Double = 30
    var hdrActive = false
    var stabilizationActive = "Desligada"
    var notes: [String] = []
}

/// What the live previews should show; set from the main thread, read per frame.
struct PreviewSpec {
    var rotationDegrees: Double = 90
    var mirror = false
}

/// Owns the AVCaptureSession and the recording pipeline. Not main-actor bound:
/// configuration runs on `sessionQueue`, frames arrive on `outputQueue`.
final class CaptureEngine: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "dualframe.session")
    private let outputQueue = DispatchQueue(label: "dualframe.output", qos: .userInitiated)
    private let photoQueue = DispatchQueue(label: "dualframe.photo", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var outputsAdded = false
    private(set) var device: AVCaptureDevice?
    let renderer = FrameRenderer()

    // Shared with the main thread.
    private let lock = NSLock()
    private var previewSinks: [OutputKind: AVSampleBufferDisplayLayer] = [:]
    private var previewSpec = PreviewSpec()

    // Output-queue state.
    private var pendingTake: PendingTake?
    private var pendingPhoto: (PhotoRequest, @Sendable (TakeResult) -> Void)?
    private var writer: TakeWriter?
    private var frameCount = 0
    private var audioCount = 0
    private var lastBufferSize = CGSize.zero
    var wantsHistogram = false

    var onHistogram: (@Sendable ([Float]) -> Void)?
    var onAudioLevel: (@Sendable (Float) -> Void)?
    var onBufferSize: (@Sendable (CGSize) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    // MARK: Previews

    func setPreviewSink(_ layer: AVSampleBufferDisplayLayer?, for kind: OutputKind) {
        lock.lock()
        previewSinks[kind] = layer
        lock.unlock()
    }

    /// Unregisters `layer` only if it is still the sink for `kind` (a newer view may have replaced it).
    func removePreviewSink(_ layer: AVSampleBufferDisplayLayer, for kind: OutputKind) {
        lock.lock()
        if previewSinks[kind] === layer { previewSinks[kind] = nil }
        lock.unlock()
    }

    func setPreviewSpec(_ spec: PreviewSpec) {
        lock.lock()
        previewSpec = spec
        lock.unlock()
    }

    private func pushPreviews(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        lock.lock()
        let sinks = previewSinks
        let spec = previewSpec
        lock.unlock()
        guard !sinks.isEmpty else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let rotation = CropMath.normalizedRotation(spec.rotationDegrees)
        let verticalIsBufferX = rotation == 90 || rotation == 270
        for (kind, layer) in sinks {
            let crop = CropMath.region(kind: kind, width: width, height: height, verticalIsBufferX: verticalIsBufferX)
            let upright = CropMath.uprightSize(crop.size, rotationDegrees: Double(rotation))
            let scale = min(1, 960 / max(upright.width, upright.height))
            let size = CGSize(width: CropMath.even(upright.width * scale), height: CropMath.even(upright.height * scale))
            let image = renderer.image(from: pixelBuffer, crop: crop, rotation: rotation, mirror: spec.mirror, size: size)
            guard let frame = renderer.render(image, size: size, format: kCVPixelFormatType_32BGRA,
                                              colorSpace: FrameRenderer.displaySpace, tagsFrom: nil),
                  let sample = Self.displaySample(frame, time: time) else { continue }
            let sink = layer.sampleBufferRenderer
            if sink.status == .failed { sink.flush() }
            sink.enqueue(sample)
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

        let candidates = device.formats.filter(Self.isFourByThree)
        var seen = Set<String>()
        state.formats = candidates.map(Self.info).filter { seen.insert($0.id).inserted }.sorted {
            ($0.width, $0.maxFPS) > ($1.width, $1.maxFPS)
        }

        let chosen: AVCaptureDevice.Format?
        if let override = config.formatOverride,
           let match = candidates.first(where: { Self.info($0).id == override }) {
            chosen = match
        } else {
            chosen = Self.pickFormat(candidates, config: config, notes: &state.notes)
        }

        let wantsHDR = config.mode == .video && config.hdr
            && (chosen?.supportedColorSpaces.contains(.HLG_BT2020) ?? false)
        if config.hdr && config.mode == .video && !wantsHDR {
            state.notes.append("Este formato do sensor não grava HDR; gravando em SDR.")
        }

        do {
            try device.lockForConfiguration()
            if let chosen {
                device.activeFormat = chosen
                let maxFPS = Self.maxFPS(chosen)
                let fps = min(Double(config.fps), maxFPS)
                if fps < Double(config.fps) {
                    state.notes.append("Este formato chega a \(Int(maxFPS)) fps; usando \(Int(fps)) fps.")
                }
                let duration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                state.fps = fps
                state.activeFormat = Self.info(chosen)
            }
            let colorSpace: AVCaptureColorSpace = wantsHDR ? .HLG_BT2020 : .sRGB
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
        state.hdrActive = wantsHDR

        // 10-bit buffers for HLG, full-range 8-bit otherwise.
        let available = videoOutput.availableVideoPixelFormatTypes
        let preferred: [OSType] = wantsHDR
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
            state.stabilizationActive = applyStabilization(config.mode == .photo ? .off : config.stabilization,
                                                           connection: connection, format: device.activeFormat)
        }
        return state
    }

    private func applyStabilization(_ choice: StabilizationChoice, connection: AVCaptureConnection,
                                    format: AVCaptureDevice.Format) -> String {
        guard connection.isVideoStabilizationSupported else { return "Indisponível" }
        let wanted: [AVCaptureVideoStabilizationMode]
        switch choice {
        case .off: wanted = [.off]
        case .standard: wanted = [.standard]
        case .cinematic: wanted = [.cinematic, .standard]
        case .cinematicExtended: wanted = [.cinematicExtended, .cinematic, .standard]
        }
        let mode = wanted.first(where: { $0 == .off || format.isVideoStabilizationModeSupported($0) }) ?? .off
        connection.preferredVideoStabilizationMode = mode
        switch mode {
        case .off: return choice == .off ? "Desligada" : "Não suportada neste formato"
        case .standard: return "Padrão"
        case .cinematic: return "Cinemática"
        case .cinematicExtended: return "Cinemática estendida"
        default: return "Ativa"
        }
    }

    func start() {
        if !session.isRunning { session.startRunning() }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    // MARK: Recording & photos

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

    func capturePhoto(_ request: PhotoRequest, completion: @escaping @Sendable (TakeResult) -> Void) {
        outputQueue.async { self.pendingPhoto = (request, completion) }
    }

    private func writePhotos(_ request: PhotoRequest, from pixelBuffer: CVPixelBuffer,
                             completion: @escaping @Sendable (TakeResult) -> Void) {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let rotation = CropMath.normalizedRotation(request.rotationDegrees)
        let plans = CropMath.plans(kinds: request.outputs, resolutions: [:], bufferWidth: width,
                                   bufferHeight: height, rotationDegrees: request.rotationDegrees)
        // CIImages keep the capture buffer alive until encoding is done on the photo queue.
        let images: [(OutputKind, CIImage)] = plans.map { plan in
            let size = CropMath.uprightSize(plan.crop.size, rotationDegrees: Double(rotation))
            return (plan.kind, renderer.image(from: pixelBuffer, crop: plan.crop, rotation: rotation,
                                              mirror: request.mirror, size: size))
        }
        let encoder = self.renderer
        photoQueue.async {
            var urls: [URL] = []
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: request.folder, withIntermediateDirectories: true)
                for (kind, image) in images {
                    let url = request.folder.appendingPathComponent("\(request.baseName)_\(kind.fileSuffix).heic")
                    try encoder.writeHEIC(image, to: url)
                    urls.append(url)
                }
            } catch {
                failure = error.localizedDescription
            }
            completion(TakeResult(folder: request.folder, urls: urls, droppedFrames: 0, error: failure))
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
        if let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            lenses.append((.ultraWide, min(0.5, max(0.5, multiplier(ultra)))))
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

    static func info(_ format: AVCaptureDevice.Format) -> FormatInfo {
        let d = dimensions(format)
        let fps = maxFPS(format)
        let hdr = format.supportedColorSpaces.contains(.HLG_BT2020)
        let id = "\(d.width)x\(d.height)@\(Int(fps))\(format.isVideoBinned ? "-b" : "")\(hdr ? "-h" : "")"
        return FormatInfo(id: id, width: Int(d.width), height: Int(d.height), maxFPS: fps, subtype: subtype(format),
                          binned: format.isVideoBinned, hdr: hdr,
                          stabilization: format.isVideoStabilizationModeSupported(.standard))
    }

    /// Resolution first (ContentCam's rule: largest-enough 4:3 format), then HDR, then stabilization.
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
        let wantsFPS = config.mode == .photo ? 30 : Double(config.fps)
        var pool = formats.filter { maxFPS($0) >= wantsFPS }
        if pool.isEmpty {
            notes.append("Nenhum formato 4:3 chega a \(config.fps) fps.")
            pool = formats
        }
        let bigEnough = pool.filter { Int(dimensions($0).width) >= min(config.requiredFormatWidth, 1 << 20) }
        if !bigEnough.isEmpty {
            pool = bigEnough
        } else if config.mode == .video {
            // Keep only the largest formats that reach the frame rate.
            let best = pool.map(area).max() ?? 0
            pool = pool.filter { area($0) == best }
            notes.append("A \(config.fps) fps o sensor entrega no máximo \(dimensions(pool[0]).width)×\(dimensions(pool[0]).height) em 4:3.")
        }
        if config.mode == .video {
            if config.hdr {
                let hdr = pool.filter { $0.supportedColorSpaces.contains(.HLG_BT2020) }
                if !hdr.isEmpty { pool = hdr }
            } else {
                let sdr = pool.filter { subtype($0) != "x420" }
                if !sdr.isEmpty { pool = sdr }
            }
            if config.stabilization != .off {
                let stable = pool.filter { $0.isVideoStabilizationModeSupported(.standard) }
                if !stable.isEmpty { pool = stable }
            }
        }
        return pool.sorted { a, b in
            if area(a) != area(b) {
                // Photo: biggest. Video: smallest that qualifies (cooler, fewer pixels to move).
                return config.mode == .photo ? area(a) > area(b) : area(a) < area(b)
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
            if let photo = pendingPhoto {
                pendingPhoto = nil
                writePhotos(photo.0, from: pixelBuffer, completion: photo.1)
            }
            writer?.appendVideo(sampleBuffer, pixelBuffer: pixelBuffer)
            pushPreviews(pixelBuffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

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
