import Foundation
import SwiftData

/// A SwiftData model whose whole collection is synchronized from an external source.
///
/// SwiftData remains the source of truth; a model only describes how external data is fetched
/// into it. Members are static because the model type is the key.
///
/// ```swift
/// extension User: QueryModel {
///     struct QueryData: Codable { var etag: String? }
///     static var cache: QueryCache { .forever(refreshAfter: .seconds(5 * 60)) }
///     static var tags: Set<String> { ["users"] }
///
///     static func fetch(query: QueryFetch<APIClient, QueryData>) async throws -> QueryData {
///         // fetch with query.previous?.etag, write into query.modelContext
///         return QueryData(etag: newETag)
///     }
/// }
/// ```
public protocol QueryModel: PersistentModel, Queryable {
    /// Runtime dependencies, resolved by type from the provider's `contexts:`.
    associatedtype Context: Sendable
    /// Sync metadata such as ETags or cursors, persisted between launches.
    associatedtype QueryData: Codable & Sendable

    /// The default cache policy. Models are always persisted.
    static var cache: QueryCache { get }

    /// Tags for invalidating and removing groups of keys. Defaults to none.
    static var tags: Set<String> { get }

    /// Whether the collection refetches on staleness while a subscription is synced. Defaults to
    /// `false`. See ``QueryFetcher/refetchWhileSubscribed``.
    static var refetchWhileSubscribed: Bool { get }

    /// Fetches the collection into `query.modelContext`. See ``QueryFetcher/fetch(query:)``.
    static func fetch(query: QueryFetch<Context, QueryData>) async throws -> QueryData

    /// Streams live updates. See ``QueryFetcher/subscribe(query:)``.
    static func subscribe(query: QuerySubscription<Context, QueryData>) async throws

    /// Deletes the collection's server-owned rows when its SWR cache expires or is removed.
    /// Defaults to nothing, so locally owned data is never deleted implicitly.
    static func evict(query: QueryEvict<Context>) throws
}

extension QueryModel {
    public static var tags: Set<String> { [] }
    public static var refetchWhileSubscribed: Bool { false }
    public static func subscribe(query: QuerySubscription<Context, QueryData>) async throws {}
    public static func evict(query: QueryEvict<Context>) throws {}
}

/// The fetcher for a ``QueryModel`` collection. `@QueryClient(User.self)` and
/// `provider.client(for: User.self)` use `ModelFetcher<User>`; you rarely name it yourself.
public struct ModelFetcher<Model: QueryModel>: QueryFetcher {
    public init() {}

    public var cache: QueryCache? { Model.cache }
    public var tags: Set<String> { Model.tags }
    public var refetchWhileSubscribed: Bool { Model.refetchWhileSubscribed }

    public func fetch(query: QueryFetch<Model.Context, Model.QueryData>) async throws -> Model.QueryData {
        try await Model.fetch(query: query)
    }

    public func subscribe(query: QuerySubscription<Model.Context, Model.QueryData>) async throws {
        try await Model.subscribe(query: query)
    }

    public func evict(query: QueryEvict<Model.Context>) throws {
        try Model.evict(query: query)
    }
}

/// Marks model fetchers, whose record key holds only the model's type name and whose clients
/// live for the whole session.
protocol ModelFetcherKind {
    static var modelTypeName: String { get }
}

extension ModelFetcher: ModelFetcherKind {
    static var modelTypeName: String { String(reflecting: Model.self) }
}
