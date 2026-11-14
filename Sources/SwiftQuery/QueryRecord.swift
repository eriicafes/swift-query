import Foundation
import SwiftData

/// Persisted synchronization metadata for one ``SyncedModel`` type.
///
/// Include `QueryRecord.self` in your `ModelContainer` schema. The model is CloudKit-compatible
/// (no unique constraints, every property has a default), but sync metadata describes one
/// device's local data, so keep it in a local-only configuration when the app uses CloudKit:
///
/// ```swift
/// let schema = Schema([User.self, QueryRecord.self])
/// let container = try ModelContainer(
///     for: schema,
///     configurations:
///         ModelConfiguration(schema: Schema([User.self]), cloudKitDatabase: .automatic),
///         ModelConfiguration("SwiftQuery", schema: Schema([QueryRecord.self]), cloudKitDatabase: .none)
/// )
/// ```
@Model
public final class QueryRecord {
    /// The model type's identity.
    public var key: String = ""
    /// The encoded ``SyncedModel/SyncState`` from the last successful fetch.
    public var stateData: Data?
    /// When the last successful fetch finished.
    public var lastSyncedAt: Date?
    /// When the cached data was last used. Used for SWR garbage collection.
    public var lastAccessedAt: Date?
    /// Whether the next sync must fetch again.
    public var invalidated: Bool = false

    public init(
        key: String,
        stateData: Data? = nil,
        lastSyncedAt: Date? = nil,
        lastAccessedAt: Date? = nil,
        invalidated: Bool = false
    ) {
        self.key = key
        self.stateData = stateData
        self.lastSyncedAt = lastSyncedAt
        self.lastAccessedAt = lastAccessedAt
        self.invalidated = invalidated
    }
}

extension QueryRecord {
    /// Records for `key`, most recently synced first.
    static func descriptor(key: String, limit: Int? = nil) -> FetchDescriptor<QueryRecord> {
        var descriptor = FetchDescriptor<QueryRecord>(
            predicate: #Predicate { $0.key == key },
            sortBy: [SortDescriptor(\.lastSyncedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return descriptor
    }
}
