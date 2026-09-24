import SwiftUI
import UIKit
import ObjectiveC.runtime

/// Keyboard height from screen-coordinate frame notifications.
/// Avoids window/`keyWindow` lookups that often return nil mid-animation.
@MainActor
final class KeyboardInsetObserver: ObservableObject {
    @Published private(set) var inset: CGFloat = 0

    private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let change = center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.apply(note, hidden: false)
            }
        }
        let hide = center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.apply(note, hidden: true)
            }
        }
        tokens = [change, hide]
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    func reset() {
        inset = 0
    }

    private func apply(_ note: Notification, hidden: Bool) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
            .doubleValue ?? 0.25

        let next: CGFloat
        if hidden {
            next = 0
        } else if let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            // Prefer the foreground scene's screen (UIScreen.main is deprecated in iOS 26).
            let bounds = Self.activeScreenBounds
            next = bounds == .zero ? 0 : endFrame.intersection(bounds).height
        } else {
            next = 0
        }

        guard abs(inset - next) > 0.5 else { return }
        withAnimation(.easeInOut(duration: duration)) {
            inset = next
        }
    }

    private static var activeScreenBounds: CGRect {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let screen = scenes.first(where: { $0.activationState == .foregroundActive })?.screen {
            return screen.bounds
        }
        return scenes.first?.screen.bounds ?? .zero
    }
}

/// Disables UIHostingController keyboard avoidance so we can lift only the chat column.
struct HostingKeyboardAvoidanceDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.apply()
    }

    final class Controller: UIViewController {
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }

        func apply() {
            // Walk our parent chain (Watch destination hosting → nav → root).
            var cursor: UIViewController? = self
            while let current = cursor {
                strip(current)
                if let hostView = current.view {
                    KeyboardAvoidanceRuntime.neutralize(hostView)
                }
                cursor = current.parent
            }
            // Also strip every hosting controller under the window root.
            if let root = view.window?.rootViewController {
                stripTree(root)
            }
        }

        private func stripTree(_ controller: UIViewController) {
            strip(controller)
            if let hostView = controller.view {
                KeyboardAvoidanceRuntime.neutralize(hostView)
            }
            controller.children.forEach(stripTree)
            if let presented = controller.presentedViewController {
                stripTree(presented)
            }
            if let nav = controller as? UINavigationController {
                nav.viewControllers.forEach(stripTree)
            }
        }

        private func strip(_ controller: UIViewController) {
            guard let hosting = controller as? any HostingKeyboardSafeAreaControlling else { return }
            // Keep container safe area; drop keyboard so the page isn't translated.
            if hosting.safeAreaRegions.contains(.keyboard) {
                hosting.safeAreaRegions = .container
            }
        }
    }
}

private protocol HostingKeyboardSafeAreaControlling: AnyObject {
    var safeAreaRegions: SafeAreaRegions { get set }
}

extension UIHostingController: HostingKeyboardSafeAreaControlling {}

enum KeyboardAvoidanceRuntime {
    static func neutralize(_ view: UIView) {
        var current: UIView? = view
        while let candidate = current {
            installNoopKeyboardHandlers(on: candidate)
            current = candidate.superview
        }
    }

    private static func installNoopKeyboardHandlers(on view: UIView) {
        guard let viewClass = object_getClass(view) else { return }
        let showSel = NSSelectorFromString("keyboardWillShowWithNotification:")
        guard class_getInstanceMethod(viewClass, showSel) != nil else { return }

        let subclassName = String(cString: class_getName(viewClass)) + "_PaircastNoKeyboardAvoidance"
        if let existing = NSClassFromString(subclassName) {
            object_setClass(view, existing)
            return
        }

        guard let nameUTF8 = (subclassName as NSString).utf8String,
              let subclass = objc_allocateClassPair(viewClass, nameUTF8, 0) else { return }

        let noop: @convention(block) (AnyObject, AnyObject) -> Void = { _, _ in }
        for name in [
            "keyboardWillShowWithNotification:",
            "keyboardWillHideWithNotification:",
            "keyboardWillChangeFrameWithNotification:",
        ] {
            let sel = NSSelectorFromString(name)
            if let method = class_getInstanceMethod(viewClass, sel) {
                class_addMethod(subclass, sel, imp_implementationWithBlock(noop), method_getTypeEncoding(method))
            }
        }
        objc_registerClassPair(subclass)
        object_setClass(view, subclass)
    }
}

extension View {
    func disableHostingKeyboardAvoidance() -> some View {
        background(HostingKeyboardAvoidanceDisabler())
    }
}
