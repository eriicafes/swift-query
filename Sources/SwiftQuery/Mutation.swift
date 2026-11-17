import Foundation
import SwiftData

/// Reverts an optimistic update to rows. Captures whatever previous values it needs.
public typealias MutationRollback = @MainActor (ModelContext) throws -> Void

/// An optimistic update: edits rows and query data before a mutation's remote call is sent.
public typealias OptimisticUpdate = @MainActor (OptimisticContext) throws -> Void

/// What an optimistic update receives: the main context for editing rows, a way to register
/// their rollback, and a way to update a key's query data.
///
/// ```swift
/// optimistic: { tx in
///     guard let user = try tx.modelContext.fetch(descriptor).first else { return }
///     user.following = true
///     tx.onRollback { _ in user.following = false }
///     tx.setQueryData(for: UserStats(id: id)) { $0.followers += 1 }
/// }
/// ```
@MainActor
public struct OptimisticContext {
    /// The container's main context. Edit rows here and register a rollback with
    /// ``onRollback(_:)`` that restores them.
    public let modelContext: ModelContext
    let provider: QueryProvider
    let recorder: OptimisticRecorder

    /// Registers a closure that restores rows edited in ``modelContext`` if the mutation fails.
    ///
    /// Rollbacks run in reverse order of registration, on the main context, which is then saved
    /// as with the optimistic update. They also run if the optimistic update itself throws.
    /// Query data changed with ``setQueryData(for:_:)-(F,_)`` needs no rollback.
    public func onRollback(_ rollback: @escaping MutationRollback) {
        recorder.rowRollbacks.append(rollback)
    }

    /// Updates a key's query data right away.
    ///
    /// The key's in-flight fetch is cancelled first, so an older response can't overwrite the
    /// edit; a ``QueryProvider/query(_:staleTime:)-(F,_)`` waiting on that fetch returns the
    /// optimistic data. Does nothing if the key has no data yet. If the mutation fails, the
    /// previous data is restored, unless the key has changed since, such as by a fetch or a newer
    /// optimistic update. Either way the key is invalidated when the mutation settles.
    public func setQueryData<F: QueryFetcher>(
        for fetcher: F,
        _ update: @escaping @Sendable (inout F.QueryData) -> Void
    ) {
        let client = provider.client(for: fetcher)
        guard let rollback = client.applyOptimistic(update) else { return }
        recorder.dataRollbacks.append(rollback)
        recorder.filters.append(.key(client))
    }

    /// ``setQueryData(for:_:)-(F,_)`` for a model collection.
    public func setQueryData<M: QueryModel>(
        for model: M.Type,
        _ update: @escaping @Sendable (inout M.QueryData) -> Void
    ) {
        setQueryData(for: ModelFetcher<M>(), update)
    }
}

/// Collects the rollbacks and query data changes an optimistic update makes.
@MainActor
final class OptimisticRecorder {
    /// Row rollbacks registered with ``OptimisticContext/onRollback(_:)``.
    var rowRollbacks: [MutationRollback] = []
    /// Restores query data changed with ``OptimisticContext/setQueryData(for:_:)-(F,_)``.
    var dataRollbacks: [@MainActor () async -> Void] = []
    var filters: [QueryFilter] = []

    /// The row rollbacks combined, newest first, or `nil` if none were registered.
    var rowRollback: MutationRollback? {
        guard !rowRollbacks.isEmpty else { return nil }
        let rollbacks = Array(rowRollbacks.reversed())
        return { context in
            for rollback in rollbacks {
                try rollback(context)
            }
        }
    }
}

/// An optimistic mutation the provider remembers while an older one could still fail, so that
/// one can tell whether rolling back would clobber this newer edit.
struct OptimisticEntry {
    let id: UInt64
    let scope: AnyHashable?
    let filters: [QueryFilter]
    /// The mutation while it runs, so an older one can hand it a rollback.
    weak var run: MutationRun?
    /// Whether its remote call succeeded, or `nil` until it's decided.
    var succeeded: Bool?

    /// Whether this mutation may have edited what a mutation with `scope` and `filters` edited:
    /// it shares the scope, or their filters overlap. Mutations without filters overlap nothing
    /// by filters, since nothing would refetch to repair a skipped rollback.
    func overlaps(scope: AnyHashable?, filters: [QueryFilter]) -> Bool {
        if let scope, scope == self.scope { return true }
        return self.filters.contains { mine in filters.contains { mine.overlaps($0) } }
    }
}

