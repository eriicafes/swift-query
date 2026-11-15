import Foundation
import Observation
import SwiftData

/// The application-level registry for synced models and fetchers.
///
/// It resolves each key's ``QueryModel/Context`` from `contexts:`, creates one shared client
/// per key on first use, and sweeps the cache of every listed type. Inject it with
/// `.environment(queryProvider)` so views can use ``QueryClient``.
///
/// ```swift
/// queryProvider = QueryProvider(
///     modelContainer: container,
///     contexts: api, socket, httpClient as any HTTPClient,
///     fetchers: User.self, Message.self, UserDetail.self
/// )
/// ```
///
/// - `contexts:` registers each value under its static type. A key's `Context` is looked
///   up by type; to satisfy a protocol-typed context, cast the value: `client as any HTTPClient`.
///   A context type conforming to ``DefaultFetchContext`` (and `Void`) needs no registration.
/// - `fetchers:` lists every persisted model and fetcher type, so the provider can evict their
///   expired caches even when no client exists. Fetchers whose `cache` is `nil` need not be
///   listed. The list doesn't restrict which keys can be used.
@Observable
@MainActor
public final class QueryProvider {
    public let modelContainer: ModelContainer
    /// How long a client is kept after its last view goes away. Then a fetcher client is
    /// dropped and a model client's stream is stopped; model clients themselves are kept for the
    /// whole session.
    public let keepAliveTime: Duration
    /// Orders scoped mutations across every client.
    @ObservationIgnored let mutations = MutationScheduler()
    @ObservationIgnored private var contexts: [ObjectIdentifier: Any] = [:]
    @ObservationIgnored private(set) var entries: [String: FetcherEntry] = [:]
    /// Every live client, held weakly so a client someone still holds is reused, never duplicated.
    @ObservationIgnored private var clients: [AnyHashable: WeakClient] = [:]
    /// Clients kept alive by the provider: models, clients in use, and idle ones in their keep-alive time.
    @ObservationIgnored private var retained: [AnyHashable: any AnyModelQueryClient] = [:]

    public init<each Context: Sendable>(
        modelContainer: ModelContainer,
        contexts: repeat each Context,
        fetchers: any Queryable.Type...,
        keepAliveTime: Duration = .seconds(5 * 60)
    ) {
        precondition(
            modelContainer.schema.entities.contains { $0.name == String(describing: QueryRecord.self) },
            "QueryProvider requires QueryRecord.self in the ModelContainer schema"
        )
        self.modelContainer = modelContainer
        self.keepAliveTime = keepAliveTime
        repeat register(each contexts)
        for type in fetchers {
            let entry = FetcherEntry.make(type)
            precondition(entries[entry.name] == nil, "`\(entry.name)` is listed in `fetchers:` twice")
            entries[entry.name] = entry
        }
        // Fail at launch, not on first use, when a listed type's context is missing.
        for entry in entries.values {
            entry.validate(self)
        }
        // Clean up data that expired since the last launch.
        scheduleGarbageCollection()
    }

    // MARK: Contexts

    private func register<C: Sendable>(_ value: C) {
        let id = ObjectIdentifier(C.self)
        precondition(contexts[id] == nil, "A fetch context of type `\(String(reflecting: C.self))` is registered twice")
        contexts[id] = value
    }

    /// The registered context of exactly type `C`, or one `C` builds itself.
    func fetchContext<C>(_: C.Type) -> C {
        if let value = contexts[ObjectIdentifier(C.self)] as? C {
            return value
        }
        if C.self == Void.self {
            return () as! C
        }
        if let type = C.self as? any DefaultFetchContext.Type, let value = type.init() as? C {
            return value
        }
        fatalError(
            "No fetch context registered for `\(String(reflecting: C.self))`. Register a value of exactly this type in `contexts:`; for a protocol type, cast it: `value as any YourProtocol`."
        )
    }

    // MARK: Clients

