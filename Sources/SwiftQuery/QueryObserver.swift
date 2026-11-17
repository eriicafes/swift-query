import Foundation
import Observation
import SwiftData

/// The observable, main-actor interface to one key's synchronization: a model collection or a
/// ``QueryFetcher`` value.
///
/// A ``QueryProvider`` creates one shared client per key, lazily. Views obtain it with
/// ``QueryClient`` and read rows with SwiftData's `@Query`; a fetcher's own data is read from
/// ``data``.
@Observable
@MainActor
public final class QueryObserver<Fetcher: QueryFetcher> {
    /// The query state: its status, data and staleness.
    public private(set) var state: QueryState<Fetcher.QueryData> = .pending
    /// The current fetch activity.
    public private(set) var fetchStatus: QueryFetchStatus = .idle

    /// The data from the last successful fetch, if any. Shorthand for `state.data`.
    public var data: Fetcher.QueryData? { state.data }
    /// Whether the first fetch is running: nothing fetched yet, and a fetch in flight.
    public var isLoading: Bool { state.isPending && fetchStatus == .fetching }
    /// Whether any fetch is running.
    public var isFetching: Bool { fetchStatus == .fetching }
    /// The error of the last failed fetch, cleared by the next successful fetch.
    ///
    /// When a refresh fails after a previous success, ``state`` stays a stale
    /// `success` and the failure is reported here.
    public private(set) var error: (any Error)?

    /// The key this client syncs.
    public let fetcher: Fetcher
    /// The container whose main context is used for optimistic updates.
    public let modelContainer: ModelContainer

    @ObservationIgnored let recordKey: String
    @ObservationIgnored private let actor: QueryActor<Fetcher>
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var lastSequence: UInt64 = 0
    @ObservationIgnored private var stateData: Data?
    @ObservationIgnored let provider: QueryProvider
    @ObservationIgnored private var observerCount = 0
    private var mutationCount = 0
    @ObservationIgnored private var wasActive = false
    /// Told whenever the client starts or stops being in use, so the provider can keep or drop it.
    @ObservationIgnored var onActivityChange: (@MainActor () -> Void)?
    /// Bumped whenever the client becomes idle; a pending release only applies to its own idle spell.
    @ObservationIgnored var idleGeneration: UInt64 = 0

    /// Created only by ``QueryProvider``, so each key has a single client and actor.
    init(
        fetcher: Fetcher,
        recordKey: String,
        modelContainer: ModelContainer,
        fetchContext: Fetcher.Context,
        provider: QueryProvider,
        gate: Task<Void, Never>? = nil,
        initialLoad: InitialLoad = .stored,
        onEvict: @escaping QueryActor<Fetcher>.EvictHandler = { _, _ in }
    ) {
        let streamBackoff = provider.streamBackoff
        let sink = SnapshotSink<Fetcher>()
        self.fetcher = fetcher
        self.recordKey = recordKey
        self.modelContainer = modelContainer
        self.provider = provider
        self.actor = QueryActor(
            fetcher: fetcher,
            key: recordKey,
            modelContainer: modelContainer,
            fetchContext: fetchContext,
            publisher: { snapshot in await sink.receive(snapshot) },
            onEvict: onEvict,
            initialBackoff: streamBackoff
        )
        sink.client = self
        // Operations wait for store work on this key that was still running at creation.
        tail = gate
        loadInitialState(initialLoad)
    }

    deinit {
        // A stream's waiting write keeps the actor alive, so stop the stream here rather than
        // relying on the actor's deinit, or a released key would keep its stream and retries.
        let actor = actor
        Task { await actor.stop() }
    }

    /// How a new client fills ``state`` before its first sync.
    enum InitialLoad {
        /// From the stored record.
        case stored
        /// From the stored record, marked stale: an invalidation of the key is being saved.
        case storedStale
        /// Not at all: the key's record is being evicted.
        case skip
    }

