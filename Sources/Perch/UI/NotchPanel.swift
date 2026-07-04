import AppKit
import SwiftUI

/// Borderless, non-activating panel hosting the notch UI (PLAN §4).
///
/// `.nonactivatingPanel` + `canBecomeKey == true` is the load-bearing combo:
/// the user can press Esc/arrows in the notch while the terminal app keeps
/// focus (the panel receives key events without Perch becoming active).
final class NotchPanel: NSPanel {
    /// Return true to swallow the key event. Wired by NotchController.
    var keyDownHandler: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above menu bar
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { true }   // keyboard input WITHOUT activating app
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Grab key status on click inside the panel so keyboard shortcuts
            // work; non-activating, so the frontmost app stays frontmost.
            makeKey()
        case .keyDown:
            if keyDownHandler?(event) == true { return }
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// Hosting view that only accepts mouse events inside the currently visible
/// shape (pill or expanded panel). Everything else falls through to whatever
/// window is underneath — the panel's window frame is large and static, so
/// most of it must be click-transparent.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Interactive region in this view's coordinate space (bottom-left origin).
    /// Updated by NotchController on expand/collapse/screen change.
    var interactiveRect: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinate system.
        var local = superview.map { convert(point, from: $0) } ?? point
        // NSHostingView is flipped (top-left origin), but `interactiveRect`
        // is in bottom-left-origin window coordinates — unflip before testing.
        if isFlipped {
            local.y = bounds.height - local.y
        }
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}
