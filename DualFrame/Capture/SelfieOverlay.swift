import CoreImage

enum OverlayShape: String, Codable, CaseIterable, Identifiable {
    case rounded, circle
    var id: String { rawValue }
    var label: String { self == .rounded ? "Arredondada" : "Círculo" }
}

/// Resolution of the selfie camera in front + back mode.
enum FrontResolution: String, Codable, CaseIterable, Identifiable {
    case hd, max
    var id: String { rawValue }
    var label: String { self == .hd ? "HD" : "Máx" }
}

/// Where and how the selfie window is burned into the back-camera picture.
/// `center` is normalized (0...1, top-left origin) in the upright output; `fraction` is the
/// window width as a share of the output's short side (resized by dragging its edge).
struct OverlaySpec: Codable, Equatable {
    var center = CGPoint(x: 0.76, y: 0.22)
    var fraction: CGFloat = 0.34
    var shape: OverlayShape = .rounded

    static let fractionRange: ClosedRange<CGFloat> = 0.14...0.9

    init() {}

    // Tolerant decoding: settings saved by older versions (which had fixed sizes) still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        center = try container.decodeIfPresent(CGPoint.self, forKey: .center) ?? center
        fraction = try container.decodeIfPresent(CGFloat.self, forKey: .fraction) ?? fraction
        shape = try container.decodeIfPresent(OverlayShape.self, forKey: .shape) ?? shape
    }
}

/// One selfie frame ready to composite: already upright and mirrored as wanted.
struct FrontOverlay {
    let image: CIImage
    let spec: OverlaySpec
    /// Previews only: draw a resize grip on the window's corner.
    var showGrip = false
}

enum OverlayCompositor {
    /// Window rectangle in a canvas of `canvas` size, top-left origin (UIKit-style).
    static func windowRect(spec: OverlaySpec, canvas: CGSize, frontAspect: CGFloat) -> CGRect {
        let fraction = min(max(spec.fraction, OverlaySpec.fractionRange.lowerBound), OverlaySpec.fractionRange.upperBound)
        var width = min(canvas.width, canvas.height) * fraction
        var height = spec.shape == .circle ? width : width / max(frontAspect, 0.1)
        // Never larger than the picture itself.
        let fit = min(1, canvas.width / width, canvas.height / height)
        width *= fit
        height *= fit
        var x = spec.center.x * canvas.width - width / 2
        var y = spec.center.y * canvas.height - height / 2
        x = min(max(x, 0), canvas.width - width)
        y = min(max(y, 0), canvas.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Burns the selfie window into `base` (extent 0,0,size).
    static func compose(_ base: CIImage, size: CGSize, overlay: FrontOverlay?) -> CIImage {
        guard let overlay else { return base }
        let front = overlay.image
        let frontExtent = front.extent
        guard frontExtent.width > 0, frontExtent.height > 0 else { return base }

        let topLeft = windowRect(spec: overlay.spec, canvas: size, frontAspect: frontExtent.width / frontExtent.height)
        // Core Image works bottom-left.
        let rect = CGRect(x: topLeft.minX, y: size.height - topLeft.maxY, width: topLeft.width, height: topLeft.height)

        // Aspect-fill the selfie into the window.
        let scale = max(rect.width / frontExtent.width, rect.height / frontExtent.height)
        let scaledWidth = frontExtent.width * scale, scaledHeight = frontExtent.height * scale
        let placed = front
            .transformed(by: CGAffineTransform(translationX: -frontExtent.minX, y: -frontExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.midX - scaledWidth / 2, y: rect.midY - scaledHeight / 2))
            .cropped(to: rect)

        let radius = overlay.spec.shape == .circle ? rect.width / 2 : rect.width * 0.12
        // A hairline edge: just enough to separate the selfie from the background.
        let border = max(1, rect.width * 0.006)
        let outline = roundedRect(rect.insetBy(dx: -border, dy: -border), radius: radius + border,
                                  color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.75))
        let mask = roundedRect(rect, radius: radius, color: .white)

        var result = placed
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: outline.composited(over: base),
                kCIInputMaskImageKey: mask,
            ])
        if overlay.showGrip {
            // Resize grip on the bottom-right corner (bottom-right in UIKit = bottom-right here too).
            let grip = max(10, min(size.width, size.height) * 0.035)
            let center = overlay.spec.shape == .circle
                ? CGPoint(x: rect.midX + rect.width * 0.354, y: rect.midY - rect.height * 0.354)
                : CGPoint(x: rect.maxX - radius * 0.3, y: rect.minY + radius * 0.3)
            let dot = roundedRect(CGRect(x: center.x - grip / 2, y: center.y - grip / 2, width: grip, height: grip),
                                  radius: grip / 2, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.95))
            result = dot.composited(over: result)
        }
        return result.cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": color,
        ])?.outputImage ?? CIImage.empty()
    }
}
