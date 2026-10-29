import AVFoundation
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
        var parts = ["\(width)×\(height)", "até \(Int(maxFPS.rounded())) fps", subtype]
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
    var warnings: [String] = []
}

/// Owns the AVCaptureSession and the recording pipeline. Not main-actor bound:
/// configuration runs on `sessionQueue`, frames arrive on `outputQueue`.
final class CaptureEngine: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "dualframe.session")
    private let outputQueue = DispatchQueue(label: "dualframe.output", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var outputsAdded = false
    private(set) var device: AVCaptureDevice?

    // Output-queue state.
    private var pendingTake: PendingTake?
    private var writer: TakeWriter?
    private var frameCount = 0
    private var audioCount = 0
    private var lastBufferSize = CGSize.zero
    var wantsHistogram = true

    var onHistogram: (@Sendable ([Float]) -> Void)?
    var onAudioLevel: (@Sendable (Float) -> Void)?
    var onBufferSize: (@Sendable (CGSize) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    // MARK: Configuration (call on sessionQueue)

    func configure(_ config: CaptureConfig) -> SessionState {
        var state = SessionState()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        if session.canSetSessionPreset(.inputPriority) { session.sessionPreset = .inputPriority }

        guard let device = Self.device(for: config.lens) else {
            state.warnings.append("Nenhuma câmera disponível.")
            return state
        }
        if device.uniqueID != videoInput?.device.uniqueID {
            if let videoInput { session.removeInput(videoInput) }
            guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                state.warnings.append("Não foi possível abrir a câmera.")
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
            videoOutput.alwaysDiscardsLateVideoFrames = false
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            audioOutput.setSampleBufferDelegate(self, queue: outputQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
            outputsAdded = true
        }

        let candidates = device.formats.filter(Self.isFourByThree)
        state.formats = candidates.map(Self.info).sorted {
            ($0.width, $0.maxFPS) > ($1.width, $1.maxFPS)
        }

        let chosen: AVCaptureDevice.Format?
        if let override = config.formatOverride,
           let match = candidates.first(where: { Self.info($0).id == override }) {
            chosen = match
        } else {
            chosen = Self.pickFormat(candidates, config: config, warnings: &state.warnings)
        }

        let wantsHDR = config.hdr && (chosen?.supportedColorSpaces.contains(.HLG_BT2020) ?? false)
        if config.hdr && !wantsHDR { state.warnings.append("Este formato do sensor não grava HDR; gravando em SDR.") }

        do {
            try device.lockForConfiguration()
            if let chosen {
                device.activeFormat = chosen
                let maxFPS = Self.maxFPS(chosen)
                let fps = min(Double(config.fps), maxFPS)
                if fps < Double(config.fps) {
                    state.warnings.append("Este formato chega a \(Int(maxFPS)) fps; usando \(Int(fps)) fps.")
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
            device.unlockForConfiguration()
        } catch {
            state.warnings.append("Câmera ocupada: \(error.localizedDescription)")
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
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = device.position == .front
            }
            state.stabilizationActive = applyStabilization(config.stabilization, connection: connection, format: device.activeFormat)
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
        case .auto: wanted = [.auto]
        }
        let mode = wanted.first(where: { $0 == .off || format.isVideoStabilizationModeSupported($0) }) ?? .off
        connection.preferredVideoStabilizationMode = mode
        switch mode {
        case .off: return choice == .off ? "Desligada" : "Não suportada neste formato"
        case .standard: return "Padrão"
        case .cinematic: return "Cinemática"
        case .cinematicExtended: return "Cinemática estendida"
        case .auto: return "Automática"
        default: return "Ativa"
        }
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
        let sub = subtype(format)
        let hdr = format.supportedColorSpaces.contains(.HLG_BT2020)
        let id = "\(d.width)x\(d.height)@\(Int(fps))-\(sub)\(format.isVideoBinned ? "-b" : "")\(hdr ? "-h" : "")"
        return FormatInfo(id: id, width: Int(d.width), height: Int(d.height), maxFPS: fps, subtype: sub,
                          binned: format.isVideoBinned, hdr: hdr,
                          stabilization: format.isVideoStabilizationModeSupported(.standard))
    }

    /// Mirrors ContentCam's rule (largest-enough 4:3 format, stabilizable first) with our own preferences.
    static func pickFormat(_ formats: [AVCaptureDevice.Format], config: CaptureConfig,
                           warnings: inout [String]) -> AVCaptureDevice.Format? {
        guard !formats.isEmpty else {
            warnings.append("Esta câmera não tem formato 4:3; usando o padrão.")
            return nil
        }
        let wantsFPS = Double(config.fps)
        var pool = formats.filter { maxFPS($0) >= wantsFPS }
        if pool.isEmpty {
            warnings.append("Nenhum formato 4:3 chega a \(config.fps) fps.")
            pool = formats
        }
        let hdrPool = pool.filter { $0.supportedColorSpaces.contains(.HLG_BT2020) }
        if config.hdr, !hdrPool.isEmpty {
            pool = hdrPool
        } else {
            let sdr = pool.filter { subtype($0) != "x420" }
            if !sdr.isEmpty { pool = sdr }
        }
        if config.stabilization != .off {
            let stable = pool.filter { $0.isVideoStabilizationModeSupported(.standard) }
            if !stable.isEmpty { pool = stable }
        }
        let minWidth = config.resolution.minimumFormatWidth
        let bigEnough = pool.filter { Int(dimensions($0).width) >= minWidth }
        if bigEnough.isEmpty {
            warnings.append("O sensor não entrega \(config.resolution.label) a \(config.fps) fps em 4:3; usando o maior disponível.")
        } else {
            pool = bigEnough
        }
        func area(_ f: AVCaptureDevice.Format) -> Int {
            let d = dimensions(f)
            return Int(d.width) * Int(d.height)
        }
        // HD: smallest qualifying format (cooler, longer takes). 4K/native: the full sensor.
        let sorted = pool.sorted { a, b in
            if area(a) != area(b) {
                return config.resolution == .hd ? area(a) < area(b) : area(a) > area(b)
            }
            if a.isVideoBinned != b.isVideoBinned { return !a.isVideoBinned }
            return subtype(a) == "420f"
        }
        return sorted.first
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
                    let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
                    writer = try TakeWriter(pending: take, bufferWidth: width, bufferHeight: height,
                                            audioSettings: audioInput == nil ? nil : audioSettings)
                } catch {
                    onError?(error.localizedDescription)
                }
            }
            writer?.appendVideo(sampleBuffer, pixelBuffer: pixelBuffer)

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

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {}
}
