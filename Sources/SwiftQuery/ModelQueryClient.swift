import Foundation
import Observation
import SwiftData

/// Reverts an optimistic update. Captures whatever previous values it needs.
public typealias MutationRollback = @MainActor (ModelContext) throws -> Void

/// The observable, main-actor interface to one key's synchronization: a model collection or a
/// ``QueryFetcher`` value.
///
/// A ``QueryProvider`` creates one shared client per key, lazily. Views obtain it with
/// ``QueryClient`` and read rows with SwiftData's `@Query`; a fetcher's own data is read from
/// ``data``.
@Observable
@MainActor
public final class ModelQueryClient<Fetcher: QueryFetcher> {
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
    @ObservationIgnored private let scheduler: MutationScheduler
    /// Bookkeeping for this client's unscoped mutations, which run in parallel.
    @ObservationIgnored private let unscoped = MutationGroup()
    @ObservationIgnored private var observerCount = 0
    @ObservationIgnored private var mutationCount = 0
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
        scheduler: MutationScheduler = MutationScheduler(),
        onEvict: @escaping QueryActor<Fetcher>.EvictHandler = { _, _ in }
    ) {
        let sink = SnapshotSink<Fetcher>()
        self.fetcher = fetcher
        self.recordKey = recordKey
        self.modelContainer = modelContainer
        self.scheduler = scheduler
        self.actor = QueryActor(
            fetcher: fetcher,
            key: recordKey,
            modelContainer: modelContainer,
            fetchContext: fetchContext,
            publisher: { snapshot in await sink.receive(snapshot) },
            onEvict: onEvict
        )
        sink.client = self
        loadInitialState()
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

    /// Runs a remote mutation, optionally applying an optimistic update first.
    ///
    /// - The optimistic update applies immediately, on the main context, which is then saved so a
    ///   later refetch can't be overwritten by an unsaved edit. Rollbacks are saved the same way.
    ///   If that save fails, the update's rollback runs and the error is rethrown before anything
    ///   is sent. With `autosaveEnabled` off, nothing is saved for you: save in your closures.
    /// - The remote call runs in its own task, so cancelling the caller doesn't cancel a call that
    ///   was already sent; the caller still gets its result. A caller cancelled before its call is
    ///   sent rolls back and throws `CancellationError`.
    /// - On success, optimistic changes are kept and the client awaits a fetch that starts after
    ///   the mutation, so a fetch already in flight (possibly sent before the mutation reached the
    ///   server) can't leave stale data behind. A failed refresh does not roll back or throw; it is
    ///   reported through ``state`` and ``error``.
    /// - On failure, the returned rollback runs and the mutation error is rethrown. If a newer
    ///   optimistic mutation has started since, the rollback is skipped so it cannot clobber the
    ///   newer change, and the client refetches once no mutations are pending.
    ///
    /// Mutation failures never change ``state`` to `.error`.
    ///
    /// A refetch writes the server's current data straight to SwiftData. If it runs while another
    /// mutation's remote call is still in flight, that mutation's optimistic edit can briefly show
    /// the server's older value until its own refetch. Put related mutations in one scope to avoid
    /// this.
    ///
    /// ### Scopes
    ///
    /// Mutations with the same `scope` send their remote calls one at a time, in call order, even
    /// across models registered with the same ``QueryProvider``. Mutations without a scope run in
    /// parallel. A per-record scope such as `"user-\(id)"` is typical. Always use the same scope (or
    /// always none) for a given record: rollbacks are only skipped in favor of newer optimistic
    /// mutations in the same scope.
    ///
    /// Within a scope, optimistic updates still apply immediately, a failure doesn't cancel later
    /// mutations, and each error goes only to its own caller. The refetch runs once the scope has
    /// nothing left queued, for every model a mutation in it touched, and only the caller of the
    /// last mutation awaits it. A caller cancelled while queued stops waiting right away, rolls back,
    /// and throws `CancellationError` without sending its remote call; later mutations keep their
    /// order.
    @discardableResult
    public func mutate<Result>(
        scope: (any Hashable & Sendable)? = nil,
        _ mutation: @escaping @Sendable () async throws -> sending Result,
        optimistic: (@MainActor (ModelContext) throws -> MutationRollback?)? = nil
    ) async throws -> Result {
        mutationCount += 1
        activityChanged()
        defer {
            mutationCount -= 1
            activityChanged()
        }
        let scopeKey = scope.map { AnyHashable($0) }
        let group = scopeKey.map { scheduler.group(for: $0) } ?? unscoped
        let context = modelContainer.mainContext

        var rollback: MutationRollback?
        var optimisticID: UInt64?
        if let optimistic {
            do {
                rollback = try Self.applyOptimistic(optimistic, in: context)
            } catch {
                if let scopeKey { scheduler.release(scopeKey, group) }
                throw error
            }
            group.latestOptimistic &+= 1
            optimisticID = group.latestOptimistic
        }
        group.pending += 1

        // Scoped: wait for the previous mutation's remote call, and let the next one wait for ours.
        var previous: Task<Void, Never>?
        var gate: MutationGate?
        if scopeKey != nil {
            let ownGate = MutationGate()
            previous = group.tail
            let waitFor = previous
            group.tail = Task {
                await waitFor?.value
                await ownGate.wait()
            }
            gate = ownGate
        }
        await Self.waitForTurn(after: previous)

        let result: Result
        do {
            try Task.checkCancellation()
            result = try await Self.send(mutation)
        } catch {
            gate?.open()
            group.pending -= 1
            if let rollback {
                if optimisticID == group.latestOptimistic {
                    do {
                        try rollback(context)
                        try Self.saveIfNeeded(context)
                    } catch {
                        group.refetches[ObjectIdentifier(self)] = refetchHandler
                    }
                } else {
                    group.refetches[ObjectIdentifier(self)] = refetchHandler
                }
            }
            await drain(group, scope: scopeKey)
            throw error
        }
        gate?.open()
        group.pending -= 1

        if scopeKey == nil {
            // Unscoped: always reconcile right away, covering any skipped rollbacks too.
            group.refetches[ObjectIdentifier(self)] = nil
            await refetch()
        } else {
            group.refetches[ObjectIdentifier(self)] = refetchHandler
            await drain(group, scope: scopeKey)
        }
        return result
    }

    /// Runs the group's refetches once nothing is pending, and forgets a drained scope.
    private func drain(_ group: MutationGroup, scope: AnyHashable?) async {
        guard group.pending == 0 else { return }
        let refetches = Array(group.refetches.values)
        group.refetches = [:]
        if let scope {
            scheduler.release(scope, group)
        }
        await withTaskGroup(of: Void.self) { tasks in
            for refetch in refetches {
                tasks.addTask { await refetch() }
            }
        }
    }

    /// Runs the remote call in its own task, so it outlives a cancelled caller.
    private static func send<Value>(
        _ mutation: @escaping @Sendable () async throws -> sending Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    continuation.resume(returning: try await mutation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Waits for the previous mutation in a scope, returning early if the caller is cancelled.
    /// Leaving early never reorders the queue: the next mutation still waits for `previous`.
    private static func waitForTurn(after previous: Task<Void, Never>?) async {
        guard let previous else { return }
        let turn = MutationGate()
        Task {
            await previous.value
            turn.open()
        }
        await withTaskCancellationHandler {
            await turn.wait()
        } onCancel: {
            Task { @MainActor in turn.open() }
        }
    }

    /// Applies an optimistic update and saves it. If the save fails, the update's own rollback
    /// runs before the error is rethrown, so a mutation that never ran leaves nothing behind.
    static func applyOptimistic(
        _ optimistic: @MainActor (ModelContext) throws -> MutationRollback?,
        in context: ModelContext,
        save: @MainActor (ModelContext) throws -> Void = saveIfNeeded
    ) throws -> MutationRollback? {
        let rollback = try optimistic(context)
        do {
            try save(context)
        } catch {
            if let rollback {
                try? rollback(context)
                try? save(context)
            }
            throw error
        }
        return rollback
    }

    /// Saves the main context after an optimistic update or rollback, but only when it autosaves.
    /// Saving commits every pending change in the shared context, so an app that turned autosave
    /// off (to hold drafts, for example) keeps control and its closures must save themselves.
    static func saveIfNeeded(_ context: ModelContext) throws {
        if context.autosaveEnabled, context.hasChanges {
            try context.save()
        }
    }

    private var refetchHandler: @MainActor () async -> Void {
        { [weak self] in await self?.refetch() }
    }

    // MARK: Internal

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

    func remove() async {
        await tail?.value
        await actor.remove()
    }

    func reset() async {
        await tail?.value
        await actor.reset()
    }

    func isSubscribed() async -> Bool {
        await actor.isSubscribed
    }

    func subscriptions() async -> Int {
        await actor.subscriptions
    }

    private func refetch() async {
        await tail?.value
        await actor.refetch()
    }

    func collectGarbage() async {
        await tail?.value
        await actor.collectGarbage()
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
    private func loadInitialState() {
        guard fetcher.cache != nil,
              let (value, data, stale) = Self.storedState(fetcher, key: recordKey, in: modelContainer.mainContext)
        else { return }
        stateData = data
        state = .success(data: value, stale: stale)
    }

    /// Decodes a key's stored state, if it has usable state.
    static func storedState(
        _ fetcher: Fetcher,
        key: String,
        in context: ModelContext
    ) -> (Fetcher.QueryData, Data, stale: Bool)? {
        guard let record = try? context.fetch(QueryRecord.descriptor(key: key, limit: 1)).first,
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
    weak var client: ModelQueryClient<Fetcher>?

    func receive(_ snapshot: QuerySnapshot) {
        client?.receive(snapshot)
    }
}

@MainActor
protocol AnyModelQueryClient: AnyObject {
    var recordKey: String { get }
    var tagSet: Set<String> { get }
    var isActive: Bool { get }
    var isObserved: Bool { get }
    var isModel: Bool { get }
    var idleGeneration: UInt64 { get set }
    func collectGarbage() async
    func invalidate()
    func resync()
    func refresh() async
    func cancel()
    func unsubscribe()
    func remove() async
    func reset() async
}

extension ModelQueryClient: AnyModelQueryClient {
    var tagSet: Set<String> { fetcher.tags }
    var isModel: Bool { Fetcher.self is any ModelFetcherKind.Type }
}
