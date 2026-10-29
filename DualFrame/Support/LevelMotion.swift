import CoreMotion
import SwiftUI

/// Horizon tilt from gravity, relative to the nearest 90° hold (portrait or landscape).
@MainActor
final class LevelMotion: ObservableObject {
    @Published private(set) var deviation: Double = 0
    @Published private(set) var pitch: Double = 0
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let g = motion?.gravity else { return }
            let roll = atan2(g.x, -g.y) * 180 / .pi
            let nearest = (roll / 90).rounded() * 90
            let pitch = asin(max(-1, min(1, -g.z))) * 180 / .pi
            MainActor.assumeIsolated {
                self?.deviation = roll - nearest
                self?.pitch = pitch
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
