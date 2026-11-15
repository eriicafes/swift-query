import SwiftUI

/// Connects a view to the shared ``ModelQueryClient`` for a key and syncs it while the view is
/// alive.
///
/// ```swift
/// @QueryClient(User.self) private var usersClient
/// @QueryClient(UserDetail(id: id)) private var detail
/// @QueryClient(ExchangeRate(from: "USD", to: "EUR"), .swr(staleTime: .seconds(10))) private var rate
/// ```
///
/// The client comes from the environment's ``QueryProvider``, which creates it on first use.
/// A sync is requested when the view appears and again whenever its scene becomes active, not on
/// every body evaluation; the key's stream starts if it has one. The cache override applies
/// only to this view's requests. While the view is alive the key counts as in use: its client is
/// kept and its cache isn't garbage collected.
@propertyWrapper
public struct QueryClient<Fetcher: QueryFetcher>: DynamicProperty {
    @Environment(QueryProvider.self) private var provider
    @Environment(\.scenePhase) private var scenePhase
    @State private var subscription = Subscription<Fetcher>()
    private let fetcher: Fetcher
    private let cache: QueryCache?

    /// Syncs a fetcher key.
    public init(_ fetcher: Fetcher, _ cache: QueryCache? = nil) {
        self.fetcher = fetcher
        self.cache = cache
    }

    /// Syncs a model collection.
    public init<M: QueryModel>(_ model: M.Type, _ cache: QueryCache? = nil) where Fetcher == ModelFetcher<M> {
        self.init(ModelFetcher<M>(), cache)
    }

    @MainActor
    public var wrappedValue: ModelQueryClient<Fetcher> {
        provider.client(for: fetcher)
    }

    public nonisolated func update() {
        let subscription = subscription
        let provider = provider
        let fetcher = fetcher
        let cache = cache
        let scenePhase = scenePhase
        MainActor.assumeIsolated {
            subscription.activate(provider.client(for: fetcher), cache: cache, phase: scenePhase) {
                provider.scheduleGarbageCollection()
            }
        }
    }
}

/// Tracks one view's subscription: syncs when it first activates or its key changes, and when
/// its scene becomes active again, never on plain body re-evaluations.
@MainActor
final class Subscription<Fetcher: QueryFetcher> {
    private var client: ModelQueryClient<Fetcher>?
    private var phase: ScenePhase?

    nonisolated init() {}

    func activate(
        _ client: ModelQueryClient<Fetcher>,
        cache: QueryCache?,
        phase: ScenePhase = .active,
        onBackground: (@MainActor () -> Void)? = nil
    ) {
        defer { self.phase = phase }
        if phase == .background, let previous = self.phase, previous != .background {
            onBackground?()
        }
        guard self.client === client else {
            self.client?.detach()
            self.client = client
            client.attach(cache)
            return
        }
        if phase == .active, let previous = self.phase, previous != .active {
            client.sync(cache ?? client.fetcher.cache ?? .forever())
        }
    }

    deinit {
        guard let client else { return }
        Task { @MainActor in client.detach() }
    }
}
