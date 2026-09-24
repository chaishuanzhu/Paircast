import Foundation
import ObjectiveC
import QuartzCore
import UIKit
import Domain

/// MobileVLCKit resets OpenGL ES buffers on its vout thread, which mutates the
/// view's `CAEAGLLayer`. iOS 26's UIKit asserts in `-[UIView actionForLayer:forKey:]`
/// for that off-main mutation.
///
/// Do **not** hop `doResetBuffers:` onto the main queue: VLC calls it while holding
/// the GL view lock, and a `main.sync` there deadlocks with UIKit layout / play().
/// Instead, let the GL thread keep owning the reset, and skip UIKit's background
/// assertion for this private view class only.
enum VLCOpenGLESMainThreadGuard {
    private static let lock = NSLock()
    private static var installed = false

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        guard let cls = NSClassFromString("VLCOpenGLES2VideoView") else {
            PaircastLog.playback.warning("VLCOpenGLES2VideoView class missing; main-thread guard skipped")
            return
        }

        let selector = NSSelectorFromString("actionForLayer:forKey:")
        guard let existing = class_getInstanceMethod(cls, selector),
              let typeEncoding = method_getTypeEncoding(existing) else {
            PaircastLog.playback.warning("VLCOpenGLES2VideoView.actionForLayer:forKey: missing; guard skipped")
            return
        }

        // Capture the IMP currently used for this selector (often UIView's).
        typealias OriginalFn = @convention(c) (AnyObject, Selector, CALayer, NSString) -> AnyObject?
        let originalIMP = method_getImplementation(existing)
        let original = unsafeBitCast(originalIMP, to: OriginalFn.self)

        let block: @convention(block) (AnyObject, CALayer, NSString) -> AnyObject? = { target, layer, key in
            if !Thread.isMainThread {
                // NSNull => no implicit CAAction; allows setContents: from the GL thread
                // without UIKit's off-main UIView layer assertion.
                return NSNull()
            }
            return original(target, selector, layer, key)
        }
        let newIMP = imp_implementationWithBlock(block)

        // Prefer adding a class-local override so we never rewrite UIView globally.
        if !class_addMethod(cls, selector, newIMP, typeEncoding) {
            method_setImplementation(existing, newIMP)
        }

        PaircastLog.playback.info("installed VLCOpenGLES2VideoView actionForLayer guard")
    }
}
