import Foundation

/// The cache policy that decides when a model's data is fresh, stale, or expired.
public enum QueryCache: Sendable, Hashable {
    /// Cached data is retained indefinitely.
    ///
    /// Without `refreshAfter`, data stays fresh until it is invalidated. With `refreshAfter`,
    /// data becomes stale once the interval has elapsed since the last successful fetch.
    case forever(refreshAfter: Duration? = nil)

    /// Stale-while-revalidate: stale data stays available while a background fetch updates SwiftData.
    ///
    /// Data becomes stale `staleTime` after the last successful fetch, and is eligible for
    /// garbage collection once it has gone unused for `cacheTime`.
    case swr(
        staleTime: Duration = .seconds(5 * 60),
        cacheTime: Duration = .seconds(24 * 60 * 60)
    )

    /// The time after a successful fetch at which data becomes stale, if any.
    public var staleTime: Duration? {
        switch self {
        case .forever(let refreshAfter): refreshAfter
        case .swr(let staleTime, _): staleTime
        }
    }

    /// The inactivity time after which cached data may be garbage collected, if any.
    public var cacheTime: Duration? {
        switch self {
        case .forever: nil
        case .swr(_, let cacheTime): cacheTime
        }
    }

    func isStale(lastSyncedAt: Date, now: Date) -> Bool {
        guard let staleTime else { return false }
        return now >= lastSyncedAt.addingTimeInterval(staleTime / .seconds(1))
    }

    func isExpired(lastAccessedAt: Date, now: Date) -> Bool {
        guard let cacheTime else { return false }
        return now >= lastAccessedAt.addingTimeInterval(cacheTime / .seconds(1))
    }
}

/// How old cached state may be before ``QueryProvider/query(_:staleTime:)`` fetches again.
public enum StaleTime: Sendable, Hashable {
    /// Stale once older than the duration. `.after(.zero)` always fetches.
    case after(Duration)
    /// Never stale: any cached state is returned unless it was invalidated.
    case infinite
}
