import Foundation
import Observation
import SwiftData

/// Reverts an optimistic update. Captures whatever previous values it needs.
public typealias Rollback = @MainActor (ModelContext) throws -> Void

/// The observable, main-actor interface to one model's synchronization.
///
/// A ``QueryProvider`` owns one shared client per registered model type. Views obtain it
/// with ``QueryClient`` and read application data with SwiftData's `@Query`.
@Observable
@MainActor
public final class ModelQueryClient<Model: SyncedModel> {
    /// The synchronization state, carrying the persisted ``SyncedModel/SyncState``.
    public private(set) var state: QueryState<Model.SyncState> = .pending
    /// The current fetch activity.
    public private(set) var fetchState: QueryFetchState = .idle
    /// The error of the last failed fetch, cleared by the next successful fetch.
    ///
    /// When a refresh fails after a previous success, ``state`` stays a stale
    /// `success` and the failure is reported here.
    public private(set) var error: (any Error)?

    /// The container whose main context is used for optimistic updates.
    public let modelContainer: ModelContainer

    @ObservationIgnored private let actor: ModelQueryActor<Model>
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var lastSequence: UInt64 = 0
    @ObservationIgnored private var stateData: Data?
    @ObservationIgnored private let scheduler: MutationScheduler
    /// Bookkeeping for this client's unscoped mutations, which run in parallel.
    @ObservationIgnored private let unscoped = MutationGroup()

    /// Created only by ``QueryProvider``, so each model has a single client and actor.
    init(
        modelContainer: ModelContainer,
        syncContext: Model.SyncContext,
        scheduler: MutationScheduler = MutationScheduler()
    ) {
        let sink = SnapshotSink<Model>()
        self.modelContainer = modelContainer
        self.scheduler = scheduler
        self.actor = ModelQueryActor(
            modelContainer: modelContainer,
            syncContext: syncContext,
            publisher: { snapshot in await sink.receive(snapshot) }
        )
        sink.client = self
        loadInitialState()
    }

    // MARK: Synchronization

    /// Schedules a freshness check using the model's default cache policy,
    /// fetching if the data is stale, invalidated, or missing.
    public func sync() {
        sync(Model.cache)
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

    /// Cancels the stream task returned by ``SyncedModel/fetch(context:syncContext:syncState:writer:)``, if any.
    public func cancelStream() {
        enqueue { await $0.cancelStream() }
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
        optimistic: (@MainActor (ModelContext) throws -> Rollback?)? = nil
    ) async throws -> Result {
        let scopeKey = scope.map { AnyHashable($0) }
        let group = scopeKey.map { scheduler.group(for: $0) } ?? unscoped
        let context = modelContainer.mainContext

        var rollback: Rollback?
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
        var gate: Gate?
        if scopeKey != nil {
            let ownGate = Gate()
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
        let turn = Gate()
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
        _ optimistic: @MainActor (ModelContext) throws -> Rollback?,
        in context: ModelContext,
        save: @MainActor (ModelContext) throws -> Void = saveIfNeeded
    ) throws -> Rollback? {
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
        enqueue { await $0.attach(cache ?? Model.cache) }
    }

    func detach() {
        enqueue { await $0.detach() }
    }

    /// Stops the client after its model is unregistered.
    func retire() {
        enqueue { await $0.retire() }
    }

    private func refetch() async {
        await tail?.value
        await actor.refetch()
    }

    func collectGarbage() async {
        await tail?.value
        await actor.collectGarbage(Model.cache)
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
            guard data != stateData || stale != state.isStale || state.value == nil else { break }
            if let value = try? JSONDecoder().decode(Model.SyncState.self, from: data) {
                stateData = data
                state = .success(value: value, stale: stale)
            } else {
                stateData = nil
                state = .pending
            }
        case .error(let error):
            stateData = nil
            state = .error(error)
        }
        if fetchState != snapshot.fetchState {
            fetchState = snapshot.fetchState
        }
        if snapshot.error != nil || error != nil {
            error = snapshot.error
        }
    }

    /// Runs operations in call order. Operations only check state and start fetches,
    /// so they never wait behind a running fetch.
    private func enqueue(_ operation: @escaping @Sendable (ModelQueryActor<Model>) async -> Void) {
        let previous = tail
        let actor = actor
        tail = Task {
            await previous?.value
            await operation(actor)
        }
    }

    /// Reads persisted metadata synchronously so views don't flash `.pending` on launch.
    private func loadInitialState() {
        guard let record = try? modelContainer.mainContext.fetch(QueryRecord.descriptor(key: Model.queryKey, limit: 1)).first,
              let data = record.stateData,
              let lastSyncedAt = record.lastSyncedAt,
              let value = try? JSONDecoder().decode(Model.SyncState.self, from: data)
        else { return }
        let stale = record.invalidated || Model.cache.isStale(lastSyncedAt: lastSyncedAt, now: .now)
        stateData = data
        state = .success(value: value, stale: stale)
    }
}

/// Delivers snapshots to a client without the actor retaining it.
@MainActor
private final class SnapshotSink<Model: SyncedModel> {
    weak var client: ModelQueryClient<Model>?

    func receive(_ snapshot: QuerySnapshot) {
        client?.receive(snapshot)
    }
}

protocol AnyModelQueryClient: AnyObject {
    @MainActor func collectGarbage() async
    @MainActor func retire()
}

extension ModelQueryClient: AnyModelQueryClient {}
