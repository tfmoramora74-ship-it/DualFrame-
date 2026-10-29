import AVFoundation
import SwiftUI
import UIKit

/// Pinch / double-tap zoomable photo or video, like the Photos app.
struct ZoomableMedia: UIViewRepresentable {
    enum Content: Equatable {
        case image(UIImage)
        case video(AVPlayer)
    }

    let content: Content

    func makeUIView(context: Context) -> ZoomScrollView {
        ZoomScrollView()
    }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.show(content)
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private var contentView: UIView?
    private var shown: ZoomableMedia.Content?
    private var naturalSize = CGSize(width: 1, height: 1)

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 8
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ content: ZoomableMedia.Content) {
        guard content != shown else { return }
        shown = content
        contentView?.removeFromSuperview()
        zoomScale = 1
        switch content {
        case .image(let image):
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFit
            naturalSize = image.size
            contentView = imageView
        case .video(let player):
            let playerView = PlayerLayerView()
            playerView.playerLayer.player = player
            playerView.playerLayer.videoGravity = .resizeAspect
            // The layer letterboxes itself, so the zoomed view simply fills the screen.
            naturalSize = .zero
            contentView = playerView
        }
        if let contentView { addSubview(contentView) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let contentView, zoomScale == 1, bounds.width > 0 else {
            centerContent()
            return
        }
        let size: CGSize
        if naturalSize.width > 0, naturalSize.height > 0 {
            let scale = min(bounds.width / naturalSize.width, bounds.height / naturalSize.height)
            size = CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
        } else {
            size = bounds.size
        }
        contentView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        centerContent()
    }

    private func centerContent() {
        guard let contentView else { return }
        let dx = max(0, (bounds.width - contentView.frame.width) / 2)
        let dy = max(0, (bounds.height - contentView.frame.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else if let contentView {
            let point = gesture.location(in: contentView)
            let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Play/pause and scrubber for the zoomable player.
struct PlayerControls: View {
    let player: AVPlayer
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: Double = 1
    @State private var scrubbing = false
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isPlaying {
                    player.pause()
                } else {
                    if progress >= duration - 0.05 { player.seek(to: .zero) }
                    player.play()
                }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(isPlaying ? "Pausar" : "Reproduzir")

            Slider(value: Binding(get: { progress }, set: { value in
                progress = value
                player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }), in: 0...max(duration, 0.1), onEditingChanged: { scrubbing = $0 })

            Text(formatDuration(progress))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .onAppear(perform: attach)
        .onDisappear(perform: detach)
    }

    private func attach() {
        detach()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { time in
            MainActor.assumeIsolated {
                let total = player.currentItem?.duration.seconds ?? 1
                if total.isFinite, total > 0 { duration = total }
                if !scrubbing { progress = time.seconds }
                if progress >= duration - 0.05 { isPlaying = false }
            }
        }
    }

    private func detach() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}
