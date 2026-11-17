import Foundation
import SwiftData

/// Persisted synchronization metadata for one model or fetcher key.
///
/// Include `QueryRecord.self` in your `ModelContainer` schema. The model is CloudKit-compatible
/// (no unique constraints, every property has a default), but sync metadata describes one
/// device's local data. When the app uses CloudKit, give it its own configuration that doesn't
/// sync, with a name distinct from your other configurations so it gets its own store file:
///
/// ```swift
/// let container = try ModelContainer(
///     for: Schema([User.self, QueryRecord.self]),
///     configurations:
///         ModelConfiguration(schema: Schema([User.self]), cloudKitDatabase: .automatic),
///         ModelConfiguration("SwiftQuery", schema: Schema([QueryRecord.self]), cloudKitDatabase: .none)
/// )
/// ```
@Model
public final class QueryRecord {
    /// The model type's identity.
    public var key: String = ""
    /// The encoded ``QueryFetcher/QueryData`` from the last successful fetch.
    public var stateData: Data?
    /// When the last successful fetch finished.
    public var lastSyncedAt: Date?
    /// When the cached data was last used. Used for SWR garbage collection.
    public var lastAccessedAt: Date?
    /// Whether the next sync must fetch again.
    public var invalidated: Bool = false
    /// The key's tags, encoded for exact `contains` matching. See ``QueryFetcher/tags``.
    public var tags: String = ""
    /// The SWR cache time in seconds, or `nil` when the cache never expires.
    public var gcTime: Double?

    public init(
        key: String,
        stateData: Data? = nil,
        lastSyncedAt: Date? = nil,
        lastAccessedAt: Date? = nil,
        invalidated: Bool = false,
        tags: String = "",
        gcTime: Double? = nil
    ) {
        self.key = key
        self.stateData = stateData
        self.lastSyncedAt = lastSyncedAt
        self.lastAccessedAt = lastAccessedAt
        self.invalidated = invalidated
        self.tags = tags
        self.gcTime = gcTime
    }
}

extension QueryRecord {
    /// Records for `key`. A key normally has one; pick among duplicates with ``latest(_:)``.
    static func descriptor(key: String) -> FetchDescriptor<QueryRecord> {
        FetchDescriptor<QueryRecord>(predicate: #Predicate { $0.key == key })
    }

    /// The most recently synced of `records`; a record that never synced counts as the oldest.
    /// Chosen in memory because how a store sorts `nil` dates isn't defined.
    static func latest(_ records: [QueryRecord]) -> QueryRecord? {
        records.max { ($0.lastSyncedAt ?? .distantPast) < ($1.lastSyncedAt ?? .distantPast) }
    }
}

extension QueryRecord {
    /// Whether the record's cache expired under its stored ``gcTime``.
    func isExpired(now: Date) -> Bool {
        guard let gcTime, stateData != nil,
              let lastUse = lastAccessedAt ?? lastSyncedAt
        else { return false }
        return now >= lastUse.addingTimeInterval(gcTime)
    }
}

extension QueryRecord {
    /// Record keys: a model's type name, or a fetcher's type name and its value as sorted JSON.
    enum Key {
        static func make<F: QueryFetcher>(_ fetcher: F) -> String {
            if let model = F.self as? any ModelFetcherKind.Type {
                return model.modelTypeName
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(fetcher) else {
                preconditionFailure("Couldn't encode the fetcher \(fetcher) to build its record key")
            }
            return "\(String(reflecting: F.self)):\(String(decoding: data, as: UTF8.self))"
        }

        /// The prefix of a pending mutation marker's key. `#` can't start a type name, so no
        /// listed type or filter matches it.
        static let markerPrefix = "#pending:"

        /// A new pending mutation marker's key.
        static func marker() -> String {
            markerPrefix + UUID().uuidString
        }

        static func isMarker(_ key: String) -> Bool {
            key.hasPrefix(markerPrefix)
        }

        static func typeName(of key: String) -> String {
            key.firstIndex(of: ":").map { String(key[..<$0]) } ?? key
        }

        static func isModel(_ key: String) -> Bool {
            !key.contains(":")
        }

        static func decode<F: QueryFetcher>(_: F.Type, from key: String) -> F? {
            if F.self is any ModelFetcherKind.Type {
                return try? JSONDecoder().decode(F.self, from: Data("{}".utf8))
            }
            guard let colon = key.firstIndex(of: ":") else { return nil }
            return try? JSONDecoder().decode(F.self, from: Data(key[key.index(after: colon)...].utf8))
        }
    }

    /// Tags stored in one string as `,tag1,tag2,`, with `%` and `,` percent-encoded so a comma is
    /// always a delimiter and a `contains` check for `,tag,` matches exactly.
    enum Tags {
        static func encode(_ tags: Set<String>) -> String {
            tags.isEmpty ? "" : "," + tags.sorted().map(escape).joined(separator: ",") + ","
        }

        static func decode(_ string: String) -> Set<String> {
            // `,a,b,` splits into "", "a", "b", ""; keeping empty pieces keeps an empty tag (`,,`).
            let pieces = string.split(separator: ",", omittingEmptySubsequences: false).dropFirst().dropLast()
            return Set(pieces.map { unescape(String($0)) })
        }

        static func needle(_ tag: String) -> String {
            "," + escape(tag) + ","
        }

        static func escape(_ tag: String) -> String {
            tag.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: ",", with: "%2C")
        }

        static func unescape(_ tag: String) -> String {
            tag.replacingOccurrences(of: "%2C", with: ",").replacingOccurrences(of: "%25", with: "%")
        }
    }
}
