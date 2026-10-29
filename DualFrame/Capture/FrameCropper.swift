import CoreVideo
import VideoToolbox

/// Crops and scales one sensor buffer into a pooled output buffer.
/// The crop is expressed as a clean-aperture attachment on the source, which
/// VTPixelTransferSession honours in `CropSourceToCleanAperture` mode — a single
/// hardware pass, no per-frame allocation.
final class FrameCropper {
    let plan: OutputPlan
    private var transferSession: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolFormat: OSType = 0

    init(plan: OutputPlan) {
        self.plan = plan
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        if let session {
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: kVTScalingMode_CropSourceToCleanAperture)
        }
        transferSession = session
    }

    deinit {
        if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
    }

    func process(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let transferSession else { return nil }
        let format = CVPixelBufferGetPixelFormatType(source)
        if pool == nil || format != poolFormat {
            makePool(format: format)
        }
        guard let pool else { return nil }

        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let destination = output else { return nil }

        // Carry colour tags (primaries, transfer function, matrix) over before adding the crop.
        CVBufferPropagateAttachments(source, destination)

        let width = CGFloat(CVPixelBufferGetWidth(source))
        let height = CGFloat(CVPixelBufferGetHeight(source))
        let crop = plan.crop
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: crop.width,
            kCVImageBufferCleanApertureHeightKey: crop.height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: crop.midX - width / 2,
            kCVImageBufferCleanApertureVerticalOffsetKey: crop.midY - height / 2,
        ]
        CVBufferSetAttachment(source, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
        let status = VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination)
        CVBufferRemoveAttachment(source, kCVImageBufferCleanApertureKey)

        return status == noErr ? destination : nil
    }

    private func makePool(format: OSType) {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: Int(plan.size.width),
            kCVPixelBufferHeightKey as String: Int(plan.size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 6]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &newPool)
        pool = newPool
        poolFormat = format
    }
}

enum Histogram {
    /// Luma histogram from a sparse sample of plane 0, normalized to the tallest bin.
    static func compute(_ buffer: CVPixelBuffer, bins: Int = 64) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return [] }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange

        var counts = [Int](repeating: 0, count: bins)
        let step = 16
        for y in stride(from: 0, to: height, by: step) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: step) {
                let value: Int
                if tenBit {
                    value = Int(row.load(fromByteOffset: x * 2, as: UInt16.self) >> 8)
                } else {
                    value = Int(row.load(fromByteOffset: x, as: UInt8.self))
                }
                counts[min(bins - 1, value * bins / 256)] += 1
            }
        }
        let peak = Float(max(1, counts.max() ?? 1))
        return counts.map { Float($0) / peak }
    }
}