/// Shared bookkeeping for a set of mutations: how many are pending, and which keys to
/// invalidate once none are pending.
///
/// Scoped mutations use one group per scope, shared across the provider, and their remote calls
/// run one at a time. Each unscoped mutation gets a group of its own and runs in parallel.
@MainActor
final class MutationGroup {
    /// Completes when the last queued mutation's remote call has finished. Scoped groups only.
    var tail: Task<Void, Never>?
    var pending = 0
    /// Keys to invalidate when the scope drains. Scoped groups only.
    var filters: Set<QueryFilter> = []
    /// Whether a mutation in the scope skipped its rollback, so its keys must refetch even where
    /// no view shows them. Scoped groups only.
    var skippedRollback = false
    /// Pending markers of the scope's optimistic mutations, deleted when the scope drains.
    var markers: [String] = []
}

/// Orders scoped mutations. Owned by ``QueryProvider``, so a scope spans every client.
@MainActor
final class MutationScheduler {
    private(set) var groups: [AnyHashable: MutationGroup] = [:]

    func group(for scope: AnyHashable) -> MutationGroup {
        if let group = groups[scope] { return group }
        let group = MutationGroup()
        groups[scope] = group
        return group
    }

    /// Forgets a drained scope so idle scopes don't accumulate.
    func release(_ scope: AnyHashable, _ group: MutationGroup) {
        if group.pending == 0, groups[scope] === group {
            groups[scope] = nil
        }
    }
}

/// A one-shot signal for scoped mutations: a queued mutation waits on the previous one's gate,
/// which opens when that mutation's remote call finishes.
@MainActor
final class MutationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }
}

/// A mutation whose optimistic update has been applied and whose place in its scope is taken,
/// waiting to send its remote call.
@MainActor
final class MutationRun {
    /// Increases with each mutation the provider begins; orders optimistic updates.
    let id: UInt64
    let group: MutationGroup
    let scope: AnyHashable?
    let filters: [QueryFilter]
    let rollback: MutationRollback?
    let dataRollbacks: [@MainActor () async -> Void]
    let isOptimistic: Bool
    let previous: Task<Void, Never>?
    let gate: MutationGate?
    /// The key of the record marking this mutation as pending, if it has an optimistic update.
    let marker: String?
    /// Rollbacks of older failed mutations that this one's edit covered, by mutation id. They run
    /// after this mutation's own if it fails too, and are dropped if it succeeds.
    var inheritedRollbacks: [(id: UInt64, rollback: MutationRollback)] = []

    init(
        id: UInt64,
        group: MutationGroup,
        scope: AnyHashable?,
        filters: [QueryFilter],
        rollback: MutationRollback?,
        dataRollbacks: [@MainActor () async -> Void],
        isOptimistic: Bool,
        previous: Task<Void, Never>?,
        gate: MutationGate?,
        marker: String?
    ) {
        self.id = id
        self.group = group
        self.scope = scope
        self.filters = filters
        self.rollback = rollback
        self.dataRollbacks = dataRollbacks
        self.isOptimistic = isOptimistic
        self.previous = previous
        self.gate = gate
        self.marker = marker
    }
}

extension QueryProvider {
    // MARK: Mutation engine

