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
/// - `recoversInterruptedMutations` invalidates, at launch, the keys of optimistic mutations that
///   never settled because the app was terminated. Pass `false` for a provider that shares its
///   store with another one running at the same time, such as in an app extension, so it doesn't
///   mistake the app's mutations in progress for interrupted ones.
@Observable
@MainActor
public final class QueryProvider {
    public let modelContainer: ModelContainer
    /// How long a client is kept after its last view goes away. Then a fetcher client is
    /// dropped and a model client's subscription task is cancelled; model clients themselves are
    /// kept for the whole session.
    public let keepAliveTime: Duration
    /// Orders scoped mutations across every client.
    @ObservationIgnored let mutations = MutationScheduler()
    /// How many mutations are running or queued.
    var mutationCount = 0
    /// How many mutations are running or queued per scope.
    var scopeMutationCounts: [AnyHashable: Int] = [:]
    /// The filters of optimistic mutations whose remote call hasn't returned, by mutation id.
    /// Keys they match are held: syncs don't fetch them, and settling defers their refetch.
    @ObservationIgnored var optimisticFilters: [UInt64: [QueryFilter]] = [:]
    /// The id of the most recently begun mutation.
    @ObservationIgnored var nextMutationID: UInt64 = 0
    /// Optimistic mutations newer than the oldest one still undecided, so a failing mutation can
    /// skip a rollback that would clobber a newer edit.
    @ObservationIgnored var optimisticHistory: [OptimisticEntry] = []
    /// Optimistic mutations whose remote call hasn't succeeded or failed yet.
    @ObservationIgnored var undecidedOptimistic: Set<UInt64> = []
    @ObservationIgnored private var contexts: [ObjectIdentifier: Any] = [:]
    @ObservationIgnored private(set) var entries: [String: FetcherEntry]
    /// Every live client, held weakly so a client someone still holds is reused, never duplicated.
    @ObservationIgnored private var clients: [AnyHashable: WeakClient] = [:]
    /// Clients kept alive by the provider: models, clients in use, and idle ones in their keep-alive time.
    @ObservationIgnored private var retained: [AnyHashable: any AnyQueryObserver] = [:]
    /// Does bulk work on stored records off the main actor.
    @ObservationIgnored private let store: RecordStore
    /// The last store operation queued; each one waits for the previous.
    @ObservationIgnored private var storeTail: Task<Void, Never>?
    @ObservationIgnored private var nextStoreWriteID: UInt64 = 0
    /// Store writes that haven't finished, by id. A client created meanwhile for a key one covers
    /// waits for it before reading its record.
    @ObservationIgnored private var pendingStoreWrites: [UInt64: PendingStoreWrite] = [:]

