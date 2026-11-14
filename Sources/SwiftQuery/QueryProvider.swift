import Observation
import SwiftData

/// The application-level registry of synchronized models.
///
/// Holds one shared ``ModelQueryClient`` per registered model type. Inject it with
/// `.environment(queryProvider)` so views can use ``QueryClient``.
///
/// ```swift
/// queryProvider = QueryProvider(
///     modelContainer: container,
///     for:
///         .model(User.self, .init(session: .shared)),
///         .model(Post.self, .init(session: .shared))
/// )
/// ```
@Observable
@MainActor
public final class QueryProvider {
    public let modelContainer: ModelContainer
    @ObservationIgnored private var models: [ObjectIdentifier: any AnyModelQueryClient] = [:]
    /// Orders scoped mutations across every registered model.
    @ObservationIgnored let mutations = MutationScheduler()

    public init<each M: SyncedModel>(
        modelContainer: ModelContainer,
        for models: repeat Model<each M>
    ) {
        precondition(
            modelContainer.schema.entities.contains { $0.name == Schema.entityName(for: QueryRecord.self) },
            "QueryProvider requires QueryRecord.self in the ModelContainer schema"
        )
        self.modelContainer = modelContainer
        repeat (each models).register(in: self)
    }

    /// Registers a model type. Registering the same type again is ignored.
    public func register<M: SyncedModel>(
        _ model: M.Type,
        context syncContext: M.SyncContext
    ) {
        let id = ObjectIdentifier(model)
        guard models[id] == nil else { return }
        models[id] = ModelQueryClient<M>(
            modelContainer: modelContainer,
            syncContext: syncContext,
            scheduler: mutations
        )
    }

    /// Removes a model type's client and cancels its stream task and any in-flight fetch.
    /// The removed client ignores later operations, even if a view still holds it.
    ///
    /// Unregister only models no visible view uses: a view's ``QueryClient`` stops syncing, but
    /// reading its `wrappedValue` afterwards is a missing-registration error.
    public func unregister<M: SyncedModel>(_ model: M.Type) {
        models.removeValue(forKey: ObjectIdentifier(model))?.retire()
    }

    /// The shared client for a registered model type.
    public func client<M: SyncedModel>(for model: M.Type) -> ModelQueryClient<M> {
        guard let client = registeredClient(for: model) else {
            fatalError("Missing QueryProvider registration for \(M.self)")
        }
        return client
    }

    /// The client for a model type, or `nil` if it isn't registered.
    func registeredClient<M: SyncedModel>(for model: M.Type) -> ModelQueryClient<M>? {
        models[ObjectIdentifier(model)] as? ModelQueryClient<M>
    }

    /// Evicts SWR caches that have gone unused for their model's `cacheTime`.
    /// Models that are currently observed or fetching are skipped.
    public func collectGarbage() async {
        for client in models.values {
            await client.collectGarbage()
        }
    }
}

extension QueryProvider {
    /// A typed model registration holding the model's ``SyncedModel/SyncContext``.
    public struct Model<M: SyncedModel> {
        public let context: M.SyncContext

        public init(context: M.SyncContext) {
            self.context = context
        }

        public static func model(_: M.Type, _ context: M.SyncContext) -> Self {
            .init(context: context)
        }

        @MainActor
        public func register(in provider: QueryProvider) {
            provider.register(M.self, context: context)
        }
    }
}

extension Schema {
    static func entityName(for type: any PersistentModel.Type) -> String {
        String(describing: type)
    }
}