    /// The shared client for a fetcher key, created on first use.
    public func client<F: QueryFetcher>(for fetcher: F) -> ModelQueryClient<F> {
        let id = AnyHashable(fetcher)
        if let existing = clients[id]?.client as? ModelQueryClient<F> {
            return existing
        }
        let key = QueryRecord.Key.make(fetcher)
        if fetcher.cache != nil, entries[QueryRecord.Key.typeName(of: key)] == nil {
            assertionFailure(
                "`\(QueryRecord.Key.typeName(of: key))` is persisted but not listed in `fetchers:`, so its expired cache is never evicted"
            )
        }
        let client = ModelQueryClient(
            fetcher: fetcher,
            recordKey: key,
            modelContainer: modelContainer,
            fetchContext: fetchContext(F.Context.self),
            scheduler: mutations,
            onEvict: { [weak self] tags, key in
                await self?.invalidateShared(tags: tags, except: key)
            }
        )
        client.onActivityChange = { [weak self, weak client] in
            guard let self, let client else { return }
            self.activityChanged(id, client)
        }
        clients[id] = WeakClient(client)
        retained[id] = client
        if !client.isModel {
            scheduleRelease(id, client)
        }
        return client
    }

    /// The shared client for a model collection.
    public func client<M: QueryModel>(for model: M.Type) -> ModelQueryClient<ModelFetcher<M>> {
        client(for: ModelFetcher<M>())
    }

    private func activityChanged(_ id: AnyHashable, _ client: any AnyModelQueryClient) {
        if client.isActive {
            retained[id] = client
            client.idleGeneration &+= 1
        } else {
            scheduleRelease(id, client)
        }
    }

    /// Keeps an idle client for the keep-alive time. If it isn't used again, a fetcher client is
    /// let go (cancelling its stream when it deallocates) and a model client's stream is stopped.
    private func scheduleRelease(_ id: AnyHashable, _ client: any AnyModelQueryClient) {
        retained[id] = client
        client.idleGeneration &+= 1
        let generation = client.idleGeneration
        let keepAliveTime = keepAliveTime
        Task { [weak self, weak client] in
            try? await Task.sleep(for: keepAliveTime)
            guard let self, let client,
                  client.idleGeneration == generation, !client.isActive,
                  self.retained[id] === client
            else { return }
            if client.isModel {
                client.cancelStream()
            } else {
                self.retained[id] = nil
                self.pruneClients()
            }
        }
    }

    // MARK: Garbage collection

    @ObservationIgnored private var garbageCollection: Task<Void, Never>?

    /// Starts a garbage collection sweep unless one is already running. Runs at launch and when
    /// the app goes to the background.
    func scheduleGarbageCollection() {
        guard garbageCollection == nil else { return }
        garbageCollection = Task { [weak self] in
            await self?.collectGarbage()
            self?.garbageCollection = nil
        }
    }

    /// Waits for a scheduled sweep to finish.
    func waitForGarbageCollection() async {
        await garbageCollection?.value
    }

    private func pruneClients() {
        clients = clients.filter { $0.value.client != nil }
    }

    /// Every client still alive, whether retained or held elsewhere.
    var liveClients: [any AnyModelQueryClient] {
        clients.values.compactMap { $0.client as? any AnyModelQueryClient }
    }

    // MARK: Reading and writing state

    /// The current status of a key, without creating a client or fetching. Uses the live client
    /// if there is one (observable in views), otherwise the stored state (a snapshot).
    public func getQueryState<F: QueryFetcher>(for fetcher: F) -> QueryState<F.QueryData> {
        if let live = clients[AnyHashable(fetcher)]?.client as? ModelQueryClient<F> {
            return live.state
        }
        guard fetcher.cache != nil,
              let (value, _, stale) = ModelQueryClient<F>.storedState(
                fetcher, key: QueryRecord.Key.make(fetcher), in: modelContainer.mainContext
              )
        else { return .pending }
        return .success(data: value, stale: stale)
    }

    /// The current status of a model collection. See ``getQueryState(for:)-(F)``.
    public func getQueryState<M: QueryModel>(for model: M.Type) -> QueryState<M.QueryData> {
        getQueryState(for: ModelFetcher<M>())
    }

