import AVFoundation
import VideoToolbox

enum EncoderSettings {
    /// `sourceTags`: the colour description carried by the sensor's own buffers. When present it
    /// is what the file declares, so the file always says exactly what its pixels are.
    static func video(size: CGSize, codec: VideoCodecChoice, fps: Double, range: DynamicRange,
                      quality: BitrateQuality, sourceTags: [String: Any]? = nil) -> [String: Any] {
        let tenBit = range != .sdr
        // 10-bit H.264 does not exist on iPhone; HDR and Log always go to HEVC or ProRes.
        let codec: VideoCodecChoice = (codec == .h264 && tenBit) ? .hevc : codec

        var settings: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        // Log: no explicit tags, the encoder keeps the Apple Log tags carried by the buffers.
        if range != .log, let sourceTags {
            settings[AVVideoColorPropertiesKey] = sourceTags
        } else if let color = colorProperties(range) {
            settings[AVVideoColorPropertiesKey] = color
        }

        let pixelsPerSecond = Double(size.width * size.height) * fps
        switch codec {
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(pixelsPerSecond * quality.bitsPerPixel),
                AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoProfileLevelKey: tenBit
                    ? kVTProfileLevel_HEVC_Main10_AutoLevel as String
                    : kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any]
        case .h264:
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(pixelsPerSecond * quality.bitsPerPixel * 1.6),
                AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any]
        case .prores:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        }
        return settings
    }

    /// Primaries / transfer function / matrix attached to a capture buffer, in AVVideo terms
    /// (the CoreVideo and AVFoundation constants share the same string values).
    static func colorTags(of buffer: CVPixelBuffer) -> [String: Any]? {
        func tag(_ key: CFString) -> String? {
            CVBufferCopyAttachment(buffer, key, nil) as? String
        }
        // Only values the encoder accepts; anything else falls back to the defaults.
        let primariesOK: Set<String> = [AVVideoColorPrimaries_ITU_R_709_2, AVVideoColorPrimaries_P3_D65,
                                        AVVideoColorPrimaries_ITU_R_2020, AVVideoColorPrimaries_SMPTE_C]
        let transferOK: Set<String> = [AVVideoTransferFunction_ITU_R_709_2, AVVideoTransferFunction_ITU_R_2100_HLG,
                                       AVVideoTransferFunction_SMPTE_ST_2084_PQ]
        let matrixOK: Set<String> = [AVVideoYCbCrMatrix_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_601_4,
                                     AVVideoYCbCrMatrix_ITU_R_2020]
        guard let primaries = tag(kCVImageBufferColorPrimariesKey), primariesOK.contains(primaries),
              let transfer = tag(kCVImageBufferTransferFunctionKey), transferOK.contains(transfer),
              let matrix = tag(kCVImageBufferYCbCrMatrixKey), matrixOK.contains(matrix) else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }

    static func colorProperties(_ range: DynamicRange) -> [String: Any]? {
        if range == .log { return nil }
        if range == .hdr {
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }
}

enum TakeWriterError: LocalizedError {
    case cannotAddInput(OutputKind)
    case startFailed(OutputKind, String)

    var errorDescription: String? {
        switch self {
        case .cannotAddInput(let kind): return "O codificador recusou a saída \(kind.label)."
        case .startFailed(let kind, let reason): return "Falha ao abrir \(kind.label): \(reason)"
        }
    }
}

/// Writes every requested output of one take from a single stream of sensor frames.
/// Lives entirely on the capture output queue.
final class TakeWriter {
    private struct Track {
        let plan: OutputPlan
        let url: URL
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audio: AVAssetWriterInput?
    }

    let folder: URL
    private let renderer: FrameRenderer
    private let range: DynamicRange
    private let mirror: Bool
    private let bake: Bool
    private let rotation: Int
    private var tracks: [Track] = []
    private var sessionStarted = false
    private var startTime: CMTime = .invalid
    private(set) var droppedFrames = 0