    public init<each Context: Sendable>(
        modelContainer: ModelContainer,
        contexts: repeat each Context,
        fetchers: any Queryable.Type...,
        keepAliveTime: Duration = .seconds(5 * 60),
        recoversInterruptedMutations: Bool = true
    ) {
        precondition(
            modelContainer.schema.entities.contains { $0.name == String(describing: QueryRecord.self) },
            "QueryProvider requires QueryRecord.self in the ModelContainer schema"
        )
        self.modelContainer = modelContainer
        self.keepAliveTime = keepAliveTime
        var entries: [String: FetcherEntry] = [:]
        for type in fetchers {
            let entry = FetcherEntry.make(type)
            precondition(entries[entry.name] == nil, "`\(entry.name)` is listed in `fetchers:` twice")
            entries[entry.name] = entry
        }
        self.entries = entries
        self.store = RecordStore(container: modelContainer, evictors: entries.mapValues(\.evict))
        repeat register(each contexts)
        // Fail at launch, not on first use, when a listed type's context is missing.
        for entry in entries.values {
            entry.validate(self)
        }
        // Refetch keys whose optimistic changes were saved by mutations that never settled.
        if recoversInterruptedMutations {
            recoverPendingMutations()
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
    public func client<F: QueryFetcher>(for fetcher: F) -> QueryObserver<F> {
        let id = AnyHashable(fetcher)
        if let existing = clients[id]?.client as? QueryObserver<F> {
            return existing
        }
        let key = QueryRecord.Key.make(fetcher)
        if fetcher.cache != nil, entries[QueryRecord.Key.typeName(of: key)] == nil {
            assertionFailure(
                "`\(QueryRecord.Key.typeName(of: key))` is persisted but not listed in `fetchers:`, so its expired cache is never evicted"
            )
        }
        // A store write still running for this key must land before the client reads its record.
        let pending = pendingStoreWrites.values.filter { write in
            write.filters.contains { $0.matches(key: key, tags: fetcher.tags) }
        }
        let gate: Task<Void, Never>? = pending.isEmpty ? nil : Task {
            for write in pending {
                await write.task.value
            }
        }
        let client = QueryObserver(
            fetcher: fetcher,
            recordKey: key,
            modelContainer: modelContainer,
            fetchContext: fetchContext(F.Context.self),
            provider: self,
            gate: gate,
            initialLoad: pending.contains(where: \.evicts) ? .skip
                : pending.isEmpty ? .stored : .storedStale,
            onEvict: { [weak self] tags, key in
                await self?.invalidateShared(tags: tags, except: [key])
            }
        )
        client.onActivityChange = { [weak self, weak client] in
            guard let self, let client else { return }
            self.activityChanged(id, client)
        }
        clients[id] = WeakClient(client)
        retained[id] = client
        if isCovered(client) {
            client.hold()
        }
        if !client.isModel {
            scheduleRelease(id, client)
        }
        return client
    }

    /// The shared client for a model collection.
    public func client<M: QueryModel>(for model: M.Type) -> QueryObserver<ModelFetcher<M>> {
        client(for: ModelFetcher<M>())
    }

    private func activityChanged(_ id: AnyHashable, _ client: any AnyQueryObserver) {
        if client.isActive {
            retained[id] = client
            client.idleGeneration &+= 1
        } else {
            scheduleRelease(id, client)
        }
    }

    /// Keeps an idle client for the keep-alive time. If it isn't used again, a fetcher client is
    /// let go (cancelling its subscription task when it deallocates) and a model client's
    /// subscription task is cancelled.
    private func scheduleRelease(_ id: AnyHashable, _ client: any AnyQueryObserver) {
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
                client.unsubscribe()
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
    var liveClients: [any AnyQueryObserver] {
        clients.values.compactMap { $0.client as? any AnyQueryObserver }
    }

    // MARK: Reading and writing state

    /// The current status of a key, without creating a client or fetching. Uses the live client
    /// if there is one (observable in views), otherwise the stored state (a snapshot).
    public func getQueryState<F: QueryFetcher>(for fetcher: F) -> QueryState<F.QueryData> {
        if let live = clients[AnyHashable(fetcher)]?.client as? QueryObserver<F> {
            return live.state
        }
        guard fetcher.cache != nil,
              let (value, _, stale) = QueryObserver<F>.storedState(
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

    // MARK: Mutations

    /// Runs a remote mutation, optionally applying an optimistic update first, then invalidates
    /// the keys it affects.
    ///
    /// ```swift
    /// try await provider.mutate(scope: "user-\(id)", invalidates: [.tag("users")]) {
    ///     try await api.follow(id)
    /// } optimistic: { tx in
    ///     tx.setQueryData(for: UserStats(id: id)) { $0.followers += 1 }
    /// }
    /// ```
    ///
    /// - The optimistic update applies immediately. Rows are edited on the main context, which is
    ///   then saved so a later refetch can't be overwritten by an unsaved edit; rollbacks are saved
    ///   the same way. If that save fails, the update is rolled back and the error is rethrown
    ///   before anything is sent. With `autosaveEnabled` off, nothing is saved for you: save in
    ///   your closures.
    /// - The remote call runs in its own task, so cancelling the caller doesn't cancel a call that
    ///   was already sent; the caller still gets its result. A caller cancelled before its call is
    ///   sent rolls back and throws `CancellationError`.
    /// - On failure, the rollbacks registered with ``OptimisticContext/onRollback(_:)`` run and
    ///   query data changed with ``OptimisticContext/setQueryData(for:_:)-(F,_)`` is restored,
    ///   then the error is rethrown. Query data is only restored if nothing has changed it since.
    ///   The rollbacks are skipped if a newer optimistic mutation may have edited the same data,
    ///   so they can't clobber its change: one in the same scope, or one whose filters overlap
    ///   this mutation's (a tag or `.all` overlaps every filter; keys and types overlap when they
    ///   match a common key; a mutation without filters overlaps only its scope). The mutation's
    ///   keys that have a client then refetch even where no view shows them.
    /// - Whether it succeeds or fails, the mutation settles by invalidating the keys matching
    ///   `invalidates`, plus any key whose query data the optimistic update changed. Keys shown
    ///   in a view refetch with a request sent after the mutation, and `mutate` waits for them; a
    ///   failed refetch is reported by its client and doesn't make `mutate` throw. Other keys
    ///   fetch on their next sync.
    ///
    /// Mutation failures never change a key's state to `.error`.
    ///
    /// Before optimistic changes are saved, the mutation's filters are stored as pending. If the
    /// app is terminated before it settles, the keys they match are invalidated at the next
    /// launch, so optimistic data the server never confirmed is refetched. A provider that shares
    /// its store with another one running at the same time, such as in an app extension, should
    /// pass `recoversInterruptedMutations: false`.
    ///
    /// While an optimistic mutation's remote call is in flight, the keys its filters match are
    /// held: syncs from views don't fetch them if they have data, and when another mutation
    /// settles, their refetch waits until no in-flight optimistic mutation covers them. So the
    /// server's older data can't overwrite the edit. ``QueryObserver/refresh()`` and
    /// ``query(_:staleTime:)-(F,_)`` still fetch.
    ///
    /// ### Scopes
    ///
    /// Mutations with the same `scope` send their remote calls one at a time, in call order,
    /// whether they are started from the provider, a ``QueryObserver``, or a
    /// ``MutationClient``. Mutations without a scope run in parallel. A per-record scope such as
    /// `"user-\(id)"` is typical; always use the same scope (or always none) for a given record.
    ///
    /// Within a scope, optimistic updates still apply immediately, a failure doesn't cancel later
    /// mutations, and each error goes only to its own caller. The scope settles once it has
    /// nothing left queued, invalidating the keys of every mutation in it at once, and only the
    /// caller of the last mutation waits for it. A caller cancelled while queued stops waiting
    /// right away, rolls back, and throws `CancellationError` without sending its remote call;
    /// later mutations keep their order.
    @discardableResult
    public func mutate<Result>(
        scope: (any Hashable & Sendable)? = nil,
        invalidates: [QueryFilter] = [],
        _ mutation: @escaping @Sendable () async throws -> sending Result,
        optimistic: OptimisticUpdate? = nil
    ) async throws -> Result {
        let run = try beginMutation(scope: scope, invalidates: invalidates, optimistic: optimistic)
        return try await finishMutation(run, mutation)
    }

    /// Whether any mutation is queued, running, or waiting for its keys to refetch. In a scope,
    /// only the last mutation waits for the refetch.
    public var isMutating: Bool { mutationCount > 0 }

    /// Whether a mutation in `scope` is queued, running, or waiting for the scope's keys to
    /// refetch.
    public func isMutating(scope: any Hashable & Sendable) -> Bool {
        scopeMutationCounts[AnyHashable(scope), default: 0] > 0
    }

    // MARK: Bulk operations

    /// Marks matching keys as stale and refetches the ones `refetch` selects, waiting for those
    /// fetches. Existing data stays available. Keys not refetched fetch on their next sync.
    ///
    /// `refetch` picks which matching keys fetch now: `.active` (the default) the keys shown in a
    /// view, `.inactive` every other key including stored keys of listed types that have data,
    /// `.all` both, and `nil` none. Each refetch uses a request sent after this call: a fetch
    /// already in flight is waited for, then followed by a new one. A failed refetch is reported
    /// by its client and doesn't make `invalidate` throw.
    ///
    /// A key an optimistic mutation in flight covers refetches once that mutation settles
    /// instead, so its edit isn't overwritten; `invalidate` doesn't wait for it.
    ///
    /// ```swift
    /// await provider.invalidate(.tag("users"), .type(UserStats.self))
    /// ```
    public func invalidate(_ filters: QueryFilter..., refetch type: QueryType? = .active) async {
        await invalidateAndRefetch(filters, refetch: type, includesStored: true)
    }

    /// Fetches matching keys with a request sent after this call, waiting for those fetches. A
    /// fetch already in flight is waited for, then followed by a new one.
    ///
    /// `type` picks which keys: `.active` (the default) refetches keys shown in a view;
    /// `.inactive` refetches every other key the provider knows about, including stored keys of
    /// listed types that have no client; `.all` refetches both. A key that was never fetched, or
    /// whose data was removed, has nothing to refetch. To fetch any key unconditionally, use
    /// ``query(_:staleTime:)-(F,_)`` with `staleTime: .after(.zero)`.
    public func refetch(_ filters: QueryFilter..., type: QueryType = .active) async {
        await refetch(filters, type: type)
    }

    /// Cancels in-flight fetches of matching keys, once the operations already queued on their
    /// clients have run. Rows already saved stay and states keep their previous value.
    public func cancel(_ filters: QueryFilter...) async {
        for client in liveClients(matching: filters) {
            await client.cancelFetch()
        }
    }

    /// Drops cached state: evicts matching keys' rows, deletes their stored state, and returns
    /// live clients to `.pending`. In-flight fetches are cancelled and waited for first, so rows
    /// they save are evicted too. Keys sharing a tag with a removed key are invalidated, except
    /// the keys removed with it.
    public func remove(_ filters: QueryFilter...) async {
        await remove(filters, refetchObserved: false)
    }

    /// Removes matching keys, then fetches the ones a view still shows once every key is removed,
    /// waiting for those fetches.
    public func reset(_ filters: QueryFilter...) async {
        await remove(filters, refetchObserved: true)
    }

    /// Evicts expired SWR caches of live clients that are unobserved and idle, and of every
    /// stored key without a client, using each record's stored cache time. Records of types no
    /// longer listed are deleted without `evict`; `.forever` records are kept.
    ///
    /// The provider already runs this at launch and whenever the app goes to the background;
    /// call it yourself only to clean up at another time.
    public func collectGarbage() async {
        var evicted = Evicted()
        for client in liveClients where await client.collectGarbage() {
            evicted.add(client.recordKey, tags: client.tagSet)
        }
        // Find expired keys first, then evict them as a write covering only those keys, so
        // clients created during the scan don't wait for it.
        let now = Date.now
        let found = await readStore { [liveKeys] store in
            await store.expiredKeys(except: liveKeys, now: now)
        }
        let expired = found.filter { !liveKeys.contains($0) }
        if !expired.isEmpty {
            evicted.formUnion(await writeStore(covering: expired.map(QueryFilter.init(key:)), evicts: true) { store in
                await store.evictExpired(expired, now: now)
            })
        }
        await invalidateShared(evicted)
    }

    // MARK: Matching

    /// Live clients matching any of `filters`, each once.
    private func liveClients(matching filters: [QueryFilter]) -> [any AnyQueryObserver] {
        liveClients.filter { client in
            filters.contains { $0.matches(key: client.recordKey, tags: client.tagSet) }
        }
    }

    private var liveKeys: Set<String> {
        Set(liveClients.map(\.recordKey))
    }

    /// Stored records without a live client matching any of `filters`, each once. Pending
    /// mutation markers never match.
    func storedRecords(matching filters: [QueryFilter], in context: ModelContext) -> [QueryRecord] {
        let liveKeys = liveKeys
        var seen = Set<String>()
        var records: [QueryRecord] = []
        for filter in filters {
            for record in (try? context.fetch(filter.descriptor())) ?? []
            where !liveKeys.contains(record.key) && !QueryRecord.Key.isMarker(record.key)
                && seen.insert(record.key).inserted {
                records.append(record)
            }
        }
        return records
    }

    func bookkeepingContext() -> ModelContext {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return context
    }

    // MARK: Store queue

    /// Runs `work` on the record store after every store operation queued before it.
    private func readStore<T: Sendable>(_ work: @escaping @Sendable (RecordStore) async -> T) async -> T {
        await writeStore(covering: [], evicts: false, work)
    }

    /// Runs `work` on the record store after every store operation queued before it. Until it
    /// finishes, a client created for a key `covering` matches waits for it before reading its
    /// record; with `evicts`, that client also starts `.pending` instead of showing the record.
    private func writeStore<T: Sendable>(
        covering filters: [QueryFilter],
        evicts: Bool,
        _ work: @escaping @Sendable (RecordStore) async -> T
    ) async -> T {
        let previous = storeTail
        let store = store
        let operation = Task {
            await previous?.value
            return await work(store)
        }
        let done = Task { _ = await operation.value }
        storeTail = done
        nextStoreWriteID &+= 1
        let id = nextStoreWriteID
        if !filters.isEmpty {
            pendingStoreWrites[id] = PendingStoreWrite(filters: filters, evicts: evicts, task: done)
        }
        let result = await operation.value
        pendingStoreWrites[id] = nil
        return result
    }

    /// Marks stored keys without a client as invalidated.
    private func markStoredInvalidated(_ filters: [QueryFilter], except excluded: Set<String> = []) async {
        guard !filters.isEmpty else { return }
        let excluded = excluded.union(liveKeys)
        await writeStore(covering: filters, evicts: false) { store in
            await store.markInvalidated(filters, except: excluded)
        }
    }

    // MARK: Invalidation

    /// Invalidates the keys that share a tag with evicted or removed keys, except those keys.
    /// Keys shown in a view start a fetch; this doesn't wait for it.
    func invalidateShared(tags: Set<String>, except keys: Set<String>) async {
        guard !tags.isEmpty else { return }
        let filters = tags.map { QueryFilter.tag($0) }
        for client in liveClients(matching: filters) where !keys.contains(client.recordKey) {
            client.invalidate()
            if client.isObserved {
                client.resync()
            }
        }
        await markStoredInvalidated(filters, except: keys)
    }

    /// Invalidates the keys sharing a tag with a batch of evicted keys, once for the whole batch,
    /// so keys evicted in the same batch don't start fetches and the store is scanned once.
    private func invalidateShared(_ evicted: Evicted) async {
        await invalidateShared(tags: evicted.tags, except: evicted.keys)
    }

    /// Whether an optimistic mutation whose remote call hasn't returned covers the client's key.
    func isCovered(_ client: any AnyQueryObserver) -> Bool {
        optimisticFilters.values.contains { filters in
            filters.contains { $0.matches(key: client.recordKey, tags: client.tagSet) }
        }
    }

    /// Holds every live client an in-flight optimistic mutation covers.
    func holdCoveredClients() {
        for client in liveClients where !client.isHeld && isCovered(client) {
            client.hold()
        }
    }

    /// Invalidates matching keys, then refetches the ones `type` selects with requests sent
    /// after this call, and waits for them. Stored keys without a client are marked invalidated;
    /// they refetch here only with `includesStored` and a `type` that includes inactive keys, so
    /// a mutation's broad filter can't start a fetch for every key ever cached.
    ///
    /// A key another in-flight optimistic mutation still covers doesn't refetch yet, so the
    /// server's older data can't overwrite that mutation's edit; it refetches when the last
    /// mutation covering it settles. Holds no mutation covers any more end here, and keys a sync
    /// wanted to fetch meanwhile refetch.
    func invalidateAndRefetch(_ filters: [QueryFilter], refetch type: QueryType?, includesStored: Bool = false) async {
        let clients = filters.isEmpty ? [] : liveClients(matching: filters)
        for client in clients {
            client.invalidate()
        }
        await markStoredInvalidated(filters)
        var targets: [any AnyQueryObserver] = []
        for client in clients where type?.includes(observed: client.isObserved) == true {
            if isCovered(client) {
                client.deferFetch()
            } else {
                targets.append(client)
            }
        }
        let targetKeys = Set(targets.map(\.recordKey))
        for client in liveClients where client.isHeld && !isCovered(client) {
            if await client.release(), !targetKeys.contains(client.recordKey) {
                targets.append(client)
            }
        }
        var refetches: [@MainActor () async -> Void] = targets.map { client in
            { await client.refetch() }
        }
        if includesStored, let type, type.includes(observed: false) {
            refetches += await storedRefreshes(matching: filters)
        }
        await withTaskGroup(of: Void.self) { group in
            for refetch in refetches {
                group.addTask { await refetch() }
            }
        }
        // The invalidations are saved once each client's queued operations have run.
        for client in clients {
            await client.settleOperations()
        }
    }

    private func refetch(_ filters: [QueryFilter], type: QueryType) async {
        // A key that was never fetched has nothing to refetch; one whose first fetch is in
        // flight is waited for and fetched again.
        var refetches: [@MainActor () async -> Void] = liveClients(matching: filters)
            .filter { type.includes(observed: $0.isObserved) && !$0.isUnfetched }
            .map { client in { await client.refetch() } }
        if type.includes(observed: false) {
            refetches += await storedRefreshes(matching: filters)
        }
        await withTaskGroup(of: Void.self) { group in
            for refetch in refetches {
                group.addTask { await refetch() }
            }
        }
    }

    /// Fetches for stored keys of listed types that match `filters`, have data and no client.
    private func storedRefreshes(matching filters: [QueryFilter]) async -> [@MainActor () async -> Void] {
        guard !filters.isEmpty else { return [] }
        let keys = await readStore { [liveKeys] store in
            await store.keysWithState(matching: filters, except: liveKeys)
        }
        return keys.compactMap { key in
            guard let entry = entries[QueryRecord.Key.typeName(of: key)] else { return nil }
            return { await entry.refresh(key, self) }
        }
    }

    /// Removes every matching key first, then invalidates the keys sharing their tags once, so
    /// keys removed together don't refetch each other. With `refetchObserved`, removed keys a
    /// view still shows fetch again last, and this waits for them.
    private func remove(_ filters: [QueryFilter], refetchObserved: Bool) async {
        var evicted = Evicted()
        let clients = liveClients(matching: filters)
        for client in clients where await client.remove() {
            evicted.add(client.recordKey, tags: client.tagSet)
        }
        let excluded = liveKeys
        evicted.formUnion(await writeStore(covering: filters, evicts: true) { store in
            await store.evict(matching: filters, except: excluded)
        })
        await invalidateShared(evicted)
        if refetchObserved {
            let resyncs: [@MainActor () async -> Void] = clients.map { client in
                { await client.resyncIfObserved() }
            }
            await withTaskGroup(of: Void.self) { group in
                for resync in resyncs {
                    group.addTask { await resync() }
                }
            }
        }
    }
}

/// A store write in progress, for making clients created meanwhile wait for it.
struct PendingStoreWrite {
    let filters: [QueryFilter]
    let evicts: Bool
    let task: Task<Void, Never>
}

/// A listed model or fetcher type, with what the provider needs for keys that have no client.
@MainActor
struct FetcherEntry {
    let name: String
    let validate: @MainActor (QueryProvider) -> Void
    /// Decodes the key and runs the type's `evict`. Does nothing if the key no longer decodes.
    let evict: RecordStore.Evictor
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

/// Selects keys for bulk operations and for the keys a mutation invalidates.
///
/// ```swift
/// .key(UserDetail(id: id))   // one fetcher key
/// .key(postsClient)          // a client's key
/// .type(User.self)           // a model's collection, or every key of a fetcher type
/// .tag("users")              // every key tagged "users"
/// .all                       // every key
/// ```
public struct QueryFilter: Hashable, Sendable, Codable {
    enum Selector: Hashable, Sendable, Codable {
        case key(String)
        case type(String)
        case tag(String)
        case all
    }

    let selector: Selector

    /// One record key.
    init(key: String) {
        selector = .key(key)
    }

    init(selector: Selector) {
        self.selector = selector
    }

    /// One fetcher key.
    public static func key<F: QueryFetcher>(_ fetcher: F) -> QueryFilter {
        QueryFilter(selector: .key(QueryRecord.Key.make(fetcher)))
    }

    /// The key a client syncs.
    @MainActor
    public static func key<F>(_ client: QueryObserver<F>) -> QueryFilter {
        QueryFilter(selector: .key(client.recordKey))
    }

    /// A model's collection, or every key of a fetcher type.
    public static func type(_ type: any Queryable.Type) -> QueryFilter {
        QueryFilter(selector: .type(String(reflecting: type)))
    }

    /// Every key whose `tags` contain `tag`.
    public static func tag(_ tag: String) -> QueryFilter {
        QueryFilter(selector: .tag(tag))
    }

    /// Every key.
    public static var all: QueryFilter {
        QueryFilter(selector: .all)
    }

    /// Whether the two filters may match a common key. Keys and types are compared; a tag or
    /// `.all` may match anything, since a filter alone doesn't say which keys a tag covers.
    func overlaps(_ other: QueryFilter) -> Bool {
        switch (selector, other.selector) {
        case (.key(let a), .key(let b)), (.type(let a), .type(let b)):
            a == b
        case (.key(let key), .type):
            other.matches(key: key, tags: [])
        case (.type, .key(let key)):
            matches(key: key, tags: [])
        default:
            true
        }
    }

    func matches(key: String, tags: Set<String>) -> Bool {
        switch selector {
        case .key(let match): key == match
        case .type(let name): key == name || key.hasPrefix(name + ":")
        case .tag(let tag): tags.contains(tag)
        case .all: true
        }
    }

    func descriptor() -> FetchDescriptor<QueryRecord> {
        switch selector {
        case .key(let key):
            return QueryRecord.descriptor(key: key)
        case .type(let name):
            let prefix = name + ":"
            return FetchDescriptor(predicate: #Predicate { $0.key == name || $0.key.starts(with: prefix) })
        case .tag(let tag):
            let needle = QueryRecord.Tags.needle(tag)
            return FetchDescriptor(predicate: #Predicate { $0.tags.contains(needle) })
        case .all:
            return FetchDescriptor()
        }
    }

    /// ``descriptor()`` limited to records that have state, checked by the store.
    func descriptorWithState() -> FetchDescriptor<QueryRecord> {
        switch selector {
        case .key(let key):
            return FetchDescriptor(predicate: #Predicate { $0.key == key && $0.stateData != nil })
        case .type(let name):
            let prefix = name + ":"
            return FetchDescriptor(predicate: #Predicate {
                ($0.key == name || $0.key.starts(with: prefix)) && $0.stateData != nil
            })
        case .tag(let tag):
            let needle = QueryRecord.Tags.needle(tag)
            return FetchDescriptor(predicate: #Predicate { $0.tags.contains(needle) && $0.stateData != nil })
        case .all:
            return FetchDescriptor(predicate: #Predicate { $0.stateData != nil })
        }
    }
}

/// Which matching keys ``QueryProvider/refetch(_:type:)`` fetches.
public enum QueryType: Sendable {
    /// Keys shown in a view.
    case active
    /// Every other key: live clients no view shows, and stored keys without a client.
    case inactive
    /// Both.
    case all

    func includes(observed: Bool) -> Bool {
        switch self {
        case .active: observed
        case .inactive: !observed
        case .all: true
        }
    }
}