    /// The key's data, without creating a client or fetching. Shorthand for
    /// `getQueryState(for:).data`.
    public func getQueryData<F: QueryFetcher>(for fetcher: F) -> F.QueryData? {
        getQueryState(for: fetcher).data
    }

    /// ``getQueryData(for:)-(F)`` for a model collection.
    public func getQueryData<M: QueryModel>(for model: M.Type) -> M.QueryData? {
        getQueryData(for: ModelFetcher<M>())
    }

    /// Returns the key's state if it is fresh, otherwise fetches it and returns the result.
    ///
    /// `staleTime` overrides how old the cached state may be: `nil` uses the key's own cache
    /// policy, `.infinite` accepts any cached state, `.after(.zero)` always fetches. Joins a fetch
    /// already in flight. Throws when the fetch fails.
    @discardableResult
    public func query<F: QueryFetcher>(_ fetcher: F, staleTime: StaleTime? = nil) async throws -> F.QueryData {
        try await client(for: fetcher).query(staleTime: staleTime)
    }

    /// ``query(_:staleTime:)-(F,_)`` for a model collection.
    @discardableResult
    public func query<M: QueryModel>(_ model: M.Type, staleTime: StaleTime? = nil) async throws -> M.QueryData {
        try await query(ModelFetcher<M>(), staleTime: staleTime)
    }

    /// Starts ``query(_:staleTime:)-(F,_)`` without waiting for it or reporting errors.
    public func prefetch<F: QueryFetcher>(_ fetcher: F, staleTime: StaleTime? = nil) {
        let client = client(for: fetcher)
        Task { _ = try? await client.query(staleTime: staleTime) }
    }

    /// ``prefetch(_:staleTime:)-(F,_)`` for a model collection.
    public func prefetch<M: QueryModel>(_ model: M.Type, staleTime: StaleTime? = nil) {
        prefetch(ModelFetcher<M>(), staleTime: staleTime)
    }

    /// Replaces a key's state as if a fetch had just returned it, for example with a
    /// mutation's response. The state counts as fresh.
    public func setQueryData<F: QueryFetcher>(for fetcher: F, _ data: F.QueryData) async throws {
        try await client(for: fetcher).setQueryData(data)
    }

    /// ``setQueryData(for:_:)-(F,_)`` for a model collection.
    public func setQueryData<M: QueryModel>(for model: M.Type, _ data: M.QueryData) async throws {
        try await setQueryData(for: ModelFetcher<M>(), data)
    }

    // MARK: Bulk operations

    /// Marks a key's cache as stale. Clients shown in a view re-sync right away; other keys
    /// fetch on their next sync. Existing data stays available.
    public func invalidate<F: QueryFetcher>(_ fetcher: F) { invalidate(.key(QueryRecord.Key.make(fetcher))) }
    /// Invalidates every key of a fetcher type, or a model collection.
    public func invalidate(_ type: any Queryable.Type) { invalidate(.type(String(reflecting: type))) }
    /// Invalidates every key tagged `tag`.
    public func invalidate(tag: String) { invalidate(.tag(tag)) }

    /// Fetches matching keys that have a live client. With `includeStored`, also fetches stored
    /// keys of listed types that have no client.
    ///
    /// Only existing keys are refetched: a key that was never fetched, or an in-memory key whose
    /// client was dropped, has neither a client nor a stored record, so nothing happens. To fetch
    /// any key unconditionally, use ``query(_:staleTime:)-(F,_)`` with `staleTime: .after(.zero)`.
    public func refetch<F: QueryFetcher>(_ fetcher: F) async { await refetch(.key(QueryRecord.Key.make(fetcher)), includeStored: true) }
    /// Refetches every key of a fetcher type, or a model collection.
    public func refetch(_ type: any Queryable.Type, includeStored: Bool = false) async {
        await refetch(.type(String(reflecting: type)), includeStored: includeStored)
    }
    /// Refetches every key tagged `tag`.
    public func refetch(tag: String, includeStored: Bool = false) async {
        await refetch(.tag(tag), includeStored: includeStored)
    }

