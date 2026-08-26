import AppKit
import Foundation

// NSWindow+Diagnostics
//
// Provides lightweight frame-mutation logging without method swizzling.
// Swizzling NSWindow geometry methods causes infinite recursion because after
// method_exchangeImplementations the "swizzled_" selector IS the original IMP;
// calling self.swizzled_setFrame() from inside swizzled_setFrame() recurses
// indefinitely and triggers the AppKit internal breakpoint on the main thread.
//
// Instead, call NSWindow.logFrame(_:label:) at the call site when needed.

extension NSWindow {

    // MARK: - No-op swizzle installer (kept for call-site compatibility)

    @MainActor
    static func swizzleDiagnostics() {
        // Intentionally empty — swizzling removed to prevent recursive setFrame crash.
        // Use logFrame(_:label:) at specific call sites instead.
        LinkOSLogger.shared.info(
            "[NSWindow+Diagnostics] Diagnostics active (non-swizzle mode).",
            category: .app
        )
    }

    // MARK: - Manual frame logger

    /// Call this at any `setFrame` call site you want to audit.
    /// Example:
    ///   window.logFrame(newFrame, label: "updateAspectRatio")
    ///   window.setFrame(newFrame, display: true)
    func logFrame(_ frameRect: NSRect, label: String) {
        let backtrace = Thread.callStackSymbols.prefix(6).joined(separator: "\n  ")
        LinkOSLogger.shared.info(
            "[NSWindow Frame] \(label) → \(frameRect)\n  Backtrace:\n  \(backtrace)",
            category: .media
        )
    }
}
