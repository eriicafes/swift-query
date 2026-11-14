import Foundation
import SwiftData

/// A SwiftData model whose data is synchronized from an external source.
///
/// SwiftData remains the source of truth for application data. A synced model only describes
/// how external data is fetched and applied to SwiftData; the query layer decides *when* to
/// fetch, deduplicates fetches, and persists ``SyncState`` between launches.
///
/// Most models conform to ``QueryModel``, which refines this protocol with a simpler `fetch`.
/// Conform to `SyncedModel` directly when a stream task returned by `fetch` should update the
/// sync state itself, for example to advance a cursor as events arrive:
///
/// ```swift
/// extension Message: SyncedModel {
///     struct SyncContext: Sendable { let api: APIClient; let socket: MessageSocket }
///     struct SyncState: Codable { var seq = 0 }
///
///     static var defaultState: SyncState { .init() }
///     static var cache: QueryCache { .forever() }
///
///     static func fetch(
///         context: ModelContext,
///         syncContext: SyncContext,
///         syncState: inout SyncState,
///         writer: SyncStateWriter<Message>
///     ) async throws -> Task<Void, Never>? {
///         let page = try await syncContext.api.messages(after: syncState.seq)
///         // write page.messages into context...
///         syncState.seq = page.lastSeq
///         return await syncContext.socket.connect(container: context.container) { event in
///             await writer.update { state in
///                 state.seq = max(state.seq, event.seq)
///             }
///         }
///     }
/// }
/// ```
public protocol SyncedModel: PersistentModel {
    /// Runtime dependencies required to synchronize the model, such as a `URLSession`,
    /// an authenticated API client, or a socket manager. Not persisted.
    associatedtype SyncContext: Sendable

    /// Synchronization metadata, such as ETags, cursors, or server versions.
    /// Loaded and persisted automatically by the query layer.
    associatedtype SyncState: Codable

    /// The sync state used before the first successful synchronization.
    static var defaultState: SyncState { get }

    /// The default cache policy for the model. Individual `sync(_:)` calls can override it.
    static var cache: QueryCache { get }

    /// Fetches external data and applies it to SwiftData.
    ///
    /// The fetch runs outside any actor and counts as complete when it returns.
    ///
    /// - Parameters:
    ///   - context: A fresh `ModelContext` dedicated to this fetch. Changes still pending when the
    ///     fetch returns are saved for you; if the fetch throws, they are discarded. Use it only
    ///     inside this call.
    ///   - syncContext: The runtime dependencies registered with the ``QueryProvider``.
    ///   - syncState: The persisted sync state. It is saved once, after the fetch returns
    ///     successfully.
    ///   - writer: Updates the persisted sync state later, from the returned stream task.
    /// - Returns: An optional long-lived task (for example a socket stream). It is not awaited.
    ///   Returning `nil` keeps any previously returned task running. Returning a different task
    ///   cancels and replaces the previous one. A stream task must not capture `context`; create
    ///   its own context from `context.container` instead.
    ///
    /// The fetch is cancelled if its model is unregistered, so check for cancellation in long work.
    @discardableResult
    static func fetch(
        context: ModelContext,
        syncContext: SyncContext,
        syncState: inout SyncState,
        writer: SyncStateWriter<Self>
    ) async throws -> Task<Void, Never>?

    /// Removes this model's cached SwiftData records when an SWR cache expires.
    ///
    /// The default implementation removes nothing, so locally owned data is never deleted
    /// implicitly. Implement it to delete only records that came from the external source.
    /// The context is saved by the query layer after this returns.
    static func evict(context: ModelContext) throws
}

extension SyncedModel {
    public static func evict(context: ModelContext) throws {}

    /// The key identifying this model's ``QueryRecord``.
    static var queryKey: String { String(reflecting: Self.self) }
}

/// A ``SyncedModel`` whose stream task, if any, never updates the sync state.
///
/// This is the conformance most models use. Implement the `fetch` without a writer; cursors
/// and ETags then only move when `fetch` runs.
///
/// ```swift
/// extension User: QueryModel {
///     struct SyncContext: Sendable { let session: URLSession }
///     struct SyncState: Codable { var etag: String? }
///
///     static var defaultState: SyncState { .init(etag: nil) }
///     static var cache: QueryCache { .forever(refreshAfter: .seconds(5 * 60)) }
///
///     static func fetch(
///         context: ModelContext,
///         syncContext: SyncContext,
///         syncState: inout SyncState
///     ) async throws -> Task<Void, Never>? {
///         // fetch and write into `context`
///         return nil
///     }
/// }
/// ```
public protocol QueryModel: SyncedModel {
    /// Fetches external data and applies it to SwiftData.
    ///
    /// Behaves like ``SyncedModel/fetch(context:syncContext:syncState:writer:)`` without a writer:
    /// a returned stream task cannot update `syncState`.
    @discardableResult
    static func fetch(
        context: ModelContext,
        syncContext: SyncContext,
        syncState: inout SyncState
    ) async throws -> Task<Void, Never>?
}

extension QueryModel {
    /// Forwards to the writer-less `fetch`, ignoring the writer.
    public static func fetch(
        context: ModelContext,
        syncContext: SyncContext,
        syncState: inout SyncState,
        writer: SyncStateWriter<Self>
    ) async throws -> Task<Void, Never>? {
        try await fetch(context: context, syncContext: syncContext, syncState: &syncState)
    }
}

/// Updates a model's persisted ``SyncedModel/SyncState`` from a stream task.
///
/// Passed to ``SyncedModel/fetch(context:syncContext:syncState:writer:)``. Updates run in order
/// on the model's sync actor and are saved immediately:
///
/// - While a fetch is in flight, updates are queued and applied on top of that fetch's
///   resulting state once it finishes, so stream progress isn't lost to an older pull.
/// - Events that arrive during a fetch may also be in its response, so make updates
///   monotonic, for example `state.seq = max(state.seq, event.seq)`.
/// - If 1,000 updates queue up behind one fetch, they are saved to the stored state right away
///   instead. That fetch's result then replaces them, so those events may be pulled again.
/// - Updates are dropped when there is no successfully synced state, and after the model
///   is unregistered.
///
/// Stream updates never change `lastSyncedAt`, so they don't affect freshness.
public struct SyncStateWriter<Model: SyncedModel>: Sendable {
    private let target: WriterTarget<Model>

    init(target: WriterTarget<Model>) {
        self.target = target
    }

    /// Applies `body` to the persisted sync state and saves it.
    /// Returns once the update is saved, or queued behind an in-flight fetch.
    public func update(_ body: @escaping @Sendable (inout Model.SyncState) -> Void) async {
        await target.actor?.write(body)
    }
}

/// Holds the actor weakly, so a stream task capturing a writer doesn't keep the actor
/// (which owns and cancels that task) alive.
final class WriterTarget<Model: SyncedModel>: @unchecked Sendable {
    // Written once, in `init`, before the target is shared.
    private(set) weak var actor: ModelQueryActor<Model>?

    init(_ actor: ModelQueryActor<Model>) {
        self.actor = actor
    }
}