    /// Cancels in-flight fetches. Rows already saved stay and states keep their previous value.
    public func cancel<F: QueryFetcher>(_ fetcher: F) { cancel(.key(QueryRecord.Key.make(fetcher))) }
    /// Cancels in-flight fetches of every key of a fetcher type, or a model collection.
    public func cancel(_ type: any Queryable.Type) { cancel(.type(String(reflecting: type))) }
    /// Cancels in-flight fetches of every key tagged `tag`.
    public func cancel(tag: String) { cancel(.tag(tag)) }

    /// Drops cached state: evicts the key's rows, deletes its stored state, and returns live
    /// clients to `.pending`. Keys sharing a tag with a removed key are invalidated.
    public func remove<F: QueryFetcher>(_ fetcher: F) async { await remove(.key(QueryRecord.Key.make(fetcher)), refetchObserved: false) }
    /// Removes every key of a fetcher type, or a model collection.
    public func remove(_ type: any Queryable.Type) async { await remove(.type(String(reflecting: type)), refetchObserved: false) }
    /// Removes every key tagged `tag`.
    public func remove(tag: String) async { await remove(.tag(tag), refetchObserved: false) }

    /// Removes matching keys, then syncs the ones a view still shows.
    public func reset<F: QueryFetcher>(_ fetcher: F) async { await remove(.key(QueryRecord.Key.make(fetcher)), refetchObserved: true) }
    /// Resets every key of a fetcher type, or a model collection.
    public func reset(_ type: any Queryable.Type) async { await remove(.type(String(reflecting: type)), refetchObserved: true) }
    /// Resets every key tagged `tag`.
    public func reset(tag: String) async { await remove(.tag(tag), refetchObserved: true) }

    /// Evicts expired SWR caches of live clients that are unobserved and idle, and of every
    /// stored key without a client, using each record's stored cache time. Records of types no
    /// longer listed are deleted without `evict`; `.forever` records are kept.
    ///
    /// The provider already runs this at launch and whenever the app goes to the background;
    /// call it yourself only to clean up at another time.
    public func collectGarbage() async {
        for client in liveClients {
            await client.collectGarbage()
        }
        let liveKeys = Set(liveClients.map(\.recordKey))
        let context = bookkeepingContext()
        let records = (try? context.fetch(FetchDescriptor<QueryRecord>(
            predicate: #Predicate { $0.gcTime != nil && $0.stateData != nil }
        ))) ?? []
        let now = Date.now
        for record in records where !liveKeys.contains(record.key) && record.isExpired(now: now) {
            await evictStored(record, in: context)
        }
    }

    // MARK: Selectors

    enum Selector {
        case key(String)
        case type(String)
        case tag(String)

        func matches(key: String, tags: Set<String>) -> Bool {
            switch self {
            case .key(let match): key == match
            case .type(let name): key == name || key.hasPrefix(name + ":")
            case .tag(let tag): tags.contains(tag)
            }
        }

