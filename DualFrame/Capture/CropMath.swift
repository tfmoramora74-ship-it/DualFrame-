import CoreGraphics

/// How one output is cut out of the sensor buffer.
/// Crops are expressed in the delivered buffer's own pixel space. For video files the writer's
/// `transform` turns the file upright on playback, so encoded pixels are never rotated.
struct OutputPlan {
    let kind: OutputKind
    /// Crop rectangle in buffer pixels (origin top-left).
    let crop: CGRect
    /// Encoded size, in buffer orientation.
    let size: CGSize
    let transform: CGAffineTransform
    /// The buffer goes to the encoder untouched (full sensor at native size, no mirroring).
    let isPassthrough: Bool

    /// Crop normalized to 0...1 of the buffer.
    func normalizedCrop(bufferWidth: Int, bufferHeight: Int) -> CGRect {
        CGRect(x: crop.minX / CGFloat(bufferWidth),
               y: crop.minY / CGFloat(bufferHeight),
               width: crop.width / CGFloat(bufferWidth),
               height: crop.height / CGFloat(bufferHeight))
    }
}

enum CropMath {
    static func plans(kinds: [OutputKind],
                      resolutions: [OutputKind: OutputResolution],
                      bufferWidth: Int,
                      bufferHeight: Int,
                      rotationDegrees: Double) -> [OutputPlan] {
        let rotation = normalizedRotation(rotationDegrees)
        let verticalIsBufferX = rotation == 90 || rotation == 270
        let transform = CGAffineTransform(rotationAngle: CGFloat(Double(rotation) * .pi / 180))

        return kinds.map { kind in
            let crop = region(kind: kind, width: bufferWidth, height: bufferHeight, verticalIsBufferX: verticalIsBufferX)
            let size = outputSize(crop: crop, resolution: resolutions[kind] ?? .hd)
            let passthrough = crop.width == CGFloat(bufferWidth) && crop.height == CGFloat(bufferHeight)
                && size.width == CGFloat(bufferWidth) && size.height == CGFloat(bufferHeight)
            return OutputPlan(kind: kind, crop: crop, size: size, transform: transform, isPassthrough: passthrough)
        }
    }

    static func normalizedRotation(_ degrees: Double) -> Int {
        let r = Int(degrees.rounded()) % 360
        return r < 0 ? r + 360 : r
    }

    /// Largest centered rectangle of the output's upright aspect that fits the buffer.
    static func region(kind: OutputKind, width: Int, height: Int, verticalIsBufferX: Bool) -> CGRect {
        if kind == .full { return CGRect(x: 0, y: 0, width: width, height: height) }
        // Buffer-x extent / buffer-y extent of the cut.
        let aspect = verticalIsBufferX ? 1 / kind.uprightAspect : kind.uprightAspect
        var w = Double(width)
        var h = w / aspect
        if h > Double(height) {
            h = Double(height)
            w = h * aspect
        }
        let cw = even(w), ch = even(h)
        let x = even(Double(width - cw) / 2), y = even(Double(height - ch) / 2)
        return CGRect(x: x, y: y, width: cw, height: ch)
    }

    static func outputSize(crop: CGRect, resolution: OutputResolution) -> CGSize {
        let longSide = max(crop.width, crop.height)
        guard let target = resolution.longSide else {
            return CGSize(width: even(Double(crop.width)), height: even(Double(crop.height)))
        }
        let scale = Double(target) / Double(longSide)
        return CGSize(width: even(Double(crop.width) * scale), height: even(Double(crop.height) * scale))
    }

    /// Size of `crop` once turned upright.
    static func uprightSize(_ size: CGSize, rotationDegrees: Double) -> CGSize {
        let r = normalizedRotation(rotationDegrees)
        return (r == 90 || r == 270) ? CGSize(width: size.height, height: size.width) : size
    }

    static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded(.down)) * 2)
    }
}
