import Foundation

/// App-level state, stored as app.json.
public struct AppState: Codable, Equatable {
    public var enabledGadgets: [String] = []
    public var onboardingDone = false
    /// Set just before a gadget's start() and cleared after. If it's still set at the next
    /// launch, that gadget crashed the app while starting, so it gets switched off.
    public var startingGadget: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledGadgets = try c.decodeIfPresent([String].self, forKey: .enabledGadgets) ?? []
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
        startingGadget = try c.decodeIfPresent(String.self, forKey: .startingGadget)
    }
}

/// Knows every gadget type, which ones are on, and runs their lifecycle.
@MainActor
public final class GadgetRegistry {
    public let types: [any Gadget.Type]
    public private(set) var state: AppState
    /// Last start error per gadget id, shown in the gallery.
    public private(set) var errors: [String: String] = [:]
    /// Called after any gadget is switched on or off.
    public var onChange: (() -> Void)?

    private var running: [String: any Gadget] = [:]
    private let store: SettingsStore
    private let makeContext: (GadgetInfo) -> GadgetContext
    static let stateKey = "app"

    public init(types: [any Gadget.Type], store: SettingsStore,
                makeContext: @escaping (GadgetInfo) -> GadgetContext) {
        self.types = types
        self.store = store
        self.makeContext = makeContext
        self.state = store.load(AppState.self, key: Self.stateKey, default: AppState())
    }

    public var infos: [GadgetInfo] { types.map { $0.info } }

    public func isEnabled(_ id: String) -> Bool { state.enabledGadgets.contains(id) }
    public func isRunning(_ id: String) -> Bool { running[id] != nil }
    public func instance(_ id: String) -> (any Gadget)? { running[id] }

    /// Running gadgets in registry order (the order of `types`).
    public var runningGadgets: [any Gadget] {
        types.compactMap { running[$0.info.id] }
    }

    /// Start every gadget that was on last time. Returns the names of gadgets switched off
    /// because they crashed while starting last time.
    @discardableResult
    public func startEnabledAtLaunch() -> [String] {
        var disabled: [String] = []
        if let crashed = state.startingGadget {
            state.enabledGadgets.removeAll { $0 == crashed }
            state.startingGadget = nil
            errors[crashed] = "Switched off because it crashed while starting last time."
            disabled.append(type(for: crashed)?.info.name ?? crashed)
            persist()
        }
        for type in types where isEnabled(type.info.id) {
            start(type)
        }
        onChange?()
        return disabled
    }

    /// Switch a gadget on or off. Returns false if it couldn't start (see `errors`).
    @discardableResult
    public func setEnabled(_ id: String, _ enabled: Bool) -> Bool {
        guard let type = type(for: id) else { return false }
        var ok = true
        if enabled {
            if !isEnabled(id) { state.enabledGadgets.append(id) }
            ok = start(type)
            if !ok { state.enabledGadgets.removeAll { $0 == id } }
        } else {
            state.enabledGadgets.removeAll { $0 == id }
            stop(id)
        }
        persist()
        onChange?()
        return ok
    }

    public func markOnboardingDone() {
        state.onboardingDone = true
        persist()
    }

    /// Stop everything (app quitting).
    public func stopAll() {
        for id in Array(running.keys) { stop(id) }
    }

    // MARK: - Private

    private func type(for id: String) -> (any Gadget.Type)? {
        types.first { $0.info.id == id }
    }

    @discardableResult
    private func start(_ type: any Gadget.Type) -> Bool {
        let info = type.info
        guard running[info.id] == nil else { return true }
        guard info.isSupportedOnThisMac else {
            errors[info.id] = "Needs macOS \(info.minimumOS.majorVersion).\(info.minimumOS.minorVersion) or newer."
            return false
        }
        state.startingGadget = info.id
        persist()
        let gadget = type.init(context: makeContext(info))
        do {
            try gadget.start()
            running[info.id] = gadget
            errors[info.id] = nil
        } catch {
            gadget.stop()
            errors[info.id] = error.localizedDescription
        }
        state.startingGadget = nil
        persist()
        return running[info.id] != nil
    }

    private func stop(_ id: String) {
        running.removeValue(forKey: id)?.stop()
    }

    private func persist() {
        try? store.save(state, key: Self.stateKey)
    }
}
