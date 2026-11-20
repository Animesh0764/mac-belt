import Foundation

/// Detects a left-right "shake" of the cursor: several quick direction changes.
public struct ShakeDetector: Sendable {
    /// How far (points) the cursor must travel back before it counts as a direction change.
    public var minTravel: Double = 30
    /// Direction changes needed. 3 = right-left-right-left.
    public var reversalsNeeded = 3
    /// All of them within this many seconds.
    public var window: TimeInterval = 0.8

    private var direction = 0          // -1 left, +1 right, 0 unknown
    private var extreme: Double?       // furthest x in the current direction
    private var reversals: [TimeInterval] = []

    public init() {}

    /// Feed one cursor sample. Returns true when a shake completes (then starts over).
    public mutating func feed(x: Double, at t: TimeInterval) -> Bool {
        guard let ext = extreme else {
            extreme = x
            return false
        }
        let delta = x - ext
        if direction == 0 {
            if abs(delta) >= minTravel / 2 { direction = delta > 0 ? 1 : -1; extreme = x }
            return false
        }
        if (direction > 0 && x > ext) || (direction < 0 && x < ext) {
            extreme = x                                 // still going the same way
        } else if abs(delta) >= minTravel {             // turned back far enough
            direction = -direction
            extreme = x
            reversals.append(t)
        }
        reversals.removeAll { t - $0 > window }
        if reversals.count >= reversalsNeeded {
            reset()
            return true
        }
        return false
    }

    public mutating func reset() {
        direction = 0
        extreme = nil
        reversals.removeAll()
    }
}

/// Decides when to open the shelf: a shake while something is being dragged.
///
/// Fed by a timer with what macOS reports (no permissions needed):
/// - is the left mouse button down,
/// - the cursor x position,
/// - the drag pasteboard's change count (it changes when a real drag starts, so moving a
///   window or selecting text doesn't count).
public struct DragShakeTracker: Sendable {
    public var detector = ShakeDetector()
    private var idleDragCount: Int?
    private var dragging = false
    private var firedThisDrag = false

    public init() {}

    private var pressedSince: TimeInterval?

    /// Returns true when the shelf should open.
    public mutating func tick(buttonDown: Bool, x: Double, dragChangeCount: Int, at t: TimeInterval) -> Bool {
        guard buttonDown else {
            // Idle: remember the drag pasteboard's count so a new drag can be noticed.
            idleDragCount = dragChangeCount
            pressedSince = nil
            dragging = false
            firedThisDrag = false
            detector.reset()
            return false
        }
        if pressedSince == nil { pressedSince = t }
        if !dragging, let idle = idleDragCount, dragChangeCount != idle {
            dragging = true
        }
        guard dragging, !firedThisDrag else { return false }
        if detector.feed(x: x, at: t) {
            firedThisDrag = true   // once per drag
            return true
        }
        return false
    }
}
