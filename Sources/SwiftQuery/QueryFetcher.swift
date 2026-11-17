import Foundation
import SwiftData

/// A type the provider can sync. Conform to ``QueryModel`` or ``QueryFetcher``, not to this
/// protocol directly; it lets both kinds share the provider's `fetchers:` list.
public protocol Queryable {}

/// A value that identifies and fetches one piece of external data.
///
/// The fetcher value is the key: each distinct value gets its own client, state and cache entry.
/// Use it for anything that isn't a whole SwiftData collection: a single row, extra data attached
/// to rows, or a value with no model of its own, returned as ``QueryData``. SwiftQuery stores that
/// state in its own ``QueryRecord`` table, or only in memory when ``cache`` is `nil`.
///
/// ```swift
/// struct ExchangeRate: QueryFetcher {
///     let from: String, to: String
///     var cache: QueryCache? { .swr(staleTime: .seconds(60)) }
///
///     func fetch(query: QueryFetch<APIContext, Double>) async throws -> Double {
///         try await query.context.api.rate(from, to)
///     }
/// }
/// ```
///
/// `Context` and `QueryData` are inferred from `fetch`. `QueryData` never needs to be optional:
/// "nothing fetched yet" is `QueryState.pending`. Keep the synthesized `Hashable` and
/// `Codable` conformances: equality picks the client and the JSON encoding names the stored
/// record, so the two must agree. Changing a fetcher's stored properties changes its keys; records
/// stored under old keys are deleted without ``evict(query:)``.
public protocol QueryFetcher: Queryable, Hashable, Codable, Sendable {
    /// Runtime dependencies, resolved by type from the provider's `contexts:`.
    associatedtype Context: Sendable
    /// Arbitrary data or sync metadata, persisted unless the cache is `nil`.
    associatedtype QueryData: Codable & Sendable

    /// The cache policy, or `nil` to keep the state in memory only, for the current session.
    var cache: QueryCache? { get }

    /// Tags for invalidating and removing groups of keys. Defaults to none.
    var tags: Set<String> { get }

    /// Whether the key refetches when its cache marks it stale while a subscription is synced.
    /// Defaults to `false`: a live stream keeps the data fresh. Invalidation and explicit refetches
    /// always fetch.
    var refetchWhileSubscribed: Bool { get }

    /// Fetches external data, writing rows into `query.modelContext`, and returns the new query data.
    ///
    /// `query.previous` is the data from the last successful fetch, or `nil` before the first one;
    /// read cursors or ETags from it. Runs outside any actor and counts as complete when it
    /// returns. Pending changes in the context are saved after it returns and discarded if it
    /// throws or was cancelled. The returned data is saved once, after a successful fetch. Check
    /// for cancellation in long work, and before saving the context yourself, so a cancelled fetch
    /// can't overwrite an optimistic edit.
    func fetch(query: QueryFetch<Context, QueryData>) async throws -> QueryData

    /// Streams live updates, such as messages from a socket, until the stream ends.
    ///
    /// Called when a view first shows the key. Connect, then call `query.begin()` to get the
    /// writer, and write each update through it:
    ///
    /// ```swift
    /// func subscribe(query: QuerySubscription<API, Feed>) async throws {
    ///     let socket = try await query.context.api.connect()
    ///     let writer = await query.begin()
    ///     for try await message in socket.messages {
    ///         try await writer.write { tx in
    ///             guard message.seq > (tx.data?.lastSeq ?? 0) else { return }  // already fetched
    ///             tx.modelContext.insert(Message(message))
    ///             tx.data?.lastSeq = message.seq
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// - `begin()` starts the fetch that writes wait for, so a view's first sync doesn't fetch
    ///   until it's called. Set a connect timeout: until `begin()` is called the key doesn't
    ///   fetch, and a connect that times out throws, which fetches at once. Call it after connecting if the stream can't resume from a cursor,
    ///   so the fetch covers everything sent before the connection. Before connecting is fine for
    ///   a stream that resumes from `query.previous` or sends its own snapshot.
    /// - Write rows and data only through the writer, and skip events the fetched data already
    ///   includes, by version, sequence number, or by upserting rows by id.
    /// - Return or throw when the stream drops; don't reconnect in a loop. While a view shows the
    ///   key, `subscribe` is called again after a backoff, and its `begin()` fetches what was
    ///   missed. Throwing before `begin()` fetches right away if a view is waiting for the data.
    /// - Returning without calling `begin()` means the key has no live updates: the key fetches
    ///   normally, and `subscribe` is called again only when the key next syncs while a view
    ///   shows it, such as when a view appears or after an invalidation. The default
    ///   implementation does this.
    /// - Respect cancellation: the stream is cancelled once no view has shown the key for the
    ///   provider's `keepAliveTime`, and when its cache is removed, which waits for it to stop.
    func subscribe(query: QuerySubscription<Context, QueryData>) async throws

    /// Deletes rows this key wrote when its cache expires or is removed. Defaults to nothing.
    /// The context is saved afterwards. Only listed fetcher types are evicted.
    func evict(query: QueryEvict<Context>) throws
}

extension QueryFetcher {
    public var tags: Set<String> { [] }
    public var refetchWhileSubscribed: Bool { false }
    public func subscribe(query: QuerySubscription<Context, QueryData>) async throws {}
    public func evict(query: QueryEvict<Context>) throws {}
}

