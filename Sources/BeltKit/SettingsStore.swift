import Foundation

/// JSON files in ~/Library/Application Support/MacBelt/, one per key.
/// Human-readable on purpose: people who clone this can inspect and edit them.
public final class SettingsStore {
    public let directory: URL

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacBelt", isDirectory: true)
    }

    public init(directory: URL = SettingsStore.defaultDirectory) {
        self.directory = directory
    }

    public func url(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    /// Returns `defaultValue` when the file is missing or can't be decoded.
    /// Settings types should decode with `decodeIfPresent` so new fields don't wipe old settings.
    public func load<T: Decodable>(_ type: T.Type, key: String, default defaultValue: T) -> T {
        guard let data = try? Data(contentsOf: url(for: key)) else { return defaultValue }
        return (try? JSONDecoder.belt.decode(T.self, from: data)) ?? defaultValue
    }

    public func save<T: Encodable>(_ value: T, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.belt.encode(value)
        try data.write(to: url(for: key), options: .atomic)
    }
}

/// A `SettingsStore` view scoped to one gadget.
public struct GadgetSettings {
    public let store: SettingsStore
    public let key: String

    public func load<T: Decodable>(_ type: T.Type, default defaultValue: T) -> T {
        store.load(type, key: key, default: defaultValue)
    }

    public func save<T: Encodable>(_ value: T) {
        try? store.save(value, key: key)
    }
}

extension JSONEncoder {
    static var belt: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var belt: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
