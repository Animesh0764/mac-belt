import Foundation

/// Name of an event gadgets can send to each other.
/// Gadgets never import each other; this is the only channel between them.
public struct BeltEvent: Hashable, Sendable, ExpressibleByStringLiteral {
    public let name: String
    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: String) { self.name = value }
}

public extension BeltEvent {
    /// Screen sharing / presenting started or stopped (Presentation gadget).
    static let presentationStarted: BeltEvent = "presentation.started"
    static let presentationEnded: BeltEvent = "presentation.ended"
    /// Microphone muted / unmuted (Mic mute gadget).
    static let micMuted: BeltEvent = "mic.muted"
    static let micUnmuted: BeltEvent = "mic.unmuted"
    /// Awake started / ended. info["reason"] describes why.
    static let awakeStarted: BeltEvent = "awake.started"
    static let awakeEnded: BeltEvent = "awake.ended"
}

@MainActor
public final class EventBus {
    public typealias Handler = @MainActor ([String: String]) -> Void

    private var handlers: [BeltEvent: [UUID: Handler]] = [:]

    public init() {}

    /// Keep the returned subscription and call `cancel()` in your gadget's `stop()`.
    public func on(_ event: BeltEvent, _ handler: @escaping Handler) -> Subscription {
        let id = UUID()
        handlers[event, default: [:]][id] = handler
        return Subscription(bus: self, event: event, id: id)
    }

    public func post(_ event: BeltEvent, info: [String: String] = [:]) {
        for handler in handlers[event, default: [:]].values {
            handler(info)
        }
    }

    public func subscriberCount(_ event: BeltEvent) -> Int {
        handlers[event]?.count ?? 0
    }

    fileprivate func remove(_ event: BeltEvent, _ id: UUID) {
        handlers[event]?[id] = nil
        if handlers[event]?.isEmpty == true { handlers[event] = nil }
    }

    @MainActor
    public final class Subscription {
        private weak var bus: EventBus?
        private let event: BeltEvent
        private let id: UUID

        fileprivate init(bus: EventBus, event: BeltEvent, id: UUID) {
            self.bus = bus
            self.event = event
            self.id = id
        }

        public func cancel() {
            bus?.remove(event, id)
            bus = nil
        }
    }
}
