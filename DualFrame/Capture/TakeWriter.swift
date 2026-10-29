import AVFoundation
import VideoToolbox

enum EncoderSettings {
    static func video(size: CGSize, codec: VideoCodecChoice, fps: Double, hdr: Bool,
                      quality: BitrateQuality) -> [String: Any] {
        // 10-bit H.264 does not exist on iPhone; HDR always goes to HEVC or ProRes.
        let codec: VideoCodecChoice = (codec == .h264 && hdr) ? .hevc : codec

        var settings: [String: Any] = [
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: colorProperties(hdr: hdr),
        ]

        let pixelsPerSecond = Double(size.width * size.height) * fps
        switch codec {
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(pixelsPerSecond * quality.bitsPerPixel),
                AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoProfileLevelKey: hdr
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

    static func colorProperties(hdr: Bool) -> [String: Any] {
        if hdr {
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
        let cropper: FrameCropper?
    }

    let folder: URL
    private var tracks: [Track] = []
    private var sessionStarted = false
    private var startTime: CMTime = .invalid
    private(set) var droppedFrames = 0

    init(pending: PendingTake, bufferWidth: Int, bufferHeight: Int, audioSettings: [String: Any]?) throws {
        folder = pending.folder
        try FileManager.default.createDirectory(at: pending.folder, withIntermediateDirectories: true)

        let plans = CropMath.plans(kinds: pending.outputs, bufferWidth: bufferWidth, bufferHeight: bufferHeight,
                                   rotationDegrees: pending.rotationDegrees, resolution: pending.resolution)
        for plan in plans {
            let url = pending.folder.appendingPathComponent("\(pending.baseName)_\(plan.kind.fileSuffix).mov")
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

            let videoSettings = EncoderSettings.video(size: plan.size, codec: pending.codec, fps: pending.fps,
                                                      hdr: pending.hdr, quality: pending.quality)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            video.expectsMediaDataInRealTime = true
            video.transform = plan.transform
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
            tracks.append(Track(plan: plan, url: url, writer: writer, video: video, adaptor: adaptor, audio: audio,
                                cropper: plan.isPassthrough ? nil : FrameCropper(plan: plan)))
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            for track in tracks { track.writer.startSession(atSourceTime: time) }
            startTime = time
            sessionStarted = true
        }
        for track in tracks where track.writer.status == .writing {
            guard track.video.isReadyForMoreMediaData else {
                droppedFrames += 1
                continue
            }
            let frame = track.cropper?.process(pixelBuffer) ?? (track.cropper == nil ? pixelBuffer : nil)
            guard let frame else {
                droppedFrames += 1
                continue
            }
            track.adaptor.append(frame, withPresentationTime: time)
        }
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
        let urls = tracks.filter { FileManager.default.fileExists(atPath: $0.url.path) }.map(\.url)
        let folder = self.folder
        group.notify(queue: .global()) {
            completion(TakeResult(folder: folder, urls: urls, droppedFrames: dropped,
                                  error: errors.joined))
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
