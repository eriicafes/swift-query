import Foundation
import SwiftData

/// A SwiftData model whose whole collection is synchronized from an external source.
///
/// SwiftData remains the source of truth; a model only describes how external data is fetched
/// into it. Members are static because the model type is the key.
///
/// ```swift
/// extension User: QueryModel {
///     struct State: Codable { var etag: String? }
///     static var cache: QueryCache { .forever(refreshAfter: .seconds(5 * 60)) }
///     static var tags: Set<String> { ["users"] }
///
///     static func fetch(context: ModelContext, fetchContext: APIClient, state: State?) async throws -> State {
///         // fetch with state?.etag, write into `context`
///         return State(etag: newETag)
///     }
/// }
/// ```
public protocol QueryModel: PersistentModel, Queryable {
    /// Runtime dependencies, resolved by type from the provider's `contexts:`.
    associatedtype Context: Sendable
    /// Sync metadata such as ETags or cursors, persisted between launches.
    associatedtype State: Codable

    /// The default cache policy. Models are always persisted.
    static var cache: QueryCache { get }

    /// Tags for invalidating and removing groups of keys. Defaults to none.
    static var tags: Set<String> { get }

    /// Fetches the collection into `context`. See ``QueryFetcher/fetch(context:fetchContext:state:)``.
    static func fetch(context: ModelContext, fetchContext: Context, state: State?) async throws -> State

    /// Starts a long-lived stream. See ``QueryFetcher/subscribe(container:fetchContext:state:writer:)``.
    static func subscribe(
        container: ModelContainer,
        fetchContext: Context,
        state: State?,
        writer: StateWriter<State>
    ) -> Task<Void, Never>?

    /// Deletes the collection's server-owned rows when its SWR cache expires or is removed.
    /// Defaults to nothing, so locally owned data is never deleted implicitly.
    static func evict(context: ModelContext) throws
}

extension QueryModel {
    public static var tags: Set<String> { [] }

    public static func subscribe(
        container: ModelContainer,
        fetchContext: Context,
        state: State?,
        writer: StateWriter<State>
    ) -> Task<Void, Never>? {
        nil
    }

    public static func evict(context: ModelContext) throws {}
}

/// The fetcher for a ``QueryModel`` collection. `@QueryClient(User.self)` and
/// `provider.client(for: User.self)` use `ModelFetcher<User>`; you rarely name it yourself.
public struct ModelFetcher<Model: QueryModel>: QueryFetcher {
    public init() {}

    public var cache: QueryCache? { Model.cache }
    public var tags: Set<String> { Model.tags }

    public func fetch(context: ModelContext, fetchContext: Model.Context, state: Model.State?) async throws -> Model.State {
        try await Model.fetch(context: context, fetchContext: fetchContext, state: state)
    }

    public func subscribe(
        container: ModelContainer,
        fetchContext: Model.Context,
        state: Model.State?,
        writer: StateWriter<Model.State>
    ) -> Task<Void, Never>? {
        Model.subscribe(container: container, fetchContext: fetchContext, state: state, writer: writer)
    }

    public func evict(context: ModelContext) throws {
        try Model.evict(context: context)
    }
}

/// Marks model fetchers, whose record key is the model's type name and whose clients live for
/// the whole session.
protocol ModelFetcherKind {
    static var modelTypeName: String { get }
}

extension ModelFetcher: ModelFetcherKind {
    static var modelTypeName: String { String(reflecting: Model.self) }
}