    /// Applies the optimistic update and takes the mutation's place in its scope, synchronously,
    /// so mutations started in a row keep their order and their edits show at once.
    func beginMutation(
        scope: (any Hashable & Sendable)?,
        invalidates: [QueryFilter],
        optimistic: OptimisticUpdate?
    ) throws -> MutationRun {
        let scopeKey = scope.map { AnyHashable($0) }
        let group = scopeKey.map { mutations.group(for: $0) } ?? MutationGroup()
        var filters = invalidates
        var rollback: MutationRollback?
        var dataRollbacks: [@MainActor () async -> Void] = []

        var marker: String?
        if let optimistic {
            let recorder = OptimisticRecorder()
            var marked = false
            do {
                rollback = try Self.applyOptimistic({ context in
                    do {
                        try optimistic(OptimisticContext(modelContext: context, provider: self, recorder: recorder))
                    } catch {
                        // Undo whatever the update edited before it threw.
                        try? recorder.rowRollback?(context)
                        throw error
                    }
                    return recorder.rowRollback
                }, in: modelContainer.mainContext, save: { context in
                    // Mark the mutation before its optimistic changes are saved, so an app
                    // terminated before it settles refetches its keys at the next launch.
                    if !marked {
                        marked = true
                        marker = markPendingMutation(filters + recorder.filters)
                    }
                    try Self.saveIfNeeded(context)
                })
            } catch {
                // Newest first, so each restore finds the data its own step left. The update may
                // have cancelled fetches of these keys, so they refetch afterwards.
                let rollbacks = recorder.dataRollbacks.reversed()
                let changed = recorder.filters
                Task {
                    for rollback in rollbacks { await rollback() }
                    if !changed.isEmpty {
                        await self.invalidateAndRefetch(changed, refetch: .active)
                    }
                }
                releasePendingMutations([marker].compactMap { $0 })
                if let scopeKey { mutations.release(scopeKey, group) }
                throw error
            }
            dataRollbacks = recorder.dataRollbacks
            filters += recorder.filters
        }
        nextMutationID &+= 1
        let id = nextMutationID

        group.pending += 1
        mutationCount += 1
        if let scopeKey {
            scopeMutationCounts[scopeKey, default: 0] += 1
        }

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

        let run = MutationRun(
            id: id,
            group: group,
            scope: scopeKey,
            filters: filters,
            rollback: rollback,
            dataRollbacks: dataRollbacks,
            isOptimistic: optimistic != nil,
            previous: previous,
            gate: gate,
            marker: marker
        )
        if run.isOptimistic {
            optimisticFilters[id] = filters
            optimisticHistory.append(OptimisticEntry(id: id, scope: scopeKey, filters: filters, run: run))
            undecidedOptimistic.insert(id)
            holdCoveredClients()
        }
        return run
    }

    /// Sends the remote call once it's the mutation's turn, rolls back on failure, and settles.
    func finishMutation<Result>(
        _ run: MutationRun,
        _ mutation: @escaping @Sendable () async throws -> sending Result
    ) async throws -> Result {
        defer {
            mutationCount -= 1
            if let scope = run.scope {
                let count = scopeMutationCounts[scope, default: 1] - 1
                scopeMutationCounts[scope] = count > 0 ? count : nil
            }
        }
        await Self.waitForTurn(after: run.previous)

        let result: Result
        do {
            try Task.checkCancellation()
            result = try await Self.send(mutation)
        } catch {
            run.gate?.open()
            run.group.pending -= 1
            optimisticFilters[run.id] = nil
            var skippedRollback = false
            var rollbacks = run.inheritedRollbacks
            if let rollback = run.rollback {
                rollbacks.append((run.id, rollback))
            }
            if !rollbacks.isEmpty {
                switch rollbackDecision(for: run) {
                case .apply:
                    let context = modelContainer.mainContext
                    do {
                        // Newest first: each restores the values the one after it found.
                        for entry in rollbacks.sorted(by: { $0.id > $1.id }) {
                            try entry.rollback(context)
                        }
                        try Self.saveIfNeeded(context)
                    } catch {
                        skippedRollback = true
                    }
                case .handOff(let heir):
                    // A newer edit covers the same data and its call hasn't returned: roll back
                    // with it if it fails too, or drop this rollback if it succeeds.
                    heir.inheritedRollbacks += rollbacks
                    skippedRollback = true
                case .drop:
                    // A newer edit to the same data succeeded; rolling back would clobber it.
                    skippedRollback = true
                }
            }
            decide(run, succeeded: false)
            // Query data only restores while it still holds this update, so it never clobbers
            // a newer one. Newest first, so each restore finds the data its own step left.
            for rollback in run.dataRollbacks.reversed() {
                await rollback()
            }
            await settle(run, skippedRollback: skippedRollback)
            throw error
        }
        run.gate?.open()
        run.group.pending -= 1
        optimisticFilters[run.id] = nil
        decide(run, succeeded: true)
        await settle(run, skippedRollback: false)
        return result
    }

    private enum RollbackDecision {
        case apply
        case handOff(MutationRun)
        case drop
    }

