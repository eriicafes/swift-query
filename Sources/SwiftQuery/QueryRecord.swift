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
    /// The key's identity: its type's name, and for a fetcher its value. See ``type``.
    public var key: String = ""
    /// The name of the key's model or fetcher type. Type filters and garbage collection find a
    /// key's type here, never by parsing ``key``.
    public var type: String = ""
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
        type: String,
        stateData: Data? = nil,
        lastSyncedAt: Date? = nil,
        lastAccessedAt: Date? = nil,
        invalidated: Bool = false,
        tags: String = "",
        gcTime: Double? = nil
    ) {
        self.key = key
        self.type = type
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
    /// Record keys: a JSON array of the key's type name and, for a fetcher, its value, written
    /// by ``QueryRecordKeyEncoder`` so unordered collections are in canonical order:
    ///
    /// ```
    /// ["MyApp.UserDetail",{"id":"42"}]   // a fetcher
    /// ["MyApp.User"]                     // a model
    /// ```
    ///
    /// JSON quotes and escapes the type name, so it ends exactly where the string does, whatever
    /// characters it contains: two different types or values can never share a key. A key is
    /// only compared whole or decoded by the type it names; type filters use the name stored on
    /// its own in ``QueryRecord/type``.
    enum Key {
        static func make<F: QueryFetcher>(_ fetcher: F) -> String {
            // A model's fetcher has no value of its own: the model type is the key.
            let value = F.self is any ModelFetcherKind.Type ? nil : fetcher
            guard let data = try? QueryRecordKeyEncoder.encode(Parts(type: typeName(F.self), value: value)) else {
                preconditionFailure("Couldn't encode the fetcher \(fetcher) to build its record key")
            }
            return String(decoding: data, as: UTF8.self)
        }

        /// The name of a fetcher's type, stored as ``QueryRecord/type``: the model's type name for
        /// a model, the fetcher's otherwise.
        static func typeName<F: QueryFetcher>(_: F.Type) -> String {
            (F.self as? any ModelFetcherKind.Type)?.modelTypeName ?? String(reflecting: F.self)
        }

        /// The prefix of a pending mutation marker's key. Keys start with `[`, so none starts
        /// with this.
        static let markerPrefix = "#pending:"

        /// A marker's ``QueryRecord/type``, which no type filter names.
        static let markerType = "#pending"

        /// A new pending mutation marker's key.
        static func marker() -> String {
            markerPrefix + UUID().uuidString
        }

        static func isMarker(_ key: String) -> Bool {
            key.hasPrefix(markerPrefix)
        }

        /// The fetcher a key of type `F` names, or `nil` if the key belongs to another type or
        /// no longer decodes as `F`.
        static func decode<F: QueryFetcher>(_: F.Type, from key: String) -> F? {
            guard let parts = try? JSONDecoder().decode(Parts<F>.self, from: Data(key.utf8)),
                  parts.type == typeName(F.self)
            else { return nil }
            if F.self is any ModelFetcherKind.Type {
                guard parts.value == nil else { return nil }
                return try? JSONDecoder().decode(F.self, from: Data("{}".utf8))
            }
            return parts.value
        }

        /// A key's contents: `[type]` or `[type, value]`.
        private struct Parts<Value: Codable>: Codable {
            let type: String
            let value: Value?

            init(type: String, value: Value?) {
                self.type = type
                self.value = value
            }

            init(from decoder: any Decoder) throws {
                var container = try decoder.unkeyedContainer()
                type = try container.decode(String.self)
                value = container.isAtEnd ? nil : try container.decode(Value.self)
                guard container.isAtEnd else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "A record key has at most two elements")
                }
            }

            func encode(to encoder: any Encoder) throws {
                var container = encoder.unkeyedContainer()
                try container.encode(type)
                if let value {
                    try container.encode(value)
                }
            }
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
