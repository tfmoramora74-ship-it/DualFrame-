import CoreImage

enum OverlayShape: String, Codable, CaseIterable, Identifiable {
    case rounded, circle
    var id: String { rawValue }
    var label: String { self == .rounded ? "Arredondada" : "Círculo" }
}

enum OverlaySize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small: return "P"
        case .medium: return "M"
        case .large: return "G"
        }
    }
    /// Window width as a fraction of the output's short side.
    var fraction: CGFloat {
        switch self {
        case .small: return 0.26
        case .medium: return 0.34
        case .large: return 0.46
        }
    }
}

/// Where and how the selfie window is burned into the back-camera picture.
/// `center` is normalized (0...1, top-left origin) in the upright output, so the same
/// placement works for the 9:16, 16:9 and 4:3 files.
struct OverlaySpec: Codable, Equatable {
    var center = CGPoint(x: 0.76, y: 0.22)
    var size: OverlaySize = .medium
    var shape: OverlayShape = .rounded
}

/// One selfie frame ready to composite: already upright and mirrored as wanted.
struct FrontOverlay {
    let image: CIImage
    let spec: OverlaySpec
}

enum OverlayCompositor {
    /// Window rectangle in a canvas of `canvas` size, top-left origin (UIKit-style).
    static func windowRect(spec: OverlaySpec, canvas: CGSize, frontAspect: CGFloat) -> CGRect {
        let width = min(canvas.width, canvas.height) * spec.size.fraction
        let height = spec.shape == .circle ? width : width / max(frontAspect, 0.1)
        var x = spec.center.x * canvas.width - width / 2
        var y = spec.center.y * canvas.height - height / 2
        // Keep the whole window inside the picture.
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
        let border = max(2, rect.width * 0.018)
        let outline = roundedRect(rect.insetBy(dx: -border, dy: -border), radius: radius + border,
                                  color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        let mask = roundedRect(rect, radius: radius, color: .white)

        let framed = outline.composited(over: base)
        return placed
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: framed,
                kCIInputMaskImageKey: mask,
            ])
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": color,
        ])?.outputImage ?? CIImage.empty()
    }
}