    /// Whether a view observes the client, or a fetch or mutation is running.
    var isActive: Bool {
        observerCount > 0 || mutationCount > 0 || fetchStatus != .idle
    }

    var isObserved: Bool { observerCount > 0 }

    private var defaultCache: QueryCache { fetcher.cache ?? .forever() }

    private func activityChanged() {
        let active = isActive
        guard active != wasActive else { return }
        wasActive = active
        onActivityChange?()
    }

    // MARK: Synchronization

    /// Schedules a freshness check using the model's default cache policy,
    /// fetching if the data is stale, invalidated, or missing.
    public func sync() {
        sync(defaultCache)
    }

    /// Schedules a freshness check using `cache` for this request only.
    public func sync(_ cache: QueryCache) {
        enqueue { await $0.sync(cache) }
    }

    /// Fetches regardless of freshness. Joins an in-flight fetch instead of starting another.
    public func refresh() async {
        await tail?.value
        await actor.refresh()
    }

    /// Marks the cached data as invalidated. The next sync fetches, even for `.forever()`.
    /// Existing data stays available and no fetch is started.
    public func invalidate() {
        enqueue { await $0.invalidate() }
    }

    /// Cancels the in-flight fetch, if any. Rows it already saved stay, its sync state is not
    /// saved, and ``state`` keeps its previous value. Call it before an optimistic update so a
    /// slow fetch sent earlier can't overwrite the edit.
    public func cancel() {
        enqueue { await $0.cancelFetch() }
    }

    /// Cancels the task returned by `subscribe`, if any. The next sync from a view calls
    /// `subscribe` again.
    public func unsubscribe() {
        enqueue { await $0.cancelSubscription() }
    }

    // MARK: Mutations

    /// Whether a mutation started with ``mutate(scope:invalidates:_:optimistic:)`` is queued,
    /// running, or waiting for its keys to refetch. In a scope, only the last mutation waits for
    /// the refetch.
    public var isMutating: Bool { mutationCount > 0 }

    /// Runs a remote mutation with ``QueryProvider/mutate(scope:invalidates:_:optimistic:)``,
    /// adding this client's key to `invalidates`.
    ///
    /// ```swift
    /// try await postsClient.mutate {
    ///     try await api.deletePost(id)
    /// } optimistic: { tx in
    ///     let post = try tx.modelContext.fetch(descriptor).first
    ///     post.map(tx.modelContext.delete)
    /// }
    /// ```
    ///
    /// Since the client's key is in `invalidates`, a mutation that fails skips its rollback when
    /// a newer optimistic mutation from this client, or any other covering its key, has started
    /// since, so it can't clobber the newer change. This client's data then refetches even if no
    /// view shows it.
    @discardableResult
    public func mutate<Result>(
        scope: (any Hashable & Sendable)? = nil,
        invalidates: [QueryFilter] = [],
        _ mutation: @escaping @Sendable () async throws -> sending Result,
        optimistic: OptimisticUpdate? = nil
    ) async throws -> Result {
        mutationCount += 1
        activityChanged()
        defer {
            mutationCount -= 1
            activityChanged()
        }
        let run = try provider.beginMutation(
            scope: scope,
            invalidates: invalidates + [.key(self)],
            optimistic: optimistic
        )
        return try await provider.finishMutation(run, mutation)
    }

    /// Updates the query data optimistically: right away in ``state``, then in storage after
    /// cancelling the in-flight fetch. Returns a closure that restores the previous data if the
    /// key still holds this update, or `nil` if there was no data to update.
    func applyOptimistic(_ update: @escaping QueryActor<Fetcher>.Write) -> (@MainActor () async -> Void)? {
        guard var value = state.data else { return nil }
        update(&value)
        if let data = try? JSONEncoder().encode(value) {
            stateData = data
            state = .success(data: value, stale: state.isStale)
        }
        let previous = tail
        let actor = actor
        let write = Task {
            await previous?.value
            return await actor.applyOptimistic(update)
        }
        tail = Task { _ = await write.value }
        return {
            guard let (previous, applied) = await write.value else { return }
            await actor.restore(previous, ifCurrent: applied)
        }
    }

