import AppKit
import ApplicationServices

/// A normal app window, in global CoreGraphics coordinates (origin top-left of the primary screen, y down).
struct TrackedWindow {
    let id: CGWindowID
    let frame: CGRect
}

enum WindowTracker {
    private static let ownPID = getpid()
    private static var askedForAccessibility = false

    /// Visible normal windows, front to back.
    static func onscreenWindows() -> [TrackedWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap(parse)
    }

    /// Every normal window that still exists, including minimized ones and ones on other Spaces.
    static func allWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return Set(list.compactMap(parse).map(\.id))
    }

    private static func parse(_ info: [String: Any]) -> TrackedWindow? {
        guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        guard alpha > 0.05, rect.width >= 80, rect.height >= 40 else { return nil }
        return TrackedWindow(id: id, frame: rect)
    }

    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// The Dock's icon strip, read through the Accessibility API. Asks for permission once.
    static func dockFrame() -> CGRect? {
        if !AXIsProcessTrusted() {
            if !askedForAccessibility {
                askedForAccessibility = true
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(opts)
            }
            return nil
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return nil }
        for el in elements {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == (kAXListRole as String) else { continue }
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posRef, let sizeRef else { continue }
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            if size.width > 0, size.height > 0 {
                // The list's frame has empty padding around the icons; the Dock's glass panel starts a little
                // above the icons, so drop the top edge to there.
                let tile = UserDefaults(suiteName: "com.apple.dock")?.double(forKey: "tilesize") ?? 0
                let pad = tile > 0 ? max(0, (size.height - CGFloat(tile)) / 2 - 4) : 0
                return CGRect(x: pos.x, y: pos.y + pad, width: size.width, height: size.height - pad)
            }
        }
        return nil
    }
}
