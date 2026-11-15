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
///     func fetch(context: ModelContext, fetchContext: APIContext, previous: Double?) async throws -> Double {
///         try await fetchContext.api.rate(from, to)
///     }
/// }
/// ```
///
/// `Context` and `QueryData` are inferred from `fetch`. `QueryData` never needs to be optional:
/// "nothing fetched yet" is `QueryState.pending`. Keep the synthesized `Hashable` and
/// `Codable` conformances: equality picks the client and the JSON encoding names the stored
/// record, so the two must agree. Changing a fetcher's stored properties changes its keys; records
/// stored under old keys are deleted without ``evict(context:)``.
public protocol QueryFetcher: Queryable, Hashable, Codable, Sendable {
    /// Runtime dependencies, resolved by type from the provider's `contexts:`.
    associatedtype Context: Sendable
    /// Arbitrary data or sync metadata, persisted unless ``cache`` is `nil`.
    associatedtype QueryData: Codable

    /// The cache policy, or `nil` to keep the state in memory only, for the current session.
    var cache: QueryCache? { get }

    /// Tags for invalidating and removing groups of keys. Defaults to none.
    var tags: Set<String> { get }

    /// Fetches external data, writing rows into `context`, and returns the new query data.
    ///
    /// `previous` is the data from the last successful fetch, or `nil` before the first one;
    /// read cursors or ETags from it. Runs outside any actor and counts as complete when it
    /// returns. Pending changes in `context` are saved after it returns and discarded if it
    /// throws. The returned data is saved once, after a successful fetch. Check for
    /// cancellation in long work.
    func fetch(context: ModelContext, fetchContext: Context, previous: QueryData?) async throws -> QueryData

    /// Starts a long-lived stream, such as a socket subscription, or returns `nil` (the default).
    ///
    /// Called when the client gains a view and no stream is running. A stream that ends on its
    /// own is not restarted right away; the next sync from a view (when one appears or its
    /// scene becomes active) starts a new one. Must not block: do any awaiting inside the
    /// returned task. The stream gets the stored data as `previous` (`nil` before the first
    /// fetch) to resume from, writes rows through its own context from `container`, and
    /// advances the stored data through `writer`. It is cancelled when its client is dropped or
    /// its cache is removed.
    func subscribe(
        container: ModelContainer,
        fetchContext: Context,
        previous: QueryData?,
        writer: QueryDataWriter<QueryData>
    ) -> Task<Void, Never>?

    /// Deletes rows this key wrote when its cache expires or is removed. Defaults to nothing.
    /// The context is saved afterwards. Only listed fetcher types are evicted.
    func evict(context: ModelContext) throws
}

extension QueryFetcher {
    public var tags: Set<String> { [] }

    public func subscribe(
        container: ModelContainer,
        fetchContext: Context,
        previous: QueryData?,
        writer: QueryDataWriter<QueryData>
    ) -> Task<Void, Never>? {
        nil
    }

    public func evict(context: ModelContext) throws {}
}

/// A fetch context the provider can create itself when no value of its type is registered.
public protocol DefaultFetchContext: Sendable {
    init()
}

/// Updates a key's persisted ``QueryFetcher/QueryData`` from its stream.
///
/// Passed to `subscribe`. Updates run in order on the key's query actor and are saved immediately:
///
/// - While a fetch is in flight, updates are queued and applied on top of that fetch's result,
///   so stream progress isn't lost to an older pull.
/// - Events that arrive during a fetch may also be in its response, so make updates monotonic,
///   for example `state.seq = max(state.seq, event.seq)`.
/// - If 1,000 updates queue up behind one fetch, they are saved to the stored state right away
///   instead. That fetch's result then replaces them, so those events may be pulled again.
/// - Updates are dropped when nothing has synced successfully yet, and once the client is gone.
///
/// Stream updates never change `lastSyncedAt`, so they don't affect freshness.
public struct QueryDataWriter<QueryData>: Sendable {
    private let apply: @Sendable (@escaping @Sendable (inout QueryData) -> Void) async -> Void

    init(_ apply: @escaping @Sendable (@escaping @Sendable (inout QueryData) -> Void) async -> Void) {
        self.apply = apply
    }

    /// Applies `body` to the persisted sync state and saves it.
    /// Returns once the update is saved, or queued behind an in-flight fetch.
    public func update(_ body: @escaping @Sendable (inout QueryData) -> Void) async {
        await apply(body)
    }
}