    // MARK: Internal

    /// Whether syncs are held for an optimistic mutation in flight. Set by the provider.
    @ObservationIgnored private(set) var isHeld = false

    func hold() {
        guard !isHeld else { return }
        isHeld = true
        enqueue { await $0.hold() }
    }

    /// Asks for a fetch once the hold ends.
    func deferFetch() {
        enqueue { await $0.deferFetch() }
    }

    /// Ends the hold, returning whether a sync wanted to fetch meanwhile.
    func release() async -> Bool {
        guard isHeld else { return false }
        isHeld = false
        let previous = tail
        let actor = actor
        let released = Task {
            await previous?.value
            return await actor.release()
        }
        tail = Task { _ = await released.value }
        return await released.value
    }

    func attach(_ cache: QueryCache?) {
        observerCount += 1
        activityChanged()
        let cache = cache ?? defaultCache
        enqueue { await $0.attach(cache) }
    }

    /// Syncs again with the key's most recent cache policy.
    func resync() {
        enqueue { await $0.resync() }
    }

    func detach() {
        observerCount = max(0, observerCount - 1)
        activityChanged()
        enqueue { await $0.detach() }
    }

    func query(staleTime: StaleTime?) async throws -> Fetcher.QueryData {
        await tail?.value
        let data = try await actor.query(staleTime: staleTime)
        return try JSONDecoder().decode(Fetcher.QueryData.self, from: data)
    }

    func setQueryData(_ value: Fetcher.QueryData) async throws {
        let data = try JSONEncoder().encode(value)
        await tail?.value
        await actor.setQueryData(data)
    }

    /// Fetches with a request sent after this call if the key has data, once the operations
    /// already queued have run. A key removed or never fetched isn't fetched.
    func refetchIfFetched() async {
        await tail?.value
        await actor.refetchIfFetched()
    }

    /// Cancels the in-flight fetch once the operations already queued have run.
    func cancelFetch() async {
        await tail?.value
        await actor.cancelFetch()
    }

    /// Removes the key's data. Returns whether it was evicted.
    func remove() async -> Bool {
        // Takes a place in the queue, so syncs queued meanwhile run after the removal instead of
        // starting a stream or fetch while it waits for the old ones to stop.
        let previous = tail
        let actor = actor
        let removal = Task {
            await previous?.value
            return await actor.remove()
        }
        tail = Task { _ = await removal.value }
        return await removal.value
    }

    /// Syncs again if a view still shows the key, waiting for any fetch it starts to finish.
    func resyncIfObserved() async {
        await tail?.value
        await actor.resyncIfObserved()
    }

    func isSubscribed() async -> Bool {
        await actor.isSubscribed
    }

    func subscriptions() async -> Int {
        await actor.subscriptions
    }

    /// Fetches with a request sent after this call; see ``QueryActor/refetch()``.
    func refetch() async {
        await tail?.value
        await actor.refetch()
    }

    /// Evicts the key if its cache expired. Returns whether it was evicted.
    func collectGarbage() async -> Bool {
        await tail?.value
        return await actor.collectGarbage()
    }

    /// Waits for scheduled operations and any in-flight fetch to finish.
    /// Waits for scheduled operations only, not for any fetch they started.
    func settleOperations() async {
        await tail?.value
    }

    /// How many fetch requests have joined an in-flight fetch.
    func fetchJoins() async -> Int {
        await actor.fetchJoins
    }

    /// How many fetches started.
    func fetchStarts() async -> Int {
        await actor.fetchStarts
    }

    /// How many writes are waiting for the stream to sync.
    func waitingWrites() async -> Int {
        await actor.waitingWrites
    }

