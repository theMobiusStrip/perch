import AppKit

/// Resolved layout facts for the notch (or the no-notch fallback pill) on a
/// given screen (PLAN §4). Recompute via `NotchGeometry.resolve()` whenever
/// screen parameters change.
struct NotchGeometry {
    let screen: NSScreen
    let hasNotch: Bool
    /// Physical notch cutout size. No-notch fallback: the pill size.
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    // MARK: - Constants

    /// The window frame is LARGE & STATIC; SwiftUI animates the visible shape
    /// inside it. The window itself never resizes during expand/collapse.
    static let windowSize = CGSize(width: 700, height: 500)
    /// No-notch fallback: ~220×28 pill at the menu-bar center.
    static let fallbackPillSize = CGSize(width: 220, height: 28)
    /// Visible band the pill extends below the physical notch cutout —
    /// the collapsed content (count + dots) lives here, outside the cutout.
    static let pillBandHeight: CGFloat = 22
    /// Horizontal slack added around the notch cutout for the pill shape.
    static let pillSlack: CGFloat = 24
    /// Expanded panel stays ≤ 640×420 (contract E).
    static let expandedMaxSize = CGSize(width: 640, height: 420)

    // MARK: - Init / resolution

    init(screen: NSScreen) {
        self.screen = screen
        let topInset = screen.safeAreaInsets.top  // > 0 ⇒ has notch (macOS 12+)
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = screen.frame.width - left.width - right.width
            notchHeight = topInset
        } else {
            hasNotch = false
            notchWidth = Self.fallbackPillSize.width
            notchHeight = Self.fallbackPillSize.height
        }
    }

    /// Built-in (potentially notched) display when present, else the
    /// menu-bar screen, else any screen.
    static func resolve() -> NotchGeometry? {
        guard let screen = builtInScreen() ?? NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }
        return NotchGeometry(screen: screen)
    }

    static func builtInScreen() -> NSScreen? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            if CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0 {
                return screen
            }
        }
        return nil
    }

    // MARK: - Frames

    /// Static window frame, top-centered on the screen (screen coordinates).
    var windowFrame: NSRect {
        let width = min(Self.windowSize.width, screen.frame.width)
        let height = min(Self.windowSize.height, screen.frame.height)
        return NSRect(x: (screen.frame.midX - width / 2).rounded(),
                      y: screen.frame.maxY - height,
                      width: width,
                      height: height)
    }

    /// Collapsed pill shape size (visible black shape, includes slack + band).
    var pillSize: CGSize {
        if hasNotch {
            return CGSize(width: notchWidth + Self.pillSlack,
                          height: notchHeight + Self.pillBandHeight)
        }
        return Self.fallbackPillSize
    }

    /// Expanded panel size (fixed; ≤ 640×420, clamped to the screen).
    var expandedSize: CGSize {
        CGSize(width: min(Self.expandedMaxSize.width, screen.frame.width - 40),
               height: min(Self.expandedMaxSize.height, screen.frame.height - 60))
    }

    /// Hit-test rect in window/content-view coordinates (bottom-left origin),
    /// top-centered within the static window frame.
    func interactiveRect(expanded: Bool) -> NSRect {
        let size = expanded ? expandedSize : pillSize
        let window = windowFrame
        return NSRect(x: ((window.width - size.width) / 2).rounded(),
                      y: window.height - size.height,
                      width: size.width,
                      height: size.height)
    }
}
