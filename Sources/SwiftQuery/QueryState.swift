/// The synchronization state of a model, carrying its ``SyncedModel/SyncState``.
public enum QueryState<Value> {
    /// No successful synchronization metadata is available.
    case pending
    /// Synchronized successfully. `stale` is `true` when a refresh is required or the last refresh failed.
    case success(value: Value, stale: Bool)
    /// Synchronization failed and no successful metadata is available.
    case error(any Error)

    /// The sync state of the last successful synchronization, if any.
    public var value: Value? {
        if case .success(let value, _) = self { value } else { nil }
    }

    /// Whether the state is ``pending``.
    public var isPending: Bool {
        if case .pending = self { true } else { false }
    }

    /// Whether the state is a stale ``success(value:stale:)``.
    public var isStale: Bool {
        if case .success(_, let stale) = self { stale } else { false }
    }

    /// Whether the state is ``error(_:)``.
    public var isError: Bool {
        if case .error = self { true } else { false }
    }
}

extension QueryState: Sendable where Value: Sendable {}

/// The fetch activity of a model, independent of its ``QueryState``.
public enum QueryFetchState: Sendable, Hashable {
    /// No fetch is running.
    case idle
    /// The initial synchronization is running.
    case loading
    /// A subsequent synchronization is running.
    case fetching

    /// Whether any fetch is running.
    public var isFetching: Bool { self != .idle }
}