/// A fetch context the provider can create itself when no value of its type is registered.
public protocol DefaultFetchContext: Sendable {
    init()
}

/// The inputs to a ``QueryFetcher/fetch(query:)`` or ``QueryModel/fetch(query:)``.
public struct QueryFetch<Context: Sendable, QueryData: Codable & Sendable> {
    /// A fresh context for the fetch's rows, saved after the fetch returns.
    public let modelContext: ModelContext
    /// The key's runtime dependencies.
    public let context: Context
    /// The data from the last successful fetch, or `nil` before the first one.
    public let previous: QueryData?

    init(modelContext: ModelContext, context: Context, previous: QueryData?) {
        self.modelContext = modelContext
        self.context = context
        self.previous = previous
    }
}

/// The inputs to a ``QueryFetcher/evict(query:)`` or ``QueryModel/evict(query:)``.
public struct QueryEvict<Context: Sendable> {
    /// The context to delete rows from, saved afterwards.
    public let modelContext: ModelContext
    /// The key's runtime dependencies.
    public let context: Context

    init(modelContext: ModelContext, context: Context) {
        self.modelContext = modelContext
        self.context = context
    }
}

/// The inputs to a ``QueryFetcher/subscribe(query:)`` or ``QueryModel/subscribe(query:)``.
public struct QuerySubscription<Context: Sendable, QueryData: Codable & Sendable>: Sendable {
    /// The key's runtime dependencies.
    public let context: Context
    /// The stored data when the stream started, or `nil` before anything has synced.
    public let previous: QueryData?
    private let start: @Sendable () async -> QueryWriter<QueryData>

    init(
        context: Context,
        previous: QueryData?,
        begin: @escaping @Sendable () async -> QueryWriter<QueryData>
    ) {
        self.context = context
        self.previous = previous
        self.start = begin
    }

    /// Starts the fetch that writes wait for, and returns the writer. Call it once the stream is
    /// connected, or before connecting if the stream resumes from a cursor. Calling it again
    /// returns the same writer without fetching.
    public func begin() async -> QueryWriter<QueryData> {
        await start()
    }
}

/// Writes rows and query data from a subscription, in step with the key's fetches.
///
/// Returned by ``QuerySubscription/begin()``. The key is synced once the fetch started by
/// `begin()` has succeeded and no fetch is running. If that fetch fails, or is cancelled
/// with `cancel()`, it's retried with a backoff, and writes that wait for sync keep waiting, so data can't skip past what the fetch
/// would have brought in. A later failed fetch doesn't unsync the key.
public struct QueryWriter<QueryData: Codable & Sendable>: Sendable {
    /// When a write runs.
    public enum Timing: Sendable {
        /// Wait until synced, then write.
        case synced
        /// Write right away, even while a fetch is in flight. Rows the fetch saves and the data it
        /// returns replace what the write stored; rows only the write touched stay.
        case now
    }

    /// The state a write closure reads and changes.
    public struct Transaction {
        /// A context for the write's rows. Saved with `data` after the closure returns; if either
        /// save fails, neither change is kept.
        public let modelContext: ModelContext
        /// The stored data, or `nil` before anything has synced. Setting it to `nil` is ignored.
        public var data: QueryData?
        /// Whether the fetch from `begin()` has succeeded and no fetch is running. Can't change
        /// while the closure runs. Always true with ``Timing/synced``.
        public let isSynced: Bool
    }

    let target: WriterBox<QueryData>

    /// Runs `body` on the key's actor, then saves its rows and data together and publishes the
    /// data. If `body` throws, its changes are rolled back and the error is rethrown. Throws
    /// `CancellationError` if the stream is cancelled, including while waiting, or if the calling
    /// task is cancelled while waiting.
    ///
    /// Keep the closure short: it runs on the key's actor and holds up its syncs and fetches. Each
    /// write saves, so apply several events in one write when a stream is busy. Writes from one
    /// task run in order.
    @discardableResult
    public func write<R: Sendable>(
        _ timing: Timing = .synced,
        _ body: @escaping @Sendable (inout Transaction) throws -> R
    ) async throws -> R {
        guard let actor = target.actor else { throw CancellationError() }
        return try await actor.write(subscription: target.subscription, timing: timing, body)
    }

    /// Returns once the fetch from `begin()` has succeeded and no fetch is running. Throws
    /// `CancellationError` if the stream or the calling task is cancelled while waiting.
    public func synced() async throws {
        guard let actor = target.actor else { throw CancellationError() }
        try await actor.waitUntilSynced(subscription: target.subscription)
    }
}

/// The key's actor, as a writer sees it.
protocol QueryWriterTarget<QueryData>: Actor {
    associatedtype QueryData: Codable & Sendable
    func write<R: Sendable>(
        subscription: UInt64,
        timing: QueryWriter<QueryData>.Timing,
        _ body: @escaping @Sendable (inout QueryWriter<QueryData>.Transaction) throws -> R
    ) async throws -> R
    func waitUntilSynced(subscription: UInt64) async throws
}

/// Holds the key's actor weakly, so a running stream doesn't keep it alive.
final class WriterBox<QueryData: Codable & Sendable>: @unchecked Sendable {
    private(set) weak var actor: (any QueryWriterTarget<QueryData>)?
    let subscription: UInt64

    init(_ actor: any QueryWriterTarget<QueryData>, subscription: UInt64) {
        self.actor = actor
        self.subscription = subscription
    }
}