    func settle() async {
        await tail?.value
        await actor.waitForIdle()
    }

    /// Applies a snapshot, assigning only what changed so views aren't invalidated needlessly.
    func receive(_ snapshot: QuerySnapshot) {
        guard snapshot.sequence > lastSequence else { return }
        lastSequence = snapshot.sequence
        switch snapshot.status {
        case .pending:
            stateData = nil
            if !state.isPending {
                state = .pending
            }
        case .success(let data, let stale):
            guard data != stateData || stale != state.isStale || state.data == nil else { break }
            if let value = try? JSONDecoder().decode(Fetcher.QueryData.self, from: data) {
                stateData = data
                state = .success(data: value, stale: stale)
            } else {
                stateData = nil
                state = .pending
            }
        case .error(let error):
            stateData = nil
            state = .error(error)
        }
        if fetchStatus != snapshot.fetchStatus {
            fetchStatus = snapshot.fetchStatus
            activityChanged()
        }
        if snapshot.error != nil || error != nil {
            error = snapshot.error
        }
    }

    /// Runs operations in call order. Operations only check state and start fetches,
    /// so they never wait behind a running fetch.
    private func enqueue(_ operation: @escaping @Sendable (QueryActor<Fetcher>) async -> Void) {
        let previous = tail
        let actor = actor
        tail = Task {
            await previous?.value
            await operation(actor)
        }
    }

    /// Reads persisted metadata synchronously so views don't flash `.pending` on launch.
    private func loadInitialState(_ load: InitialLoad) {
        guard load != .skip, fetcher.cache != nil,
              let (value, data, stale) = Self.storedState(fetcher, key: recordKey, in: modelContainer.mainContext)
        else { return }
        stateData = data
        state = .success(data: value, stale: stale || load == .storedStale)
    }

    /// Decodes a key's stored state, if it has usable state.
    static func storedState(
        _ fetcher: Fetcher,
        key: String,
        in context: ModelContext
    ) -> (Fetcher.QueryData, Data, stale: Bool)? {
        guard let record = try? QueryRecord.latest(context.fetch(QueryRecord.descriptor(key: key))),
              let data = record.stateData,
              let lastSyncedAt = record.lastSyncedAt,
              let value = try? JSONDecoder().decode(Fetcher.QueryData.self, from: data)
        else { return nil }
        let stale = record.invalidated
            || (fetcher.cache ?? .forever()).isStale(lastSyncedAt: lastSyncedAt, now: .now)
        return (value, data, stale)
    }
}

/// Delivers snapshots to a client without the actor retaining it.
@MainActor
private final class SnapshotSink<Fetcher: QueryFetcher> {
    weak var client: QueryObserver<Fetcher>?

    func receive(_ snapshot: QuerySnapshot) {
        client?.receive(snapshot)
    }
}

@MainActor
protocol AnyQueryObserver: AnyObject {
    var recordKey: String { get }
    var tagSet: Set<String> { get }
    var isActive: Bool { get }
    var isObserved: Bool { get }
    /// Whether nothing was fetched and no fetch is running.
    var isUnfetched: Bool { get }
    var isModel: Bool { get }
    var idleGeneration: UInt64 { get set }
    func collectGarbage() async -> Bool
    func invalidate()
    func resync()
    func refresh() async
    func refetch() async
    func settleOperations() async
    var isHeld: Bool { get }
    func hold()
    func deferFetch()
    func release() async -> Bool
    func cancel()
    func cancelFetch() async
    func unsubscribe()
    func remove() async -> Bool
    func resyncIfObserved() async
}

extension QueryObserver: AnyQueryObserver {
    var tagSet: Set<String> { fetcher.tags }
    var isUnfetched: Bool { state.isPending && fetchStatus == .idle }
    var isModel: Bool { Fetcher.self is any ModelFetcherKind.Type }
}
