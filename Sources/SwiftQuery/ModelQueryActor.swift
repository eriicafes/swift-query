import Foundation
import SwiftData

/// An ordered state update delivered from a ``ModelQueryActor`` to its client.
struct QuerySnapshot: Sendable {
    enum Status: Sendable {
        case pending
        case success(Data, stale: Bool)
        case error(any Error)
    }

    var sequence: UInt64
    var status: Status
    var fetchState: QueryFetchState
    var error: (any Error)?
}

/// Serializes synchronization for one model type.
///
/// The actor runs on the global concurrent executor, not on SwiftData's default model executor,
/// which runs on the main thread. Its own `ModelContext` is created lazily on the actor and used
/// only for ``QueryRecord`` bookkeeping. Each fetch gets a separate fresh `ModelContext`, so a
/// failed or in-progress fetch never leaks partial changes into bookkeeping saves.
actor ModelQueryActor<Model: SyncedModel> {
    typealias Publisher = @Sendable (QuerySnapshot) async -> Void
    typealias Write = @Sendable (inout Model.SyncState) -> Void

    nonisolated let modelContainer: ModelContainer
    private let syncContext: Model.SyncContext
    private let publisher: Publisher
    private let key = Model.queryKey
    private var context: ModelContext?

    private var loaded = false
    private var retired = false
    private var status: QuerySnapshot.Status = .pending
    private var fetchState: QueryFetchState = .idle
    private var lastError: (any Error)?
    private var sequence: UInt64 = 0

    private var inFlight: (id: UInt64, task: Task<Void, Never>)?
    /// The most recent fetch, kept after it leaves `inFlight` so waiters see its final publish.
    private var lastFetch: Task<Void, Never>?
    private var nextFetchID: UInt64 = 0
    /// How many fetch requests joined an in-flight fetch instead of starting one.
    private(set) var fetchJoins = 0
    private var invalidations: UInt64 = 0
    private var streamTask: Task<Void, Never>?
    private var observers = 0
    /// The cache policy of the most recent sync, used by garbage collection so per-view
    /// overrides such as `.swr(cacheTime:)` are honored.
    private var lastCache: QueryCache?
    /// How stale `lastAccessedAt` may get before a sync or detach writes it again. Keeps views
    /// that appear often (list rows) from saving on every appearance. Expiry can therefore come
    /// up to this much early, which is negligible next to cache times measured in minutes.
    static var accessResolution: TimeInterval { 60 }
    /// Stream writes received while a fetch is in flight, applied after it finishes.
    private var pendingWrites: [Write] = []
    /// Most writes kept behind one fetch. Beyond this they are saved to the stored state right
    /// away, so a fetch that never finishes can't grow the queue without bound.
    static var pendingWriteLimit: Int { 1_000 }
    private var writerTarget: WriterTarget<Model>?

    init(
        modelContainer: ModelContainer,
        syncContext: Model.SyncContext,
        publisher: @escaping Publisher
    ) {
        self.modelContainer = modelContainer
        self.syncContext = syncContext
        self.publisher = publisher
    }

    deinit {
        streamTask?.cancel()
    }

    /// The bookkeeping context, created on first use so it belongs to this actor.
    private var modelContext: ModelContext {
        if let context { return context }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.context = context
        return context
    }

    /// The writer handed to every fetch. It holds this actor weakly.
    private var writer: SyncStateWriter<Model> {
        if let writerTarget { return SyncStateWriter(target: writerTarget) }
        let target = WriterTarget(self)
        writerTarget = target
        return SyncStateWriter(target: target)
    }

    // MARK: Operations

    /// Starts observing the query. Expiry is only checked when the query was unobserved.
    func attach(_ cache: QueryCache) async {
        guard !retired else { return }
        let wasUnobserved = observers == 0
        observers += 1
        await sync(cache, checkExpiry: wasUnobserved)
    }

    /// Stops observing the query and records the last use.
    func detach() {
        guard !retired else { return }
        observers = max(0, observers - 1)
        do {
            let record = try record()
            Self.touch(record, now: .now)
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
        }
    }

    /// Checks freshness against `cache` and starts a deduplicated fetch when required.
    /// Returns once the fetch has started, not when it finishes.
    func sync(_ cache: QueryCache) async {
        guard !retired else { return }
        await sync(cache, checkExpiry: observers == 0)
    }

    /// Fetches regardless of freshness, joining an in-flight fetch if there is one.
    func refresh() async {
        guard !retired else { return }
        loadIfNeeded()
        await startFetch().value
    }

    /// Fetches with a request that starts after this call.
    ///
    /// An in-flight fetch may have been sent before a mutation reached the server, so it is
    /// awaited and then followed by a new fetch. A fetch that started after this call is joined.
    func refetch() async {
        guard !retired else { return }
        loadIfNeeded()
        if let current = inFlight {
            await current.task.value
            if let next = inFlight, next.id > current.id {
                await next.task.value
                return
            }
        }
        guard !retired else { return }
        await startFetch().value
    }

    /// Marks the persisted record as invalidated without fetching.
    func invalidate() async {
        guard !retired else { return }
        loadIfNeeded()
        invalidations &+= 1
        do {
            let record = try record()
            record.invalidated = true
            try modelContext.save()
        } catch {
            modelContext.rollback()
        }
        if case .success(let data, false) = status {
            status = .success(data, stale: true)
            await publish()
        }
    }

    /// Evicts the cache if it expired under `cache` while unobserved and idle.
    /// Evicts the cache if it expired while unobserved and idle, under the cache policy of the
    /// most recent sync, or `defaultCache` if there hasn't been one.
    func collectGarbage(_ defaultCache: QueryCache) async {
        guard !retired else { return }
        loadIfNeeded()
        guard observers == 0, inFlight == nil else { return }
        do {
            if try evictIfExpired(try record(), cache: lastCache ?? defaultCache, now: .now) {
                await publish()
            }
        } catch {
            modelContext.rollback()
        }
    }

    /// Cancels the managed stream task.
    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Stops all work for an unregistered model: cancels the stream and any in-flight fetch,
    /// and ignores every later operation.
    func retire() {
        retired = true
        pendingWrites.removeAll()
        cancelStream()
        inFlight?.task.cancel()
    }

    /// Applies a stream write now, or queues it behind the in-flight fetch.
    func write(_ body: @escaping Write) async {
        guard !retired else { return }
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

    // MARK: Sync

    private func sync(_ cache: QueryCache, checkExpiry: Bool) async {
        loadIfNeeded()
        lastCache = cache
        let now = Date.now
        let needsFetch: Bool
        do {
            let record = try record()
            // Never evict while a fetch is writing the same records.
            if checkExpiry, inFlight == nil {
                _ = try evictIfExpired(record, cache: cache, now: now)
            }
            Self.touch(record, now: now)
            if modelContext.hasChanges {
                try modelContext.save()
            }
            if let (data, stale) = freshness(of: record, cache: cache, now: now) {
                status = .success(data, stale: stale)
                needsFetch = stale
            } else {
                needsFetch = true
            }
        } catch {
            modelContext.rollback()
            fail(error)
            await publish()
            return
        }
        if needsFetch {
            startFetch()
        }
        await publish()
    }

    @discardableResult
    private func startFetch() -> Task<Void, Never> {
        if let inFlight {
            fetchJoins += 1
            return inFlight.task
        }
        nextFetchID &+= 1
        let id = nextFetchID
        // Registered before any suspension; the task body runs only after this method returns.
        let task = Task { await self.performFetch(id: id) }
        inFlight = (id, task)
        lastFetch = task
        return task
    }

    private func performFetch(id: UInt64) async {
        let generation = invalidations
        let storedData = (try? record().stateData).flatMap { Self.isDecodable($0) ? $0 : nil }
        fetchState = storedData == nil ? .loading : .fetching
        await publish()

        do {
            try Task.checkCancellation()
            let (fetchedData, stream) = try await Self.runFetch(
                stateData: storedData,
                modelContainer: modelContainer,
                syncContext: syncContext,
                writer: writer
            )
            if retired {
                stream?.cancel()
                throw CancellationError()
            }
            if let stream, stream != streamTask {
                streamTask?.cancel()
                streamTask = stream
            }
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
                try modelContext.save()
                status = .success(data, stale: record.invalidated)
                lastError = nil
            } catch {
                pendingWrites = applied + pendingWrites
                throw error
            }
        } catch is CancellationError {
            // A cancelled fetch is not a failure; keep the previous state.
            modelContext.rollback()
        } catch {
            modelContext.rollback()
            fail(error)
        }

        // Only the owner of the in-flight fetch clears it. Writes still queued (after a failed
        // fetch) apply to the stored state; later writes no longer queue.
        var leftover: [Write] = []
        if inFlight?.id == id {
            inFlight = nil
            fetchState = .idle
            leftover = pendingWrites
            pendingWrites = []
        }
        await persist(leftover)
        await publish()
    }

    /// Applies writes to the stored state and saves it. Dropped when nothing has synced yet.
    private func persist(_ writes: [Write]) async {
        guard !writes.isEmpty, !retired else { return }
        do {
            let record = try record()
            guard let data = record.stateData,
                  record.lastSyncedAt != nil,
                  let updated = Self.applying(writes, to: data),
                  updated != data
            else { return }
            record.stateData = updated
            try modelContext.save()
            let stale: Bool
            if case .success(_, let current) = status {
                stale = current
            } else {
                stale = record.invalidated
            }
            status = .success(updated, stale: stale)
            await publish()
        } catch {
            modelContext.rollback()
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
              let (data, stale) = freshness(of: record, cache: Model.cache, now: .now)
        else { return }
        status = .success(data, stale: stale)
    }

    /// Returns the stored state and whether it is stale, or `nil` when there is no usable state.
    /// State that no longer decodes, for example after `SyncState` changed in an app update,
    /// counts as missing so the next sync fetches from ``SyncedModel/defaultState``.
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

        cancelStream()
        // Clear the metadata first: if evicting the data then fails, the data stays and the
        // next sync refetches it, instead of empty data being treated as fresh.
        record.stateData = nil
        record.lastSyncedAt = nil
        record.invalidated = false
        try modelContext.save()
        status = .pending
        lastError = nil

        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        try Model.evict(context: context)
        try context.save()
        return true
    }

    /// Decodes `data`, applies `writes` in order, and re-encodes. `nil` if it doesn't decode.
    private static func applying(_ writes: [Write], to data: Data) -> Data? {
        guard !writes.isEmpty else { return data }
        guard var state = try? JSONDecoder().decode(Model.SyncState.self, from: data) else {
            return nil
        }
        for write in writes {
            write(&state)
        }
        return try? JSONEncoder().encode(state)
    }

    private static func isDecodable(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Model.SyncState.self, from: data)) != nil
    }

    /// Runs `Model.fetch` outside actor isolation with a fresh context.
    /// Only `Sendable` values cross into and out of it.
    private static func runFetch(
        stateData: Data?,
        modelContainer: ModelContainer,
        syncContext: Model.SyncContext,
        writer: SyncStateWriter<Model>
    ) async throws -> (Data, Task<Void, Never>?) {
        var syncState = Model.defaultState
        if let stateData, let decoded = try? JSONDecoder().decode(Model.SyncState.self, from: stateData) {
            syncState = decoded
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let stream = try await Model.fetch(
            context: context,
            syncContext: syncContext,
            syncState: &syncState,
            writer: writer
        )
        do {
            if context.hasChanges {
                try context.save()
            }
            return (try JSONEncoder().encode(syncState), stream)
        } catch {
            stream?.cancel()
            throw error
        }
    }

    /// Records a use of the cache, unless one was recorded within ``accessResolution``.
    private static func touch(_ record: QueryRecord, now: Date) {
        if let last = record.lastAccessedAt, now.timeIntervalSince(last) < accessResolution {
            return
        }
        record.lastAccessedAt = now
    }

    /// The record for this model. Without a unique constraint (which CloudKit forbids),
    /// duplicates can appear, so extras are removed and the most recently synced one kept.
    private func record() throws -> QueryRecord {
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
                fetchState: fetchState,
                error: lastError
            )
        )
    }
}
