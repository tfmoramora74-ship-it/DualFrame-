import CoreImage
import CoreVideo
import ImageIO
import Metal

/// GPU crop / rotate / scale of sensor frames for the recorded files, the live previews and photos.
/// One shared CIContext; only ever used from the capture output queue (and the photo queue for encoding).
final class FrameRenderer: @unchecked Sendable {
    let context: CIContext
    private var pools: [String: CVPixelBufferPool] = [:]
    private let poolLock = NSLock()

    static let sdrVideoSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    static let hdrVideoSpace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    static let displaySpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let photoSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    init() {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAh]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// Cuts `crop` (buffer pixels, top-left origin) out of `source`, turns it upright by `rotation`
    /// degrees, optionally mirrors it, and scales it to exactly `size`.
    func image(from source: CVPixelBuffer, crop: CGRect, rotation: Int, mirror: Bool = false,
               size: CGSize) -> CIImage {
        let height = CGFloat(CVPixelBufferGetHeight(source))
        let ciCrop = CGRect(x: crop.minX, y: height - crop.maxY, width: crop.width, height: crop.height)
        var image = CIImage(cvPixelBuffer: source).cropped(to: ciCrop)
        image = image.transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
        if let orientation = Self.orientation(for: rotation) {
            image = image.oriented(orientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        if mirror {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -image.extent.width, y: 0))
        }
        let extent = image.extent
        let scaleX = size.width / extent.width, scaleY = size.height / extent.height
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Renders into a pooled buffer of the given pixel format. Colour tags are copied from
    /// `source`, minus any clean-aperture / pixel-aspect metadata that would distort playback.
    func render(_ image: CIImage, size: CGSize, format: OSType, colorSpace: CGColorSpace,
                tagsFrom source: CVPixelBuffer?) -> CVPixelBuffer? {
        guard let pool = pool(width: Int(size.width), height: Int(size.height), format: format) else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let destination = output else { return nil }
        if let source {
            CVBufferPropagateAttachments(source, destination)
            CVBufferRemoveAttachment(destination, kCVImageBufferCleanApertureKey)
            CVBufferRemoveAttachment(destination, kCVImageBufferPixelAspectRatioKey)
        }
        context.render(image, to: destination, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        return destination
    }

    func writeHEIC(_ image: CIImage, to url: URL) throws {
        try context.writeHEIFRepresentation(of: image, to: url, format: .RGBA8, colorSpace: Self.photoSpace,
                                            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
    }

    static func orientation(for rotation: Int) -> CGImagePropertyOrientation? {
        switch CropMath.normalizedRotation(Double(rotation)) {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return nil
        }
    }

    private func pool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let key = "\(width)x\(height)-\(format)"
        poolLock.lock()
        defer { poolLock.unlock() }
        if let pool = pools[key] { return pool }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool)
        pools[key] = pool
        return pool
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
