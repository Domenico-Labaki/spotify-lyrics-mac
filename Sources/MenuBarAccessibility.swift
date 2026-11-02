import AppKit
import ApplicationServices
import CoreGraphics

/// Reads menu bar geometry only; no events, clicks, or control of other apps.
enum MenuBarAccessibility {
    struct ScreenInfo {
        let frame: CGRect // AX global coordinates, origin at top left
        let notchRight: CGFloat?
    }
    struct Snapshot {
        let ownPID: pid_t
        let appPIDs: [pid_t]
        let statusHostPIDs: [pid_t]
        let frontPID: pid_t?
        let allocatedWidth: CGFloat
        // Our own window uses AX/Core Graphics coordinates, and is available
        // without asking Accessibility to inspect other applications.
        let ownWindowFrame: CGRect?
        let screens: [ScreenInfo]
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func attribute(_ object: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(object, name, &value) == .success else { return nil }
        return value
    }

    private static func children(_ parent: AXUIElement) -> [AXUIElement] {
        attribute(parent, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private static func element(_ object: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(object, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute as CFString),
              let s = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &position),
              AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    // Core Graphics supplies window bounds, not screen pixels. macOS 26
    // commonly hosts status-item windows in Control Center rather than the
    // owning app, so include both processes.
    static func visibleStatusWindows(_ snapshot: Snapshot) -> [CGRect]? {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let hosts = Set(snapshot.statusHostPIDs + [snapshot.ownPID])
        let rectangles = raw.compactMap { entry -> CGRect? in
            guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  hosts.contains(pid),
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  (20...30).contains(layer),
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 0, rect.height >= 12, rect.height <= 60,
                  snapshot.screens.contains(where: { screen in
                      rect.minY >= screen.frame.minY - 3 && rect.minY < screen.frame.minY + 45 &&
                      rect.maxX > screen.frame.minX && rect.minX < screen.frame.maxX
                  }) else { return nil }
            return rect
        }
        return rectangles.isEmpty ? nil : rectangles
    }

    static func measure(_ snapshot: Snapshot) -> MenuBarMeasurement {
        guard let windows = visibleStatusWindows(snapshot) else { return .unavailable }
        if let frame = snapshot.ownWindowFrame, frame.width > 0, frame.height > 0,
           !StatusItemVisibility.hasMatchingWindow(item: frame, windows: windows) {
            return .hidden
        }
        guard isTrusted(prompt: false) else { return .unavailable }
        let own = AXUIElementCreateApplication(snapshot.ownPID)
        AXUIElementSetMessagingTimeout(own, 0.15)
        guard let ownBar = element(own, kAXExtrasMenuBarAttribute as CFString),
              let ownRect = children(ownBar).compactMap(frame).first else { return .unavailable }
        // Accessibility can return an apparently normal rectangle for an item
        // that Control Center has silently stopped displaying.
        guard StatusItemVisibility.hasMatchingWindow(item: ownRect, windows: windows) else { return .hidden }
        guard let screen = snapshot.screens.first(where: { $0.frame.intersects(ownRect) }) else { return .hidden }
        let barHeight = max(ownRect.height * 2, 40)
        guard ownRect.minY >= screen.frame.minY - 3,
              ownRect.minY < screen.frame.minY + barHeight else { return .hidden }
        var boundary = screen.frame.minX
        if let notchRight = screen.notchRight, ownRect.midX >= notchRight {
            boundary = max(boundary, notchRight)
        }
        var obstacles: [CGRect] = []
        for pid in Set(snapshot.appPIDs) where pid != snapshot.ownPID {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            if let extras = element(app, kAXExtrasMenuBarAttribute as CFString) {
                obstacles.append(contentsOf: children(extras).compactMap(frame))
            }
            if pid == snapshot.frontPID, let menu = element(app, kAXMenuBarAttribute as CFString) {
                obstacles.append(contentsOf: children(menu).compactMap(frame))
            }
        }
        let systemPadding = max(0, ownRect.width - snapshot.allocatedWidth)
        let width = MenuBarWidth.fit(item: ownRect, leftBoundary: boundary, obstacles: obstacles, systemPadding: systemPadding) ?? snapshot.allocatedWidth
        // Track other status-window sizes, independent of their positions: macOS
        // may move neighbors while our own width changes. A new or removed
        // indicator changes this signature and triggers a width adjustment.
        let otherWindows = windows.filter { !StatusItemVisibility.hasMatchingWindow(item: ownRect, windows: [$0]) }
        let layout = otherWindows.map { Int(($0.width / 4).rounded()) }.sorted().map(String.init).joined(separator: ",")
            + ":" + String(Int(screen.frame.width)) + ":" + String(Int(boundary))
        return .visible(width, layout)
    }
}
