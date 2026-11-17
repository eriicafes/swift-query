import Foundation
import SwiftData

/// An ordered state update delivered from a ``QueryActor`` to its client.
struct QuerySnapshot: Sendable {
    enum Status: Sendable {
        case pending
        case success(Data, stale: Bool)
        case error(any Error)

        /// The encoded data, if any.
        var data: Data? {
            if case .success(let data, _) = self { data } else { nil }
        }
    }

    var sequence: UInt64
    var status: Status
    var fetchStatus: QueryFetchStatus
    var error: (any Error)?
}

/// Delays between restarting a stream that ended, and between retries of a stream's failed
/// `begin()` fetch. Each doubles up to `maximum`, and resets once a stream has run that long.
enum StreamBackoff {
    static let initial: Duration = .seconds(1)
    static let maximum: Duration = .seconds(30)
}

/// Serializes synchronization for one fetcher key.
///
/// Runs on the global concurrent executor. Its own `ModelContext` is created lazily and used only
/// for ``QueryRecord`` bookkeeping; each fetch gets a separate fresh context. Keys whose fetcher
/// has no cache keep their record in memory, unattached to any context, and never save it.
actor QueryActor<Fetcher: QueryFetcher> {
    typealias Publisher = @Sendable (QuerySnapshot) async -> Void
    typealias Write = @Sendable (inout Fetcher.QueryData) -> Void
    /// Invalidates other keys that share an evicted key's tags. Called when a sync evicts an
    /// expired key; `remove` and `collectGarbage` return instead, so the provider can batch.
    typealias EvictHandler = @Sendable (_ tags: Set<String>, _ key: String) async -> Void

    nonisolated let modelContainer: ModelContainer
    nonisolated let fetcher: Fetcher
    nonisolated let key: String
    nonisolated let persisted: Bool
    nonisolated let isModel: Bool
    private let fetchContext: Fetcher.Context
    private let publisher: Publisher
    private let onEvict: EvictHandler
    private var context: ModelContext?
    private var memoryRecord: QueryRecord?

    private var loaded = false
    private var status: QuerySnapshot.Status = .pending
    private var fetchStatus: QueryFetchStatus = .idle
    private var lastError: (any Error)?
    private var sequence: UInt64 = 0

    private var inFlight: (id: UInt64, task: Task<Void, Never>)?
    /// The most recent fetch, kept after it leaves `inFlight` so waiters see its final publish.
    private var lastFetch: Task<Void, Never>?
    private var nextFetchID: UInt64 = 0
    /// The most recent fetch that was cancelled, so `query` can report it instead of
    /// returning the previous state as if it were the result.
    private var lastCancelledFetch: UInt64?
    /// The most recent fetch cancelled by an optimistic update, so `query` can return the
    /// optimistic data instead of failing.
    private var optimisticallyCancelledFetch: UInt64?
    /// Whether an optimistic mutation covering this key is in flight. While held, syncs don't
    /// fetch a key that has data, so the server's older data can't overwrite the edit.
    private var held = false
    /// Whether a sync wanted to fetch while the key was held.
    private var deferredFetch = false
    /// How many fetch requests joined an in-flight fetch instead of starting one.
    private(set) var fetchJoins = 0
    /// How many fetches started. For tests.
    private(set) var fetchStarts = 0
    /// How many writes and `synced()` calls are waiting for sync. For tests.
    var waitingWrites: Int { syncWaiters.count }
    private var invalidations: UInt64 = 0
    private var subscriptionTask: Task<Void, Never>?
    private var subscriptionID: UInt64 = 0
    /// How many streams called `begin()`.
    private(set) var subscriptions = 0
    /// Whether the current stream has called `begin()`.
    private var began = false
    /// The first fetch id that syncs the current stream: a fetch that started after `begin()`.
    /// `nil` once one has succeeded.
    private var syncAfter: UInt64?
    /// Whether `begin()` arrived during a fetch that started before it, so another follows it.
    private var followUpFetch = false
    /// Whether a sync wanted to fetch before the stream called `begin()`, which fetches instead.
    private var fetchOnBegin = false
    /// Whether the last `subscribe` returned without calling `begin()`: the key has no live
    /// updates, so syncs fetch right away instead of waiting for `begin()`.
    private var subscribeDeclined = false
    /// Whether the client is gone. Operations it queued before going may still run, but no
    /// stream starts again.
    private var stopped = false
    private var streamStartedAt: ContinuousClock.Instant?
    private var restartDelay: Duration
    private var beginRetryDelay: Duration
    /// The first delay of each backoff. See ``StreamBackoff``.
    private let initialBackoff: Duration
    /// Writes and `synced()` calls waiting for the stream to be synced.
    private var syncWaiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private var nextWaiterID: UInt64 = 0
    /// Callers waiting for a deferred fetch to start or be dropped.
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []
    /// The data from the last successful fetch. A retry of the `begin()` fetch reads `previous`
    /// from it, so data a stream wrote before it synced can't make the fetch skip anything.
    private var lastFetchedData: Data?
    /// Data a stream wrote before it first synced. Kept in memory only, so a cursor it advanced
    /// past events no fetch has covered can't be stored and survive a relaunch. Dropped when a
    /// fetch succeeds or the stream ends.
    private var unsyncedData: Data?
    private var observers = 0
    /// The cache policy of the most recent sync, used by garbage collection so per-view
    /// overrides such as `.swr(gcTime:)` are honored.
    private var lastCache: QueryCache?
    /// How stale `lastAccessedAt` may get before a sync or detach writes it again. Keeps views
    /// that appear often (list rows) from saving on every appearance. Expiry can therefore come
    /// up to this much early, which is negligible next to cache times measured in minutes.
    static var accessResolution: TimeInterval { 60 }
    /// The last stored data known to decode. See `isDecodable`.
    private var validatedData: Data?

    init(
        fetcher: Fetcher,
        key: String,
        modelContainer: ModelContainer,
        fetchContext: Fetcher.Context,
        publisher: @escaping Publisher,
        onEvict: @escaping EvictHandler,
        initialBackoff: Duration = StreamBackoff.initial
    ) {
        self.initialBackoff = initialBackoff
        self.restartDelay = initialBackoff
        self.beginRetryDelay = initialBackoff
        self.fetcher = fetcher
        self.key = key
        self.persisted = fetcher.cache != nil
        self.isModel = Fetcher.self is any ModelFetcherKind.Type
        self.modelContainer = modelContainer
        self.fetchContext = fetchContext
        self.publisher = publisher
        self.onEvict = onEvict
    }

    deinit {
        subscriptionTask?.cancel()
    }

    private var defaultCache: QueryCache { fetcher.cache ?? .forever() }

    /// The bookkeeping context, created on first use so it belongs to this actor.
    private var modelContext: ModelContext {
        if let context { return context }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.context = context
        return context
    }

    // MARK: Operations

    /// Starts observing the key: syncs it and calls `subscribe` if no subscription task is running.
    /// Expiry is only checked when the key was unobserved.
    func attach(_ cache: QueryCache) async {
        let wasUnobserved = observers == 0
        observers += 1
        await sync(cache, checkExpiry: wasUnobserved)
        ensureSubscribed()
    }

    /// Stops observing the key and records the last use.
    func detach() {
        observers = max(0, observers - 1)
        do {
            Self.touch(try record(), now: .now)
            try save()
        } catch {
            rollback()
        }
    }

    /// Checks freshness against `cache` and starts a deduplicated fetch when required.
    /// Returns once the fetch has started, or been left to a stream's `begin()`, not when it
    /// finishes.
    func sync(_ cache: QueryCache) async {
        await sync(cache, checkExpiry: observers == 0)
        if observers > 0 {
            ensureSubscribed()
        }
    }

    /// Syncs again with the most recent cache policy, so a view's override survives a
    /// provider-driven re-sync such as after invalidation.
    func resync() async {
        await sync(lastCache ?? defaultCache)
    }

    /// Fetches regardless of freshness, joining an in-flight fetch if there is one.
    func refresh() async {
        loadIfNeeded()
        await startFetch().task.value
    }

    /// ``refetch()`` if the key has data; a key that was removed or never fetched isn't fetched.
    func refetchIfFetched() async {
        loadIfNeeded()
        guard case .success = status else { return }
        await refetch()
    }

    /// Fetches with a request that starts after this call.
    ///
    /// An in-flight fetch may have been sent before a mutation reached the server, so it is
    /// awaited and then followed by a new fetch. A fetch that started after this call is joined.
    ///
    /// While an optimistic mutation holds the key, the fetch is deferred until the hold ends,
    /// like a sync's, so the server's older data can't overwrite the edit.
    func refetch() async {
        loadIfNeeded()
        if held, case .success = status {
            deferredFetch = true
            return
        }
        if let current = inFlight {
            await current.task.value
            if let next = inFlight, next.id > current.id {
                await next.task.value
                return
            }
        }
        await startFetch().task.value
    }

    /// Returns the stored state if it is fresh under `staleTime` (or the key's own cache policy
    /// when `nil`), otherwise fetches and returns the result. Throws when that fetch fails.
    func query(staleTime: StaleTime?) async throws -> Data {
        loadIfNeeded()
        let record = try record()
        if let data = record.stateData, let lastSyncedAt = record.lastSyncedAt,
           isDecodable(data), !record.invalidated {
            let fresh = switch staleTime {
            case nil: isLive || !(lastCache ?? defaultCache).isStale(lastSyncedAt: lastSyncedAt, now: .now)
            case .infinite: true
            case .after(let duration): Date.now.timeIntervalSince(lastSyncedAt) < duration / .seconds(1)
            }
            if fresh { return data }
        }
        let (id, task) = startFetch()
        await task.value
        if lastCancelledFetch == id {
            // An optimistic update cancelled the fetch so it couldn't overwrite the edit; the
            // optimistic data is the key's current data.
            if optimisticallyCancelledFetch == id, case .success(let data, _) = status {
                return data
            }
            throw CancellationError()
        }
        if case .success(let data, _) = status, lastError == nil {
            return data
        }
        throw lastError ?? CancellationError()
    }

    /// Replaces the stored state, as if a fetch had just returned it.
    func setQueryData(_ data: Data) async {
        loadIfNeeded()
        do {
            let record = try record()
            let now = Date.now
            record.stateData = data
            record.lastSyncedAt = now
            record.lastAccessedAt = now
            record.invalidated = false
            writeMetadata(record, cache: lastCache ?? defaultCache)
            try save()
            status = .success(data, stale: false)
            lastError = nil
            lastFetchedData = data
        } catch {
            rollback()
        }
        await publish()
    }

    /// Cancels the in-flight fetch and applies an optimistic update to the current data, keeping
    /// its sync time and staleness. Returns the data before and after the update, or `nil` if
    /// there is no data. A key without data keeps its fetch.
    ///
    /// The client shows the update before this runs. When it can't be applied, the stored state
    /// is published again so the client stops showing data that was never stored.
    func applyOptimistic(_ update: Write) async -> (previous: Data, applied: Data)? {
        loadIfNeeded()
        guard case .success(let previous, let stale) = status,
              var value = Self.decodedState(previous)
        else {
            await publish()
            return nil
        }
        if let inFlight {
            optimisticallyCancelledFetch = inFlight.id
            inFlight.task.cancel()
        }
        update(&value)
        guard let applied = try? JSONEncoder().encode(value), store(applied, stale: stale) else {
            await publish()
            return nil
        }
        await publish()
        return (previous, applied)
    }

    /// Restores the data from before an optimistic update, if the key still holds that update.
    func restore(_ previous: Data, ifCurrent applied: Data) async {
        guard case .success(let current, let stale) = status, current == applied else { return }
        if store(previous, stale: stale) {
            await publish()
        }
    }

    /// Replaces the stored data without touching its sync time.
    private func store(_ data: Data, stale: Bool) -> Bool {
        do {
            try record().stateData = data
            try save()
            status = .success(data, stale: stale)
            return true
        } catch {
            rollback()
            return false
        }
    }

    /// Marks the stored state as invalidated without fetching.
    func invalidate() async {
        loadIfNeeded()
        invalidations &+= 1
        do {
            let record = try record()
            record.invalidated = true
            try save()
        } catch {
            rollback()
        }
        if case .success(let data, false) = status {
            status = .success(data, stale: true)
            await publish()
        }
    }

    /// Holds syncs from fetching while an optimistic mutation covering the key is in flight.
    func hold() {
        held = true
    }

    /// Asks for a fetch once the hold ends.
    func deferFetch() {
        deferredFetch = true
    }

    /// Ends a hold. Returns whether a sync wanted to fetch meanwhile; the caller fetches then.
    func release() -> Bool {
        held = false
        defer { deferredFetch = false }
        return deferredFetch
    }

    /// Cancels the in-flight fetch. Rows it already saved stay; its sync state is not saved.
    func cancelFetch() {
        inFlight?.task.cancel()
    }

    /// Cancels any fetch and stream, waits for both to stop, then evicts the key's data and clears its state.
    /// Returns whether the key was evicted. The caller invalidates keys sharing its tags.
    ///
    /// Waits for a cancelled fetch to finish before evicting, so rows it saves (including rows
    /// the fetcher saved itself) are evicted too instead of reappearing afterwards.
    func remove() async -> Bool {
        loadIfNeeded()
        // Stop the stream first so it can't start fetches or write while the key is evicted. A
        // fetch a sync was leaving to begin() is dropped, not started, since the key is going.
        clearFetchOnBegin()
        let stream = subscriptionTask
        cancelSubscription()
        await stream?.value
        // A sync while waiting may start another fetch; it is cancelled in turn.
        while let inFlight {
            inFlight.task.cancel()
            await inFlight.task.value
        }
        // No suspension between the loop and eviction, so no fetch can start in between.
        let evicted: Bool
        do {
            try evict(try record())
            evicted = true
        } catch {
            rollback()
            lastError = error
            evicted = false
        }
        await publish()
        return evicted
    }

    /// Syncs again if a view still shows the key, then waits for any fetch in flight. Used by
    /// `reset` after removing it.
    func resyncIfObserved() async {
        guard observers > 0 else { return }
        await sync(lastCache ?? defaultCache, checkExpiry: false)
        ensureSubscribed()
        // With a stream, the sync left the fetch to its begin(). Fetch now instead, so `reset`
        // doesn't depend on the stream connecting; its begin() then fetches again after this.
        if fetchOnBegin {
            clearFetchOnBegin()
            startHeldFetch()
        }
        if let inFlight {
            await inFlight.task.value
        }
    }

    /// Evicts the key if it expired while unobserved and idle, under the cache policy of the
    /// most recent sync, or the key's own policy if there hasn't been one. Returns whether it
    /// was evicted. The caller invalidates keys sharing its tags.
    func collectGarbage() async -> Bool {
        loadIfNeeded()
        guard observers == 0, inFlight == nil, subscriptionTask == nil else { return false }
        do {
            if try evictIfExpired(try record(), cache: lastCache ?? defaultCache, now: .now) {
                await publish()
                return true
            }
        } catch {
            rollback()
        }
        return false
    }

    /// Stops the stream for a client that's gone, without starting a fetch a sync was leaving to
    /// its `begin()`.
    func stop() {
        stopped = true
        clearFetchOnBegin()
        cancelSubscription()
    }

    /// Cancels the stream. Waiting writes throw. The next sync from a view calls `subscribe` again.
    func cancelSubscription() {
        let wasRunning = subscriptionTask != nil
        subscriptionTask?.cancel()
        subscriptionTask = nil
        subscriptionID &+= 1
        if wasRunning {
            streamStopped()
        }
        resetStream()
        // A sync was waiting for begin() to fetch; fetch now instead.
        if fetchOnBegin {
            clearFetchOnBegin()
            startHeldFetch()
        }
    }

    /// Waits until no fetch is in flight and the last one has published its final state.
    func waitForIdle() async {
        while fetchOnBegin {
            await withCheckedContinuation { beginWaiters.append($0) }
        }
        while let inFlight {
            await inFlight.task.value
        }
        await lastFetch?.value
    }

    /// Whether a stream is running.
    var isSubscribed: Bool { subscriptionTask != nil }

    // MARK: Sync

    private func sync(_ cache: QueryCache, checkExpiry: Bool) async {
        loadIfNeeded()
        lastCache = cache
        let now = Date.now
        let needsFetch: Bool
        var evicted = false
        do {
            var record = try record()
            // Never evict while a fetch or a stream is writing the same records.
            if checkExpiry, inFlight == nil, subscriptionTask == nil {
                evicted = try evictIfExpired(record, cache: cache, now: now)
                if evicted { record = try self.record() }
            }
            Self.touch(record, now: now)
            writeMetadata(record, cache: cache)
            try save()
            if let (data, stale) = freshness(of: record, cache: cache, now: now) {
                status = .success(data, stale: stale)
                needsFetch = stale
            } else {
                needsFetch = true
            }
        } catch {
            rollback()
            fail(error)
            await publish()
            return
        }
        if needsFetch {
            if observers > 0, !subscribeDeclined, !began, !stopped {
                // The stream's begin() fetches, so a stream that can't resume gets one fetch that
                // covers its connection instead of two.
                fetchOnBegin = true
            } else {
                startHeldFetch()
            }
        }
        await publish()
        if evicted {
            await onEvict(fetcher.tags, key)
        }
    }

    /// Starts a fetch, or joins the one in flight. Returns its id and task.
    @discardableResult
    private func startFetch() -> (id: UInt64, task: Task<Void, Never>) {
        if let inFlight {
            fetchJoins += 1
            return inFlight
        }
        nextFetchID &+= 1
        fetchStarts += 1
        let id = nextFetchID
        // Registered before any suspension; the task body runs only after this method returns.
        let task = Task { await self.performFetch(id: id) }
        inFlight = (id, task)
        lastFetch = task
        return (id, task)
    }

    private func performFetch(id: UInt64) async {
        let generation = invalidations
        // Until the stream syncs, it may have written data the fetch hasn't covered.
        let baseData = began && syncAfter != nil ? lastFetchedData : try? record().stateData
        let storedData = baseData.flatMap { isDecodable($0) ? $0 : nil }
        fetchStatus = .fetching
        await publish()
        var outcome = FetchOutcome.failed

        do {
            try Task.checkCancellation()
            let fetched = try await Self.runFetch(
                fetcher: fetcher,
                stateData: storedData,
                modelContainer: modelContainer,
                fetchContext: fetchContext
            )
            // A fetch cancelled while running may still return; don't save its rows or state.
            // Checked and saved on the actor with no suspension in between, so a cancel, a
            // removal or a stream's write can't land between the check and the save.
            try Task.checkCancellation()
            if fetched.context.hasChanges {
                try fetched.context.save()
            }
            let data = fetched.data
            let record = try record()
            let now = Date.now
            record.stateData = data
            record.lastSyncedAt = now
            record.lastAccessedAt = now
            if invalidations == generation {
                record.invalidated = false
            }
            writeMetadata(record, cache: lastCache ?? defaultCache)
            try save()
            status = .success(data, stale: record.invalidated)
            lastError = nil
            lastFetchedData = data
            unsyncedData = nil
            outcome = .succeeded
        } catch let error where error is CancellationError || Task.isCancelled {
            // A cancelled fetch is not a failure; keep the previous state. Checked through the
            // task too, since URLSession reports a cancel as `URLError(.cancelled)`.
            rollback()
            lastCancelledFetch = id
            outcome = .cancelled
        } catch {
            rollback()
            fail(error)
        }

        // Only the owner of the in-flight fetch clears it.
        if inFlight?.id == id {
            inFlight = nil
            fetchStatus = .idle
            fetchSettled(id, outcome)
        }
        await publish()
    }

    private enum FetchOutcome { case succeeded, failed, cancelled }

    /// Fetches unless an optimistic mutation holds the key, in which case its release fetches.
    private func startHeldFetch() {
        if held, case .success = status {
            deferredFetch = true
        } else {
            startFetch()
        }
    }

    // MARK: Streams

    /// Whether the stream's `begin()` fetch has succeeded.
    private var streamSynced: Bool { began && syncAfter == nil }

    /// Whether a synced stream keeps the data current, so it doesn't go stale by time, unless the
    /// key asks to refetch anyway.
    private var isLive: Bool { streamSynced && !fetcher.refetchWhileSubscribed }

    /// Whether writes that wait for sync may run.
    private var isSynced: Bool { streamSynced && inFlight == nil }

    /// Calls `subscribe` if no stream is running.
    private func ensureSubscribed() {
        guard subscriptionTask == nil, !stopped else { return }
        subscriptionID &+= 1
        let id = subscriptionID
        resetStream()
        let stored = (try? record().stateData).flatMap { isDecodable($0) ? $0 : nil }
        let writer = QueryWriter<Fetcher.QueryData>(target: WriterBox(self, subscription: id))
        let query = QuerySubscription<Fetcher.Context, Fetcher.QueryData>(
            context: fetchContext,
            previous: Self.decodedState(stored),
            begin: { [weak self] in
                await self?.begin(id)
                return writer
            }
        )
        let fetcher = fetcher
        streamStartedAt = .now
        // Weak, so a running stream doesn't keep this actor (which cancels it on deinit) alive.
        subscriptionTask = Task { [weak self] in
            var failed = false
            do {
                try await Self.runSubscribe(fetcher: fetcher, query: query)
            } catch {
                failed = true
            }
            await self?.subscriptionEnded(id, failed: failed)
        }
    }

    private nonisolated static func runSubscribe(fetcher: Fetcher, query: QuerySubscription<Fetcher.Context, Fetcher.QueryData>) async throws {
        try await fetcher.subscribe(query: query)
    }

    /// Starts the fetch the stream's writes wait for: now, or after the fetch in flight, which
    /// started before the stream was ready.
    private func begin(_ id: UInt64) {
        guard id == subscriptionID, subscriptionTask != nil, !began else { return }
        began = true
        subscriptions += 1
        clearFetchOnBegin()
        if let inFlight {
            syncAfter = inFlight.id &+ 1
            followUpFetch = true
        } else {
            syncAfter = nextFetchID &+ 1
            startHeldFetch()
        }
    }

    /// Handles a stream that returned or threw on its own.
    private func subscriptionEnded(_ id: UInt64, failed: Bool) {
        guard id == subscriptionID, subscriptionTask != nil else { return }
        let didBegin = began
        let wantedFetch = fetchOnBegin
        subscriptionTask = nil
        streamStopped()
        resetStream()
        clearFetchOnBegin()
        if !didBegin && !failed {
            // No live updates for this key.
            subscribeDeclined = true
            if wantedFetch { startHeldFetch() }
            return
        }
        subscribeDeclined = false
        // A sync waiting for this stream's begin() fetches now instead, so a stream that fails to
        // connect doesn't leave the data unfetched, and doesn't refetch data that's still fresh.
        if !didBegin && wantedFetch { startHeldFetch() }
        guard observers > 0 else { return }
        if let started = streamStartedAt, started.duration(to: .now) >= StreamBackoff.maximum {
            restartDelay = initialBackoff
        }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, StreamBackoff.maximum)
        let generation = subscriptionID
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.restartSubscription(generation)
        }
    }

    private func restartSubscription(_ generation: UInt64) {
        guard subscriptionID == generation, subscriptionTask == nil, observers > 0 else { return }
        ensureSubscribed()
    }

    /// Records a use of the key, since the stream kept it in use after its last view went away,
    /// and publishes its staleness again if a synced stream was keeping it fresh. Call before
    /// `resetStream`.
    private func streamStopped() {
        do {
            Self.touch(try record(), now: .now)
            try save()
        } catch {
            rollback()
        }
        guard isLive else { return }
        began = false
        if let record = try? record(), let (data, stale) = freshness(of: record, cache: lastCache ?? defaultCache, now: .now),
           case .success(_, false) = status, stale {
            status = .success(data, stale: true)
            Task { [weak self] in await self?.publishStatus() }
        }
    }

    private func publishStatus() async {
        await publish()
    }

    /// Clears the stream's sync state and fails its waiting writes. A fetch deferred to `begin()`
    /// stays deferred; whoever ends the stream decides what happens to it.
    private func resetStream() {
        began = false
        syncAfter = nil
        followUpFetch = false
        beginRetryDelay = initialBackoff
        if unsyncedData != nil {
            // Show the stored data again instead of what the stream wrote before it synced.
            unsyncedData = nil
            if let record = try? record(),
               let (data, stale) = freshness(of: record, cache: lastCache ?? defaultCache, now: .now) {
                status = .success(data, stale: stale)
                Task { [weak self] in await self?.publishStatus() }
            }
        }
        let waiters = syncWaiters.values
        syncWaiters = [:]
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    private func clearFetchOnBegin() {
        fetchOnBegin = false
        let waiters = beginWaiters
        beginWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Updates the stream's sync state after a fetch settles, and resumes writes once synced.
    private func fetchSettled(_ id: UInt64, _ outcome: FetchOutcome) {
        if began, let after = syncAfter {
            if outcome == .succeeded, id >= after {
                syncAfter = nil
                beginRetryDelay = initialBackoff
            } else if followUpFetch {
                followUpFetch = false
                startHeldFetch()
            } else if id >= after {
                if outcome == .cancelled, optimisticallyCancelledFetch == id {
                    // An optimistic update's cancel fetches again once its hold ends.
                    startHeldFetch()
                } else {
                    // A failure, or a cancel from `cancel()`: the cancelled request stays
                    // stopped, and the stream syncs with a retry after a backoff instead of
                    // leaving its writes waiting until something else fetches.
                    scheduleBeginRetry()
                }
            }
        }
        guard isSynced else { return }
        let waiters = syncWaiters.values
        syncWaiters = [:]
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func scheduleBeginRetry() {
        let delay = beginRetryDelay
        beginRetryDelay = min(beginRetryDelay * 2, StreamBackoff.maximum)
        let generation = subscriptionID
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.retryBeginFetch(generation)
        }
    }

    private func retryBeginFetch(_ generation: UInt64) {
        guard generation == subscriptionID, began, syncAfter != nil, inFlight == nil else { return }
        startHeldFetch()
    }

    private func checkStream(_ id: UInt64) throws {
        guard id == subscriptionID, subscriptionTask != nil, began, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func waitUntilSynced(_ id: UInt64) async throws {
        try checkStream(id)
        while !isSynced {
            nextWaiterID &+= 1
            let waiter = nextWaiterID
            // A caller whose task is cancelled stops waiting right away, like any other await.
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        syncWaiters[waiter] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(waiter) }
            }
            try checkStream(id)
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        syncWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Runs a stream's write: the closure and the saves happen with no suspension in between, so
    /// no fetch can start or save during them. If the closure throws, nothing is saved.
    private func performWrite<R: Sendable>(
        _ body: (inout QueryWriter<Fetcher.QueryData>.Transaction) throws -> R
    ) async throws -> R {
        loadIfNeeded()
        // A fresh context per write, so rows are read as the store has them now, not as an
        // earlier write left them, and a long stream doesn't keep every row it wrote in memory.
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let record = try record()
        let stored = record.stateData.flatMap { isDecodable($0) ? $0 : nil }
        let previousUnsynced = unsyncedData
        let initial = Self.decodedState(unsyncedData ?? stored)
        // Before the stream syncs, data stays in memory; see `unsyncedData`.
        let storesData = streamSynced
        var tx = QueryWriter<Fetcher.QueryData>.Transaction(
            modelContext: context,
            data: initial,
            isSynced: isSynced
        )
        let result = try body(&tx)
        // Compared with sorted keys, so data holding a dictionary doesn't look changed when it isn't.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var changedData: Data?
        if let data = tx.data, let encoded = try? encoder.encode(data),
           encoded != initial.flatMap({ try? encoder.encode($0) }) {
            changedData = encoded
        }
        // Data, then rows, with no suspension in between or before: no fetch can start or save
        // during the write. The data goes first because it can be put back if the rows fail.
        if let changedData {
            if storesData {
                record.stateData = changedData
                do {
                    try save()
                } catch {
                    rollback()
                    record.stateData = stored
                    throw error
                }
            } else {
                unsyncedData = changedData
            }
        }
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                context.rollback()
                if changedData != nil {
                    if storesData {
                        record.stateData = stored
                        do { try save() } catch { rollback() }
                    } else {
                        unsyncedData = previousUnsynced
                    }
                }
                throw error
            }
        }
        guard let changedData else { return result }
        if storesData {
            if let (data, stale) = freshness(of: record, cache: lastCache ?? defaultCache, now: .now) {
                status = .success(data, stale: stale)
                await publish()
            }
        } else if record.lastSyncedAt != nil {
            // Shown, but the key doesn't count as fetched until the stream syncs.
            let stale = if case .success(_, let stale) = status { stale } else { true }
            status = .success(changedData, stale: stale)
            await publish()
        }
        return result
    }

    // MARK: Helpers

    /// Keeps usable metadata on failure: a previous success becomes stale instead of an error.
    private func fail(_ error: any Error) {
        lastError = error
        if case .success(let data, _) = status {
            status = .success(data, stale: true)
        } else {
            status = .error(error)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let record = try? record(),
              let (data, stale) = freshness(of: record, cache: defaultCache, now: .now)
        else { return }
        status = .success(data, stale: stale)
        lastFetchedData = data
    }

    /// Returns the stored state and whether it is stale, or `nil` when there is no usable state.
    /// QueryData that no longer decodes, for example after `QueryData` changed in an app update,
    /// counts as missing so the next sync fetches from the default state.
    private func freshness(of record: QueryRecord, cache: QueryCache, now: Date) -> (Data, Bool)? {
        guard let data = record.stateData,
              let lastSyncedAt = record.lastSyncedAt,
              isDecodable(data)
        else { return nil }
        let stale = record.invalidated || (!isLive && cache.isStale(lastSyncedAt: lastSyncedAt, now: now))
        return (data, stale)
    }

    private func evictIfExpired(_ record: QueryRecord, cache: QueryCache, now: Date) throws -> Bool {
        guard record.stateData != nil,
              let lastAccessedAt = record.lastAccessedAt ?? record.lastSyncedAt,
              cache.isExpired(lastAccessedAt: lastAccessedAt, now: now)
        else { return false }
        try evict(record)
        return true
    }

    /// Clears the key's metadata first, then evicts its data: if evicting fails, the data stays
    /// and the next sync refetches it, instead of empty data being treated as fresh.
    private func evict(_ record: QueryRecord) throws {
        cancelSubscription()
        clear(record)
        try save()
        status = .pending
        lastError = nil
        // The next fetch starts from nothing, not from the evicted data's cursor or ETag.
        lastFetchedData = nil

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        try fetcher.evict(query: QueryEvict(modelContext: context, context: fetchContext))
        if context.hasChanges {
            try context.save()
        }
    }

    /// A model's record is kept and cleared; a fetcher key's record is deleted.
    private func clear(_ record: QueryRecord) {
        if isModel {
            record.stateData = nil
            record.lastSyncedAt = nil
            record.invalidated = false
        } else if persisted {
            modelContext.delete(record)
        } else {
            memoryRecord = nil
        }
    }

    /// Stores the key's tags and cache time, so expiry and tag invalidation work for keys
    /// without a live client.
    private func writeMetadata(_ record: QueryRecord, cache: QueryCache) {
        let tags = QueryRecord.Tags.encode(fetcher.tags)
        if record.tags != tags {
            record.tags = tags
        }
        let gcTime = cache.gcTime.map { $0 / .seconds(1) }
        if record.gcTime != gcTime {
            record.gcTime = gcTime
        }
    }

    /// Records a use of the cache, unless one was recorded within ``accessResolution``.
    private static func touch(_ record: QueryRecord, now: Date) {
        if let last = record.lastAccessedAt, now.timeIntervalSince(last) < accessResolution {
            return
        }
        record.lastAccessedAt = now
    }

    /// Whether `data` decodes as `QueryData`. The last data known to decode is remembered, so
    /// checking unchanged state compares bytes instead of decoding it again.
    private func isDecodable(_ data: Data) -> Bool {
        if data == validatedData { return true }
        guard Self.decodedState(data) != nil else { return false }
        validatedData = data
        return true
    }

    private static func decodedState(_ data: Data?) -> Fetcher.QueryData? {
        data.flatMap { try? JSONDecoder().decode(Fetcher.QueryData.self, from: $0) }
    }

    /// Runs the fetch outside actor isolation with a fresh context, and hands the context back
    /// unsaved so the actor saves it. Only `Sendable` values and that context cross.
    private static func runFetch(
        fetcher: Fetcher,
        stateData: Data?,
        modelContainer: ModelContainer,
        fetchContext: Fetcher.Context
    ) async throws -> sending FetchedState {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let state = try await fetcher.fetch(
            query: QueryFetch(modelContext: context, context: fetchContext, previous: decodedState(stateData))
        )
        return FetchedState(data: try JSONEncoder().encode(state), context: context)
    }

    /// A fetch's encoded state and its unsaved rows.
    private final class FetchedState {
        let data: Data
        let context: ModelContext

        init(data: Data, context: ModelContext) {
            self.data = data
            self.context = context
        }
    }

    private func save() throws {
        if persisted, modelContext.hasChanges {
            try modelContext.save()
        }
    }

    private func rollback() {
        if persisted {
            modelContext.rollback()
        }
    }

    /// The key's record. Without a unique constraint (which CloudKit forbids), duplicates can
    /// appear, so extras are removed and the most recently synced one kept. Keys without a
    /// cache use a record held in memory only.
    private func record() throws -> QueryRecord {
        guard persisted else {
            if let memoryRecord { return memoryRecord }
            let record = QueryRecord(key: key)
            memoryRecord = record
            return record
        }
        let records = try modelContext.fetch(QueryRecord.descriptor(key: key))
        if let keep = QueryRecord.latest(records) {
            if records.count > 1 {
                for extra in records where extra !== keep {
                    modelContext.delete(extra)
                }
                try modelContext.save()
            }
            return keep
        }
        let record = QueryRecord(key: key)
        modelContext.insert(record)
        return record
    }

    private func publish() async {
        sequence &+= 1
        await publisher(
            QuerySnapshot(
                sequence: sequence,
                status: status,
                fetchStatus: fetchStatus,
                error: lastError
            )
        )
    }
}

extension QueryActor: QueryWriterTarget {
    typealias QueryData = Fetcher.QueryData

    func write<R: Sendable>(
        subscription id: UInt64,
        timing: QueryWriter<QueryData>.Timing,
        _ body: @escaping @Sendable (inout QueryWriter<QueryData>.Transaction) throws -> R
    ) async throws -> R {
        try checkStream(id)
        if timing == .synced {
            try await waitUntilSynced(id)
        }
        return try await performWrite(body)
    }

    func waitUntilSynced(subscription id: UInt64) async throws {
        try await waitUntilSynced(id)
    }
}
