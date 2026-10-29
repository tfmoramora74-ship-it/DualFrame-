import CoreGraphics

/// How one output file is cut out of the sensor buffer.
/// Everything is expressed in the sensor buffer's own (unrotated, landscape) pixel space;
/// the writer's `transform` turns the file upright on playback, so no pixels are ever rotated.
struct OutputPlan {
    let kind: OutputKind
    /// Crop rectangle in buffer pixels (origin top-left).
    let crop: CGRect
    /// Encoded size, in buffer orientation.
    let size: CGSize
    let transform: CGAffineTransform
    /// The buffer goes to the encoder untouched (full sensor at native size).
    let isPassthrough: Bool

    /// Crop normalized to 0...1 of the buffer, the same convention as metadata-output rects.
    func normalizedCrop(bufferWidth: Int, bufferHeight: Int) -> CGRect {
        CGRect(x: crop.minX / CGFloat(bufferWidth),
               y: crop.minY / CGFloat(bufferHeight),
               width: crop.width / CGFloat(bufferWidth),
               height: crop.height / CGFloat(bufferHeight))
    }
}

enum CropMath {
    static func plans(kinds: [OutputKind],
                      bufferWidth: Int,
                      bufferHeight: Int,
                      rotationDegrees: Double,
                      resolution: OutputResolution) -> [OutputPlan] {
        let rotation = normalizedRotation(rotationDegrees)
        let verticalIsBufferX = rotation == 90 || rotation == 270
        let transform = CGAffineTransform(rotationAngle: CGFloat(Double(rotation) * .pi / 180))

        return kinds.map { kind in
            let crop = region(kind: kind, width: bufferWidth, height: bufferHeight, verticalIsBufferX: verticalIsBufferX)
            let size = outputSize(crop: crop, resolution: resolution)
            let passthrough = crop.width == CGFloat(bufferWidth) && crop.height == CGFloat(bufferHeight)
                && size.width == CGFloat(bufferWidth) && size.height == CGFloat(bufferHeight)
            return OutputPlan(kind: kind, crop: crop, size: size, transform: transform, isPassthrough: passthrough)
        }
    }

    static func normalizedRotation(_ degrees: Double) -> Int {
        let r = Int(degrees.rounded()) % 360
        return r < 0 ? r + 360 : r
    }

    /// Largest centered rectangle of the output's aspect that fits the buffer.
    static func region(kind: OutputKind, width: Int, height: Int, verticalIsBufferX: Bool) -> CGRect {
        let aspect: Double // buffer-x extent / buffer-y extent
        switch kind {
        case .full:
            return CGRect(x: 0, y: 0, width: width, height: height)
        case .vertical:
            // Scene is 9 wide by 16 tall.
            aspect = verticalIsBufferX ? 16.0 / 9.0 : 9.0 / 16.0
        case .horizontal:
            aspect = verticalIsBufferX ? 9.0 / 16.0 : 16.0 / 9.0
        }
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

    static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded(.down)) * 2)
    }
}
