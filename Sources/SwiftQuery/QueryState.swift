/// A key's query state: whether it has data, the data itself, and whether it's stale.
///
/// The case is the status: `pending`, `success` or `error`.
public enum QueryState<QueryData> {
    /// Nothing has been fetched successfully yet.
    case pending
    /// Fetched successfully. `stale` is `true` when a refresh is required or the last refresh failed.
    case success(data: QueryData, stale: Bool)
    /// The fetch failed and nothing has been fetched successfully yet.
    case error(any Error)

    /// The data from the last successful fetch, if any.
    public var data: QueryData? {
        if case .success(let data, _) = self { data } else { nil }
    }

    /// Whether nothing has been fetched successfully yet.
    public var isPending: Bool {
        if case .pending = self { true } else { false }
    }

    /// Whether the state is ``success(data:stale:)``.
    public var isSuccess: Bool {
        if case .success = self { true } else { false }
    }

    /// Whether the state is a stale ``success(data:stale:)``.
    public var isStale: Bool {
        if case .success(_, let stale) = self { stale } else { false }
    }

    /// Whether the state is ``error(_:)``.
    public var isError: Bool {
        if case .error = self { true } else { false }
    }
}

extension QueryState: Sendable where QueryData: Sendable {}

/// A key's fetch activity, independent of its ``QueryState``.
public enum QueryFetchStatus: Sendable, Hashable {
    /// No fetch is running.
    case idle
    /// A fetch is running.
    case fetching

    /// Whether a fetch is running.
    public var isFetching: Bool { self == .fetching }
}