    /// What to do with a failed mutation's rollbacks, given the newer optimistic mutations that
    /// may have edited the same data: one in the same scope, or whose filters overlap.
    /// - One of them succeeded: drop them, since rolling back would clobber its edit.
    /// - One hasn't returned: hand them to the newest such mutation, to run if it fails too.
    /// - Otherwise (none, or all failed and rolled back to this one's edit): apply them.
    private func rollbackDecision(for run: MutationRun) -> RollbackDecision {
        let newer = optimisticHistory.filter {
            $0.id > run.id && $0.overlaps(scope: run.scope, filters: run.filters)
        }
        if newer.contains(where: { $0.succeeded == true }) { return .drop }
        if let heir = newer.last(where: { $0.succeeded == nil })?.run { return .handOff(heir) }
        return .apply
    }

    /// Records that an optimistic mutation succeeded or failed, and forgets the entries no
    /// undecided mutation is older than.
    private func decide(_ run: MutationRun, succeeded: Bool) {
        guard run.isOptimistic else { return }
        if let index = optimisticHistory.firstIndex(where: { $0.id == run.id }) {
            optimisticHistory[index].succeeded = succeeded
        }
        undecidedOptimistic.remove(run.id)
        let oldest = undecidedOptimistic.min() ?? .max
        optimisticHistory.removeAll { $0.id < oldest }
    }

    /// Invalidates the mutation's keys, or for a scope, every key its mutations touched once
    /// nothing in it is pending. After a skipped rollback, the keys refetch even where no view
    /// shows them, so the edit it left behind is replaced by the server's data.
    private func settle(_ run: MutationRun, skippedRollback: Bool) async {
        guard let scope = run.scope else {
            // A marker whose keys couldn't all be marked invalidated stays, so the next launch
            // invalidates them instead.
            if await invalidateAndRefetch(run.filters, refetch: skippedRollback ? .all : .active) {
                releasePendingMutations([run.marker].compactMap { $0 })
            }
            return
        }
        run.group.filters.formUnion(run.filters)
        run.group.skippedRollback = run.group.skippedRollback || skippedRollback
        run.group.markers += [run.marker].compactMap { $0 }
        guard run.group.pending == 0 else { return }
        let filters = Array(run.group.filters)
        let everywhere = run.group.skippedRollback
        let markers = run.group.markers
        run.group.filters = []
        run.group.skippedRollback = false
        run.group.markers = []
        mutations.release(scope, run.group)
        if await invalidateAndRefetch(filters, refetch: everywhere ? .all : .active) {
            releasePendingMutations(markers)
        }
    }

    /// Records an optimistic mutation's filters as pending, and returns the marker's key. One small
    /// record per mutation, however many keys the filters match. Uses its own context, so the
    /// main context's other changes aren't saved with it.
    private func markPendingMutation(_ filters: [QueryFilter]) -> String? {
        guard !filters.isEmpty, let data = try? JSONEncoder().encode(filters) else { return nil }
        let context = bookkeepingContext()
        let key = QueryRecord.Key.marker()
        context.insert(QueryRecord(key: key, stateData: data))
        guard (try? context.save()) != nil else { return nil }
        return key
    }

    /// Deletes pending markers once their mutations have settled and their keys are invalidated.
    private func releasePendingMutations(_ markers: [String]) {
        guard !markers.isEmpty else { return }
        let context = bookkeepingContext()
        for marker in markers {
            for record in (try? context.fetch(QueryRecord.descriptor(key: marker))) ?? [] {
                context.delete(record)
            }
        }
        try? context.save()
    }

    /// Invalidates the keys of mutations that never settled because the app was terminated, then
    /// deletes their markers. Runs at launch, before any client loads its state.
    func recoverPendingMutations() {
        let context = bookkeepingContext()
        let prefix = QueryRecord.Key.markerPrefix
        let markers = (try? context.fetch(FetchDescriptor<QueryRecord>(
            predicate: #Predicate { $0.key.starts(with: prefix) }
        ))) ?? []
        guard !markers.isEmpty else { return }
        var filters: [QueryFilter] = []
        for marker in markers {
            if let data = marker.stateData, let decoded = try? JSONDecoder().decode([QueryFilter].self, from: data) {
                filters += decoded
            }
            context.delete(marker)
        }
        for record in storedRecords(matching: filters, in: context) {
            record.invalidated = true
        }
        try? context.save()
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
}
