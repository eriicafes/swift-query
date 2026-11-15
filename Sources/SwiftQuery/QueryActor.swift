import Foundation
import SwiftData

/// An ordered state update delivered from a ``QueryActor`` to its client.
struct QuerySnapshot: Sendable {
    enum Status: Sendable {
        case pending
        case success(Data, stale: Bool)
        case error(any Error)
    }

    var sequence: UInt64
    var status: Status
    var fetchStatus: QueryFetchStatus
    var error: (any Error)?
}

/// Serializes synchronization for one fetcher key.
///
/// Runs on the global concurrent executor. Its own `ModelContext` is created lazily and used only
/// for ``QueryRecord`` bookkeeping; each fetch gets a separate fresh context. Keys whose fetcher
/// has no cache keep their record in memory, unattached to any context, and never save it.
actor QueryActor<Fetcher: QueryFetcher> {
    typealias Publisher = @Sendable (QuerySnapshot) async -> Void
    typealias Write = @Sendable (inout Fetcher.State) -> Void
    /// Invalidates other keys that share an evicted key's tags.
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
    /// How many fetch requests joined an in-flight fetch instead of starting one.
    private(set) var fetchJoins = 0
    private var invalidations: UInt64 = 0
    private var streamTask: Task<Void, Never>?
    private var streamID: UInt64 = 0
    /// How many times `subscribe` returned a stream.
    private(set) var subscriptions = 0
    private var observers = 0
    /// The cache policy of the most recent sync, used by garbage collection so per-view
    /// overrides such as `.swr(cacheTime:)` are honored.
    private var lastCache: QueryCache?
    /// Stream writes received while a fetch is in flight, applied after it finishes.
    private var pendingWrites: [Write] = []
    /// Most writes kept behind one fetch. Beyond this they are saved to the stored state right
    /// away, so a fetch that never finishes can't grow the queue without bound.
    static var pendingWriteLimit: Int { 1_000 }
    /// How stale `lastAccessedAt` may get before a sync or detach writes it again. Keeps views
    /// that appear often (list rows) from saving on every appearance. Expiry can therefore come
    /// up to this much early, which is negligible next to cache times measured in minutes.
    static var accessResolution: TimeInterval { 60 }
    private var stateWriter: StateWriter<Fetcher.State>?

    init(
        fetcher: Fetcher,
        key: String,
        modelContainer: ModelContainer,
        fetchContext: Fetcher.Context,
        publisher: @escaping Publisher,
        onEvict: @escaping EvictHandler
    ) {
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
        streamTask?.cancel()
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

    /// The writer handed to `subscribe`. It holds this actor weakly.
    private var writer: StateWriter<Fetcher.State> {
        if let stateWriter { return stateWriter }
        let writer = StateWriter<Fetcher.State> { [weak self] body in
            await self?.write(body)
        }
        stateWriter = writer
        return writer
    }

    // MARK: Operations

    /// Starts observing the key: syncs it and starts its stream if none is running.
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
    /// Returns once the fetch has started, not when it finishes.
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

    /// Fetches with a request that starts after this call.
    ///
    /// An in-flight fetch may have been sent before a mutation reached the server, so it is
    /// awaited and then followed by a new fetch. A fetch that started after this call is joined.
    func refetch() async {
        loadIfNeeded()
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
           Self.isDecodable(data), !record.invalidated {
            let fresh = switch staleTime {
            case nil: !(lastCache ?? defaultCache).isStale(lastSyncedAt: lastSyncedAt, now: .now)
            case .infinite: true
            case .after(let duration): Date.now.timeIntervalSince(lastSyncedAt) < duration / .seconds(1)
            }
            if fresh { return data }
        }
        let (id, task) = startFetch()
        await task.value
        if lastCancelledFetch == id {
            throw CancellationError()
        }
        if case .success(let data, _) = status, lastError == nil {
            return data
        }
        throw lastError ?? CancellationError()
    }

    /// Replaces the stored state, as if a fetch had just returned it.
    func setState(_ data: Data) async {
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
        } catch {
            rollback()
        }
        await publish()
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

    /// Cancels the in-flight fetch. Rows it already saved stay; its sync state is not saved.
    func cancelFetch() {
        inFlight?.task.cancel()
    }

    /// Cancels any fetch and stream, then evicts the key's data and clears its state.
    func remove() async {
        loadIfNeeded()
        inFlight?.task.cancel()
        pendingWrites.removeAll()
        do {
            try evict(try record())
        } catch {
            rollback()
            lastError = error
        }
        await publish()
        await onEvict(fetcher.tags, key)
    }

    /// Removes the key, then syncs it again if a view still shows it.
    func reset() async {
        await remove()
        if observers > 0 {
            await sync(lastCache ?? defaultCache, checkExpiry: false)
            ensureSubscribed()
        }
    }

    /// Evicts the key if it expired while unobserved and idle, under the cache policy of the
    /// most recent sync, or the key's own policy if there hasn't been one.
    func collectGarbage() async {
        loadIfNeeded()
        guard observers == 0, inFlight == nil else { return }
        do {
            if try evictIfExpired(try record(), cache: lastCache ?? defaultCache, now: .now) {
                await publish()
                await onEvict(fetcher.tags, key)
            }
        } catch {
            rollback()
        }
    }

    /// Cancels the running stream. The next sync from a view starts a new one.
    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        streamID &+= 1
    }

    /// Applies a stream write now, or queues it behind the in-flight fetch.
    func write(_ body: @escaping Write) async {
        if inFlight != nil {
            pendingWrites.append(body)
            if pendingWrites.count >= Self.pendingWriteLimit {
                let overflow = pendingWrites
                pendingWrites = []
                await persist(overflow)
            }
            return
        }
        await persist([body])
    }

    /// Waits until no fetch is in flight and the last one has published its final state.
    func waitForIdle() async {
        while let inFlight {
            await inFlight.task.value
        }
        await lastFetch?.value
    }

    /// Whether a stream is running.
    var isStreaming: Bool { streamTask != nil }

    // MARK: Sync

    private func sync(_ cache: QueryCache, checkExpiry: Bool) async {
        loadIfNeeded()
        lastCache = cache
        let now = Date.now
        let needsFetch: Bool
        var evicted = false
        do {
            var record = try record()
            // Never evict while a fetch is writing the same records.
            if checkExpiry, inFlight == nil {
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
            startFetch()
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
        let id = nextFetchID
        // Registered before any suspension; the task body runs only after this method returns.
        let task = Task { await self.performFetch(id: id) }
        inFlight = (id, task)
        lastFetch = task
        return (id, task)
    }

    private func performFetch(id: UInt64) async {
        let generation = invalidations
        let storedData = (try? record().stateData).flatMap { Self.isDecodable($0) ? $0 : nil }
        fetchStatus = storedData == nil ? .loading : .fetching
        await publish()

        do {
            try Task.checkCancellation()
            let fetchedData = try await Self.runFetch(
                fetcher: fetcher,
                stateData: storedData,
                modelContainer: modelContainer,
                fetchContext: fetchContext
            )
            // A fetch cancelled while running may still return; don't save its state.
            try Task.checkCancellation()
            // Stream progress made during the fetch goes on top of the fetched state.
            let applied = pendingWrites
            pendingWrites = []
            let data = Self.applying(applied, to: fetchedData) ?? fetchedData
            do {
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
            } catch {
                pendingWrites = applied + pendingWrites
                throw error
            }
        } catch is CancellationError {
            // A cancelled fetch is not a failure; keep the previous state.
            rollback()
            lastCancelledFetch = id
        } catch {
            rollback()
            fail(error)
        }

        // Only the owner of the in-flight fetch clears it. Writes still queued (after a failed
        // fetch) apply to the stored state; later writes no longer queue.
        var leftover: [Write] = []
        if inFlight?.id == id {
            inFlight = nil
            fetchStatus = .idle
            leftover = pendingWrites
            pendingWrites = []
        }
        await persist(leftover)
        await publish()
    }

    /// Applies writes to the stored state and saves it. Dropped when nothing has synced yet.
    private func persist(_ writes: [Write]) async {
        guard !writes.isEmpty else { return }
        do {
            let record = try record()
            guard let data = record.stateData,
                  record.lastSyncedAt != nil,
                  let updated = Self.applying(writes, to: data),
                  updated != data
            else { return }
            record.stateData = updated
            try save()
            let stale: Bool
            if case .success(_, let current) = status {
                stale = current
            } else {
                stale = record.invalidated
            }
            status = .success(updated, stale: stale)
            await publish()
        } catch {
            rollback()
        }
    }

    /// Starts the stream if the key has one and none is running.
    private func ensureSubscribed() {
        guard streamTask == nil else { return }
        let storedData = (try? record().stateData).flatMap { Self.isDecodable($0) ? $0 : nil }
        guard let task = Self.runSubscribe(
            fetcher: fetcher,
            stateData: storedData,
            modelContainer: modelContainer,
            fetchContext: fetchContext,
            writer: writer
        ) else { return }
        subscriptions += 1
        streamID &+= 1
        let id = streamID
        streamTask = task
        // Forget the stream once it ends on its own, so the next sync from a view restarts it.
        // Weak, so a running stream doesn't keep this actor (which cancels it on deinit) alive.
        Task { [weak self] in
            await task.value
            await self?.streamEnded(id)
        }
    }

    private func streamEnded(_ id: UInt64) {
        if streamID == id {
            streamTask = nil
        }
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
    }

    /// Returns the stored state and whether it is stale, or `nil` when there is no usable state.
    /// State that no longer decodes, for example after `State` changed in an app update,
    /// counts as missing so the next sync fetches from the default state.
    private func freshness(of record: QueryRecord, cache: QueryCache, now: Date) -> (Data, Bool)? {
        guard let data = record.stateData,
              let lastSyncedAt = record.lastSyncedAt,
              Self.isDecodable(data)
        else { return nil }
        let stale = record.invalidated || cache.isStale(lastSyncedAt: lastSyncedAt, now: now)
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
        cancelStream()
        clear(record)
        try save()
        status = .pending
        lastError = nil

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        try fetcher.evict(context: context)
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
        let cacheTime = cache.cacheTime.map { $0 / .seconds(1) }
        if record.cacheTime != cacheTime {
            record.cacheTime = cacheTime
        }
    }

    /// Records a use of the cache, unless one was recorded within ``accessResolution``.
    private static func touch(_ record: QueryRecord, now: Date) {
        if let last = record.lastAccessedAt, now.timeIntervalSince(last) < accessResolution {
            return
        }
        record.lastAccessedAt = now
    }

    /// Decodes `data`, applies `writes` in order, and re-encodes. `nil` if it doesn't decode.
    private static func applying(_ writes: [Write], to data: Data) -> Data? {
        guard !writes.isEmpty else { return data }
        guard var state = try? JSONDecoder().decode(Fetcher.State.self, from: data) else {
            return nil
        }
        for write in writes {
            write(&state)
        }
        return try? JSONEncoder().encode(state)
    }

    private static func isDecodable(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Fetcher.State.self, from: data)) != nil
    }

    private static func decodedState(_ data: Data?) -> Fetcher.State? {
        data.flatMap { try? JSONDecoder().decode(Fetcher.State.self, from: $0) }
    }

    /// Runs the fetch outside actor isolation with a fresh context.
    /// Only `Sendable` values cross into and out of it.
    private static func runFetch(
        fetcher: Fetcher,
        stateData: Data?,
        modelContainer: ModelContainer,
        fetchContext: Fetcher.Context
    ) async throws -> Data {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let state = try await fetcher.fetch(
            context: context,
            fetchContext: fetchContext,
            state: decodedState(stateData)
        )
        if context.hasChanges {
            try context.save()
        }
        return try JSONEncoder().encode(state)
    }

    private static func runSubscribe(
        fetcher: Fetcher,
        stateData: Data?,
        modelContainer: ModelContainer,
        fetchContext: Fetcher.Context,
        writer: StateWriter<Fetcher.State>
    ) -> Task<Void, Never>? {
        fetcher.subscribe(
            container: modelContainer,
            fetchContext: fetchContext,
            state: decodedState(stateData),
            writer: writer
        )
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
        if let keep = records.first {
            if records.count > 1 {
                for extra in records.dropFirst() {
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
