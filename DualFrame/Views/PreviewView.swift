import AVFoundation
import AVKit
import SwiftUI
import UIKit

extension OutputKind {
    var color: UIColor {
        switch self {
        case .vertical: return UIColor(red: 0.20, green: 0.85, blue: 0.95, alpha: 1)
        case .horizontal: return UIColor(red: 1.00, green: 0.78, blue: 0.20, alpha: 1)
        case .full: return UIColor(white: 1, alpha: 0.55)
        }
    }
}

/// Full-sensor preview with the crop guides of every active output drawn on top.
struct PreviewView: UIViewRepresentable {
    @ObservedObject var model: CameraModel

    func makeUIView(context: Context) -> PreviewUIView {
        let model = self.model
        let view = PreviewUIView(previewLayer: model.previewLayer)
        view.onTap = { [weak model] point in model?.focusAndExpose(at: point) }
        view.onPinch = { [weak model] scale, began in
            guard let model else { return }
            if began { context.coordinator.pinchStart = model.zoomDisplay }
            let range = model.zoomRange
            let value = min(max(context.coordinator.pinchStart * scale, range.lowerBound), range.upperBound)
            model.setZoom(display: value, animated: false)
        }
        view.onShutterButton = { [weak model] in model?.toggleRecording() }
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.guides = model.config.showGuides ? model.guides : []
        view.isRecording = model.isRecording
        view.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var pinchStart: CGFloat = 1
    }
}

final class PreviewUIView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var guides: [(kind: OutputKind, rect: CGRect)] = []
    var isRecording = false
    var onTap: ((CGPoint) -> Void)?
    var onPinch: ((CGFloat, Bool) -> Void)?
    var onShutterButton: (() -> Void)?

    private var guideLayers: [OutputKind: CAShapeLayer] = [:]
    private var labelLayers: [OutputKind: CATextLayer] = [:]
    private let focusRing = CAShapeLayer()

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(previewLayer)

        focusRing.strokeColor = UIColor.systemYellow.cgColor
        focusRing.fillColor = UIColor.clear.cgColor
        focusRing.lineWidth = 1.5
        focusRing.opacity = 0
        layer.addSublayer(focusRing)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))

        // Volume buttons / Camera Control start and stop recording.
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended { self?.onShutterButton?() }
            }
            addInteraction(interaction)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        drawGuides()
        CATransaction.commit()
    }

    private func drawGuides() {
        let active = Set(guides.map(\.kind))
        for (kind, shape) in guideLayers where !active.contains(kind) {
            shape.removeFromSuperlayer()
            guideLayers[kind] = nil
            labelLayers[kind]?.removeFromSuperlayer()
            labelLayers[kind] = nil
        }
        for guide in guides {
            let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: guide.rect)
            let shape = guideLayers[guide.kind] ?? makeGuideLayer(guide.kind)
            shape.path = UIBezierPath(rect: rect.insetBy(dx: 1, dy: 1)).cgPath
            shape.lineWidth = isRecording ? 2.5 : 1.5
            let label = labelLayers[guide.kind] ?? makeLabelLayer(guide.kind)
            label.frame = CGRect(x: rect.minX + 6, y: rect.minY + 4, width: 120, height: 16)
        }
    }

    private func makeGuideLayer(_ kind: OutputKind) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.strokeColor = kind.color.cgColor
        shape.fillColor = UIColor.clear.cgColor
        if kind == .full { shape.lineDashPattern = [6, 4] }
        layer.insertSublayer(shape, below: focusRing)
        guideLayers[kind] = shape
        return shape
    }

    private func makeLabelLayer(_ kind: OutputKind) -> CATextLayer {
        let text = CATextLayer()
        text.string = kind.shortLabel
        text.fontSize = 11
        text.foregroundColor = kind.color.cgColor
        text.contentsScale = UIScreen.main.scale
        layer.insertSublayer(text, below: focusRing)
        labelLayers[kind] = text
        return text
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        onTap?(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        showFocusRing(at: point)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began: onPinch?(gesture.scale, true)
        case .changed: onPinch?(gesture.scale, false)
        default: break
        }
    }

    private func showFocusRing(at point: CGPoint) {
        let size: CGFloat = 70
        focusRing.path = UIBezierPath(rect: CGRect(x: point.x - size / 2, y: point.y - size / 2,
                                                   width: size, height: size)).cgPath
        focusRing.removeAllAnimations()
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 1, 0]
        animation.keyTimes = [0, 0.7, 1]
        animation.duration = 1.2
        focusRing.add(animation, forKey: "fade")
    }
}
