import SwiftUI

/// Connects a view to the shared ``ModelQueryClient`` for a model and syncs it
/// when the view appears.
///
/// ```swift
/// @QueryClient(User.self, .swr(staleTime: .seconds(30)))
/// private var usersClient
///
/// @Query(sort: \User.name)
/// private var users: [User]
/// ```
///
/// The client is shared through the environment's ``QueryProvider``; the wrapper never creates
/// its own. A sync is requested when the view appears and again whenever its scene becomes
/// active, not on every body evaluation. The cache override applies only to those requests.
/// While the view is alive the model's cache counts as in use and is not garbage collected.
@propertyWrapper
public struct QueryClient<Model: SyncedModel>: DynamicProperty {
    @Environment(QueryProvider.self) private var provider
    @Environment(\.scenePhase) private var scenePhase
    @State private var subscription = Subscription<Model>()
    private let cache: QueryCache?

    public init(_ model: Model.Type, _ cache: QueryCache? = nil) {
        self.cache = cache
    }

    @MainActor
    public var wrappedValue: ModelQueryClient<Model> {
        provider.client(for: Model.self)
    }

    public nonisolated func update() {
        let subscription = subscription
        let provider = provider
        let cache = cache
        let scenePhase = scenePhase
        MainActor.assumeIsolated {
            // An unregistered model only fails when the view actually reads the client.
            guard let client = provider.registeredClient(for: Model.self) else { return }
            subscription.activate(client, cache: cache, phase: scenePhase)
        }
    }
}

/// Tracks one view's subscription: syncs when it first activates and when its scene
/// becomes active again, never on plain body re-evaluations.
@MainActor
final class Subscription<Model: SyncedModel> {
    private var client: ModelQueryClient<Model>?
    private var phase: ScenePhase?

    nonisolated init() {}

    func activate(_ client: ModelQueryClient<Model>, cache: QueryCache?, phase: ScenePhase = .active) {
        defer { self.phase = phase }
        guard self.client === client else {
            self.client?.detach()
            self.client = client
            client.attach(cache)
            return
        }
        if phase == .active, let previous = self.phase, previous != .active {
            client.sync(cache ?? Model.cache)
        }
    }

    deinit {
        guard let client else { return }
        Task { @MainActor in client.detach() }
    }
}
