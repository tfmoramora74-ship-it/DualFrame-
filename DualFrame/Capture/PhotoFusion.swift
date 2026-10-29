import CoreImage
import CoreVideo
import Vision

/// Multi-frame photo processing in the spirit of HDR+ / Adobe Indigo:
/// a short burst is aligned to one reference frame and merged.
/// - Averaging N aligned frames cuts noise by about √N, which lets shadows be lifted cleanly.
/// - Super resolution: hand tremor shifts each frame by fractions of a pixel; resampling every
///   frame onto a finer grid at its measured offset and summing recovers real detail
///   ("shift-and-add", the idea behind Super Res Zoom).
enum PhotoFusion {
    struct Result {
        let image: CIImage
        let framesUsed: Int
    }

    /// Frames are capture buffers in sensor orientation. Returns the merged image, still in that orientation.
    static func fuse(frames: [CVPixelBuffer], upscale: CGFloat, toneMap: Bool, context: CIContext) -> Result? {
        guard !frames.isEmpty else { return nil }
        let images = frames.map { CIImage(cvPixelBuffer: $0) }

        // Reference = sharpest frame (least motion blur).
        let referenceIndex = sharpestIndex(images, context: context)
        let reference = images[referenceIndex]
        let extent = reference.extent
        let probeScale: CGFloat = 0.25
        let referenceSmall = reference.transformed(by: CGAffineTransform(scaleX: probeScale, y: probeScale))

        let output = CGRect(x: 0, y: 0, width: (extent.width * upscale).rounded(), height: (extent.height * upscale).rounded())
        guard let accumulator = CIImageAccumulator(extent: output, format: .RGBAh) else { return nil }

        var used = 0
        for (index, image) in images.enumerated() {
            var offset = CGPoint.zero
            if index != referenceIndex {
                guard let measured = translation(of: image, to: referenceSmall, probeScale: probeScale) else { continue }
                // Big jumps mean subject or camera motion: averaging them would ghost.
                if hypot(measured.x, measured.y) > 60 { continue }
                offset = measured
            }
            let aligned = image
                .transformed(by: CGAffineTransform(translationX: offset.x - extent.minX, y: offset.y - extent.minY))
                .clampedToExtent()
            let resampled = upscale == 1
                ? aligned.cropped(to: output)
                : aligned.applyingFilter("CILanczosScaleTransform",
                                         parameters: [kCIInputScaleKey: upscale, kCIInputAspectRatioKey: 1])
                    .cropped(to: output)
            let sum = used == 0
                ? resampled
                : resampled.applyingFilter("CIAdditionCompositing",
                                           parameters: [kCIInputBackgroundImageKey: accumulator.image()])
            accumulator.setImage(sum)
            used += 1
        }
        guard used > 0 else { return nil }

        let k = CGFloat(1) / CGFloat(used)
        var result = accumulator.image().applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])

        if toneMap {
            // The burst was shot ~0.7 EV under to keep highlights; open the shadows back up.
            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": 0.55,
                "inputHighlightAmount": 0.9,
                "inputRadius": 12 * upscale,
            ])
            result = result.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.35])
            result = result.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.15])
        }
        // Merged frames are clean enough to take real sharpening without amplifying noise.
        result = result.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 1.2 * upscale,
            kCIInputIntensityKey: upscale > 1 ? 0.7 : 0.45,
        ])
        return Result(image: result.cropped(to: output), framesUsed: used)
    }

    /// Offset (full-resolution pixels) that moves `image` onto the reference.
    private static func translation(of image: CIImage, to referenceSmall: CIImage, probeScale: CGFloat) -> CGPoint? {
        let small = image.transformed(by: CGAffineTransform(scaleX: probeScale, y: probeScale))
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: small, options: [:])
        let handler = VNImageRequestHandler(ciImage: referenceSmall, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        let t = observation.alignmentTransform
        return CGPoint(x: t.tx / probeScale, y: t.ty / probeScale)
    }

    /// Picks the frame with the most high-frequency energy (edge strength) on a small center crop.
    private static func sharpestIndex(_ images: [CIImage], context: CIContext) -> Int {
        var best = 0
        var bestScore: Float = -1
        for (index, image) in images.enumerated() {
            let e = image.extent
            let center = CGRect(x: e.midX - 256, y: e.midY - 256, width: 512, height: 512)
            let edges = image.cropped(to: center).applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4])
            let average = edges.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: center)])
            var pixel = [Float](repeating: 0, count: 4)
            context.render(average, toBitmap: &pixel, rowBytes: 16,
                           bounds: CGRect(origin: average.extent.origin, size: CGSize(width: 1, height: 1)),
                           format: .RGBAf, colorSpace: nil)
            let score = pixel[0] + pixel[1] + pixel[2]
            if score > bestScore {
                bestScore = score
                best = index
            }
        }
        return best
    }
}
