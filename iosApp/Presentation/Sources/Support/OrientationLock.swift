import UIKit

/// App-wide interface orientation lock. Default portrait; Watch fullscreen switches to landscape.
@MainActor
public enum OrientationLock {
    public private(set) static var mask: UIInterfaceOrientationMask = .portrait

    public static func lock(_ orientations: UIInterfaceOrientationMask) {
        // Multitasking-capable iPad apps can't drive orientation; requesting it only
        // leaves UIKit and the app's declared mask disagreeing. Let iPad rotate freely.
        guard UIDevice.current.userInterfaceIdiom != .pad else {
            mask = .all
            return
        }

        mask = orientations
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
        scene.windows.forEach { window in
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}
