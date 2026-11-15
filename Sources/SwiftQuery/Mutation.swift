/// Shared bookkeeping for a set of mutations: how many are pending, which optimistic update
/// is newest, and which clients need a refetch once none are pending.
///
/// Unscoped mutations use one group per client and run in parallel. Scoped mutations use one
/// group per scope, shared across clients, and their remote calls run one at a time.
@MainActor
final class MutationGroup {
    /// Completes when the last queued mutation's remote call has finished. Scoped groups only.
    var tail: Task<Void, Never>?
    var pending = 0
    /// The newest optimistic mutation; an older one that fails skips its rollback.
    var latestOptimistic: UInt64 = 0
    /// Refetches to run when `pending` reaches zero, keyed by client.
    var refetches: [ObjectIdentifier: @MainActor () async -> Void] = [:]
}

/// Orders scoped mutations. Owned by ``QueryProvider`` and shared by its clients,
/// so a scope can span several models.
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