        func descriptor() -> FetchDescriptor<QueryRecord> {
            switch self {
            case .key(let key):
                return FetchDescriptor(predicate: #Predicate { $0.key == key })
            case .type(let name):
                let prefix = name + ":"
                return FetchDescriptor(predicate: #Predicate { $0.key == name || $0.key.starts(with: prefix) })
            case .tag(let tag):
                let needle = QueryRecord.Tags.needle(tag)
                return FetchDescriptor(predicate: #Predicate { $0.tags.contains(needle) })
            }
        }
    }

    private func liveClients(matching selector: Selector) -> [any AnyModelQueryClient] {
        liveClients.filter { selector.matches(key: $0.recordKey, tags: $0.tagSet) }
    }

    private func storedRecords(matching selector: Selector, in context: ModelContext) -> [QueryRecord] {
        let liveKeys = Set(liveClients.map(\.recordKey))
        let records = (try? context.fetch(selector.descriptor())) ?? []
        return records.filter { !liveKeys.contains($0.key) }
    }

    private func bookkeepingContext() -> ModelContext {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return context
    }

    private func invalidate(_ selector: Selector, except excluded: String? = nil) {
        for client in liveClients(matching: selector) where client.recordKey != excluded {
            client.invalidate()
            if client.isObserved {
                client.resync()
            }
        }
        let context = bookkeepingContext()
        for record in storedRecords(matching: selector, in: context) where record.key != excluded {
            record.invalidated = true
        }
        try? context.save()
    }

    /// Invalidates other keys that share a tag with an evicted or removed key.
    func invalidateShared(tags: Set<String>, except key: String) {
        for tag in tags {
            invalidate(.tag(tag), except: key)
        }
    }

    private func refetch(_ selector: Selector, includeStored: Bool) async {
        var refreshes: [@MainActor () async -> Void] = liveClients(matching: selector).map { client in
            { await client.refresh() }
        }
        if includeStored {
            for record in storedRecords(matching: selector, in: bookkeepingContext()) {
                guard let entry = entries[QueryRecord.Key.typeName(of: record.key)] else { continue }
                let key = record.key
                refreshes.append { await entry.refresh(key, self) }
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for refresh in refreshes {
                group.addTask { await refresh() }
            }
        }
    }

    private func cancel(_ selector: Selector) {
        for client in liveClients(matching: selector) {
            client.cancel()
        }
    }

    private func remove(_ selector: Selector, refetchObserved: Bool) async {
        for client in liveClients(matching: selector) {
            if refetchObserved {
                await client.reset()
            } else {
                await client.remove()
            }
        }
        let context = bookkeepingContext()
        for record in storedRecords(matching: selector, in: context) {
            await evictStored(record, in: context)
        }
    }

    /// Evicts a stored key that has no client: clears or deletes its record first, then runs the
    /// type's `evict` if the type is listed and the key still decodes.
    private func evictStored(_ record: QueryRecord, in context: ModelContext) async {
        let key = record.key
        let tags = QueryRecord.Tags.decode(record.tags)
        if QueryRecord.Key.isModel(key) {
            record.stateData = nil
            record.lastSyncedAt = nil
            record.invalidated = false
        } else {
            context.delete(record)
        }
        guard (try? context.save()) != nil else {
            context.rollback()
            return
        }
        if let entry = entries[QueryRecord.Key.typeName(of: key)] {
            let evictContext = bookkeepingContext()
            if (try? entry.evict(key, evictContext)) != nil, evictContext.hasChanges {
                try? evictContext.save()
            }
        }
        invalidateShared(tags: tags, except: key)
    }
}

/// A listed model or fetcher type, with what the provider needs for keys that have no client.
@MainActor
struct FetcherEntry {
    let name: String
    let validate: @MainActor (QueryProvider) -> Void
    /// Decodes the key and runs the type's `evict`. Does nothing if the key no longer decodes.
    let evict: @MainActor (_ key: String, _ context: ModelContext) throws -> Void
    /// Creates a client for the key and refreshes it.
    let refresh: @MainActor (_ key: String, _ provider: QueryProvider) async -> Void

    static func make(_ type: any Queryable.Type) -> FetcherEntry {
        if let model = type as? any QueryModel.Type {
            return entry(for: model)
        }
        if let fetcher = type as? any QueryFetcher.Type {
            return entry(for: fetcher)
        }
        preconditionFailure("`\(type)` must conform to QueryModel or QueryFetcher")
    }

    private static func entry<M: QueryModel>(for _: M.Type) -> FetcherEntry {
        entry(for: ModelFetcher<M>.self)
    }

    private static func entry<F: QueryFetcher>(for _: F.Type) -> FetcherEntry {
        FetcherEntry(
            name: (F.self as? any ModelFetcherKind.Type)?.modelTypeName ?? String(reflecting: F.self),
            validate: { provider in _ = provider.fetchContext(F.Context.self) },
            evict: { key, context in
                try QueryRecord.Key.decode(F.self, from: key)?.evict(context: context)
            },
            refresh: { key, provider in
                guard let fetcher = QueryRecord.Key.decode(F.self, from: key) else { return }
                await provider.client(for: fetcher).refresh()
            }
        )
    }
}

@MainActor
final class WeakClient {
    weak var client: AnyObject?

    init(_ client: AnyObject) {
        self.client = client
    }
}
