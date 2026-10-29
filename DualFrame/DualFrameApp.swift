import SwiftUI
import UIKit

@main
struct DualFrameApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CameraScreen()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Which interface orientations are allowed right now ("Girar com o celular" in Settings).
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

enum OrientationLock {
    @MainActor static func apply(rotates: Bool) {
        let mask: UIInterfaceOrientationMask = rotates ? .allButUpsideDown : .portrait
        guard AppDelegate.orientationLock != mask else { return }
        AppDelegate.orientationLock = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !rotates {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}
