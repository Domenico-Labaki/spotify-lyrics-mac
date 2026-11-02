import Foundation
import CoreGraphics

/// Width derived from the space between the nearest left-hand obstacle and
/// the item's right edge. All rectangles use the same screen coordinates.
enum MenuBarWidth {
    static let maximum: CGFloat = 320
    static let minimum: CGFloat = 24
    static let fallback: CGFloat = 96
    static let padding: CGFloat = 6
    // A little breathing room at the notch/screen edge prevents a transient
    // system item from pushing an exactly fitting item out of view.
    static let boundaryPadding: CGFloat = 24
    // Small apparent gains can be the menu bar moving a neighbor alongside us.
    static let expansionThreshold: CGFloat = 20

    static func shouldApply(current: CGFloat, candidate: CGFloat) -> Bool {
        candidate <= current - 4 || candidate >= current + expansionThreshold
    }

    static func fit(item: CGRect, leftBoundary: CGFloat, obstacles: [CGRect], systemPadding: CGFloat = 0) -> CGFloat? {
        guard item.width > 0, item.height > 0, item.minX.isFinite, item.maxX.isFinite,
              leftBoundary.isFinite, item.maxX > leftBoundary else { return nil }
        var left = leftBoundary + boundaryPadding
        for obstacle in obstacles {
            guard obstacle.width > 0, obstacle.height > 0,
                  obstacle.minX.isFinite, obstacle.maxX.isFinite,
                  obstacle.maxY > item.minY, obstacle.minY < item.maxY else { continue }
            // Ignore our own rectangle and items entirely to its right. Only
            // use clear left-side neighbors; ambiguous overlaps are not safe.
            if obstacle.maxX <= item.minX + 2 {
                left = max(left, obstacle.maxX + padding)
            } else if obstacle.minX < item.minX - 2 && obstacle.maxX > item.minX + 2 {
                return nil
            }
        }
        return min(maximum, max(minimum, floor(item.maxX - left - max(0, systemPadding))))
    }
}

enum StatusItemVisibility {
    // A status item's selection window commonly extends a few points beyond
    // its accessibility frame. Match both edges to avoid mistaking another
    // menu extra for the lyrics item.
    static func hasMatchingWindow(item: CGRect, windows: [CGRect]) -> Bool {
        windows.contains { rect in
            abs(rect.minX - item.minX) <= 10 && abs(rect.maxX - item.maxX) <= 10 &&
            abs(rect.midY - item.midY) <= 10 && rect.width > 0 && rect.height > 0
        }
    }
}

enum MenuBarMeasurement {
    case visible(CGFloat, String)
    case hidden
    case unavailable
}

/// Adjusts by an estimated icon width when the number of items changes.
/// Hidden items receive smaller successive corrections until visible.
struct MenuBarWidthTracker {
    private(set) var width: CGFloat = MenuBarWidth.maximum
    private let iconWidth: CGFloat = 40
    private let correction: CGFloat = 8
    private var itemCount: Int?
    private var observedCount: Int?
    private var matching = 0
    private var recovering = false
    private var missing = 0

    mutating func itemIsHidden() -> CGFloat {
        width = max(MenuBarWidth.minimum, width - (recovering ? correction : iconWidth))
        recovering = true
        matching = 0
        observedCount = nil
        return width
    }

    mutating func update(_ candidate: CGFloat?, layout: String = "") -> CGFloat {
        guard candidate != nil else {
            missing += 1
            matching = 0
            if missing >= 2 { width = min(width, MenuBarWidth.fallback) }
            return width
        }
        if missing >= 2 && itemCount == nil && !recovering { width = MenuBarWidth.maximum }
        missing = 0
        let list = layout.split(separator: ":", omittingEmptySubsequences: false).first ?? ""
        let count = list.isEmpty ? 0 : list.split(separator: ",").count
        if observedCount == count { matching += 1 }
        else { observedCount = count; matching = 1 }
        guard matching >= 2 else { return width }
        if recovering {
            // The initial reduction already compensated for the new item.
            itemCount = count
            recovering = false
        } else if let previous = itemCount, previous != count {
            width = min(MenuBarWidth.maximum, max(MenuBarWidth.minimum,
                width + CGFloat(previous - count) * iconWidth))
            itemCount = count
        } else {
            itemCount = count
        }
        return width
    }
}