    init(pending: PendingTake, source: CVPixelBuffer, bufferWidth: Int, bufferHeight: Int,
         audioSettings: [String: Any]?, renderer: FrameRenderer) throws {
        folder = pending.folder
        self.renderer = renderer
        range = pending.dynamicRange
        mirror = pending.mirror
        bake = pending.bakeRotation
        rotation = CropMath.normalizedRotation(pending.rotationDegrees)
        try FileManager.default.createDirectory(at: pending.folder, withIntermediateDirectories: true)

        let plans = CropMath.plans(kinds: pending.outputs, resolutions: pending.resolutions,
                                   bufferWidth: bufferWidth, bufferHeight: bufferHeight,
                                   rotationDegrees: pending.rotationDegrees)
        for plan in plans {
            let url = pending.folder.appendingPathComponent("\(pending.baseName)_\(plan.kind.fileSuffix).mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            let encodedSize = pending.bakeRotation
                ? CropMath.uprightSize(plan.size, rotationDegrees: pending.rotationDegrees) : plan.size
            let videoSettings = EncoderSettings.video(size: encodedSize, codec: pending.codec, fps: pending.fps,
                                                      range: pending.dynamicRange, quality: pending.quality,
                                                      sourceTags: EncoderSettings.colorTags(of: source))
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            video.expectsMediaDataInRealTime = true
            video.transform = pending.bakeRotation ? .identity : plan.transform
            guard writer.canAdd(video) else { throw TakeWriterError.cannotAddInput(plan.kind) }
            writer.add(video)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

            var audio: AVAssetWriterInput?
            if let audioSettings {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audio = input
                }
            }

            guard writer.startWriting() else {
                throw TakeWriterError.startFailed(plan.kind, writer.error?.localizedDescription ?? "desconhecido")
            }
            tracks.append(Track(plan: plan, url: url, writer: writer, video: video, adaptor: adaptor, audio: audio))
        }
    }

    /// Returns the frames it rendered per format, so a live preview can reuse them for free.
    @discardableResult
    func appendVideo(_ sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer,
                     overlay: FrontOverlay? = nil) -> [OutputKind: CVPixelBuffer] {
        var rendered: [OutputKind: CVPixelBuffer] = [:]
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            for track in tracks { track.writer.startSession(atSourceTime: time) }
            startTime = time
            sessionStarted = true
        }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        for track in tracks where track.writer.status == .writing {
            guard track.video.isReadyForMoreMediaData else {
                droppedFrames += 1
                continue
            }
            let frame: CVPixelBuffer?
            if bake {
                // Front + back: upright pixels with the selfie window drawn in. Both cameras' encoded
                // values pass through unconverted (a colour round trip here shifted gamma and saturation).
                let size = CropMath.uprightSize(track.plan.size, rotationDegrees: Double(rotation))
                let image = renderer.image(from: pixelBuffer, crop: track.plan.crop, rotation: rotation,
                                           mirror: mirror, size: size, colorManaged: false)
                frame = renderer.render(OverlayCompositor.compose(image, size: size, overlay: overlay), size: size,
                                        format: format, colorSpace: nil, tagsFrom: pixelBuffer)
            } else if track.plan.isPassthrough && !mirror {
                frame = pixelBuffer
            } else {
                // Encoded values pass through unconverted, so SDR, HLG and Log stay bit-exact.
                let image = renderer.image(from: pixelBuffer, crop: track.plan.crop, rotation: 0,
                                           mirror: mirror, size: track.plan.size, colorManaged: false)
                frame = renderer.render(image, size: track.plan.size, format: format, colorSpace: nil,
                                        tagsFrom: pixelBuffer)
            }
            guard let frame else {
                droppedFrames += 1
                continue
            }
            track.adaptor.append(frame, withPresentationTime: time)
            rendered[track.plan.kind] = frame
        }
        return rendered
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        // Audio before the first video frame would leave a black lead-in; skip it.
        guard sessionStarted, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= startTime else { return }
        for track in tracks where track.writer.status == .writing {
            if let audio = track.audio, audio.isReadyForMoreMediaData {
                audio.append(sampleBuffer)
            }
        }
    }

    func finish(completion: @escaping @Sendable (TakeResult) -> Void) {
        guard sessionStarted else {
            tracks.forEach { $0.writer.cancelWriting() }
            try? FileManager.default.removeItem(at: folder)
            completion(TakeResult(folder: nil, urls: [], droppedFrames: 0, error: "Nenhum quadro foi gravado."))
            return
        }
        let group = DispatchGroup()
        let errors = ErrorList()
        for track in tracks {
            track.video.markAsFinished()
            track.audio?.markAsFinished()
            group.enter()
            track.writer.finishWriting {
                if track.writer.status != .completed {
                    errors.add("\(track.plan.kind.label): \(track.writer.error?.localizedDescription ?? "erro")")
                }
                group.leave()
            }
        }
        let dropped = droppedFrames
        let urls = tracks.map(\.url)
        let folder = self.folder
        group.notify(queue: .global()) {
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            completion(TakeResult(folder: folder, urls: existing, droppedFrames: dropped, error: errors.joined))
        }
    }
}

/// Thread-safe collector for per-file finalization errors.
private final class ErrorList: @unchecked Sendable {
    private var items: [String] = []
    private let lock = NSLock()

    func add(_ message: String) {
        lock.lock()
        items.append(message)
        lock.unlock()
    }

    var joined: String? {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.joined(separator: "\n")
    }
}
