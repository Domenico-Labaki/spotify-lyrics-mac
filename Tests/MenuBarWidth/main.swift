import Foundation
let item = CGRect(x: 900, y: 0, width: 160, height: 24)
// No neighbors: fill the space up to the notch, capped at the preferred width.
precondition(MenuBarWidth.fit(item: item, leftBoundary: 700, obstacles: []) == 320)
// A nearby neighbor limits the item without repeated shrink/grow probing.
let neighbor = CGRect(x: 850, y: 0, width: 44, height: 24)
precondition(MenuBarWidth.fit(item: item, leftBoundary: 700, obstacles: [neighbor]) == 160)
// A neighboring item on the right or a different row must not limit the width.
precondition(MenuBarWidth.fit(item: item, leftBoundary: 700, obstacles: [CGRect(x: 1070, y: 0, width: 20, height: 24), CGRect(x: 880, y: 100, width: 50, height: 20)]) == 320)
// Intersections are ambiguous; don't change the current width.
precondition(MenuBarWidth.fit(item: item, leftBoundary: 700, obstacles: [CGRect(x: 850, y: 0, width: 60, height: 24)]) == nil)
// Respect the notch boundary and the minimum width.
precondition(MenuBarWidth.fit(item: item, leftBoundary: 1000, obstacles: []) == 36)
// Status item frames can include system padding beyond the requested width.
precondition(MenuBarWidth.fit(item: CGRect(x: 1118, y: 0, width: 112, height: 33), leftBoundary: 1080, obstacles: [], systemPadding: 16) == 110)
precondition(MenuBarWidth.fit(item: CGRect(x: 1118, y: 0, width: 112, height: 33), leftBoundary: 1200, obstacles: [], systemPadding: 16) == 24)
precondition(MenuBarWidth.fit(item: .zero, leftBoundary: 700, obstacles: []) == nil)
print("Menu bar geometry checks passed")
// End-to-end geometry simulation: the outer frame contains 16 points of
// macOS padding and stays right-anchored as the app changes its length.
func measure(right: CGFloat, allocated: CGFloat, notch: CGFloat) -> CGFloat? {
    let outerWidth = allocated + 16
    let frame = CGRect(x: right - outerWidth, y: 0, width: outerWidth, height: 33)
    return MenuBarWidth.fit(item: frame, leftBoundary: notch, obstacles: [], systemPadding: 16)
}
let crowded = measure(right: 1230, allocated: 96, notch: 1130)!
precondition(crowded == 60)
for _ in 0..<20 { precondition(measure(right: 1230, allocated: crowded, notch: 1130) == crowded) }
let roomier = measure(right: 1230, allocated: crowded, notch: 1100)!
precondition(roomier == 90)
for _ in 0..<20 { precondition(measure(right: 1230, allocated: roomier, notch: 1100) == roomier) }
print("Crowded and uncrowded width stability simulation passed")

// A neighboring item moving with the lyric item can report a small false gain.
precondition(!MenuBarWidth.shouldApply(current: 96, candidate: 104))
precondition(!MenuBarWidth.shouldApply(current: 96, candidate: 115))
precondition(MenuBarWidth.shouldApply(current: 96, candidate: 116))
precondition(MenuBarWidth.shouldApply(current: 96, candidate: 92))
print("Menu bar expansion hysteresis checks passed")

// Stable changes to the number of items change width by 40 points each.
var tracker = MenuBarWidthTracker()
_ = tracker.update(320, layout: "8,10:1728:956")
_ = tracker.update(320, layout: "8,10:1728:956")
precondition(tracker.width == 320)
_ = tracker.update(280, layout: "8,10,12:1728:956")
precondition(tracker.update(280, layout: "8,10,12:1728:956") == 280)
_ = tracker.update(320, layout: "8,10:1728:956")
precondition(tracker.update(320, layout: "8,10:1728:956") == 320)
// A hidden item immediately drops by 40, then by 8 until visible. Its
// new layout is recorded without subtracting the added item twice.
precondition(tracker.itemIsHidden() == 280)
precondition(tracker.itemIsHidden() == 272)
_ = tracker.update(272, layout: "8,10,12:1728:956")
precondition(tracker.update(272, layout: "8,10,12:1728:956") == 272)
_ = tracker.update(320, layout: "8,10:1728:956")
precondition(tracker.update(320, layout: "8,10:1728:956") == 312)
for _ in 0..<50 { _ = tracker.itemIsHidden() }
precondition(tracker.width == MenuBarWidth.minimum)
print("Fixed increments, correction, and layout stability checks passed")
let hiddenItem = CGRect(x: 980, y: 4.5, width: 203, height: 24)
let shareIcon = CGRect(x: 1190, y: 0, width: 48, height: 33)
let visibleWindow = CGRect(x: 976, y: 0, width: 211, height: 33)
precondition(!StatusItemVisibility.hasMatchingWindow(item: hiddenItem, windows: [shareIcon]))
precondition(StatusItemVisibility.hasMatchingWindow(item: hiddenItem, windows: [visibleWindow, shareIcon]))
print("Hidden window detection checks passed")
