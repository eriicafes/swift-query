import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

@MainActor
@Suite("Fetchers")
struct FetcherTests {
    typealias DetailClient = QueryObserver<TestDetail>

    func makeRates(
        _ container: ModelContainer? = nil,
        rates: FakeRates = FakeRates(),
        keepAliveTime: Duration = .seconds(300)
    ) throws -> (QueryProvider, FakeRates) {
        let provider = QueryProvider(
            modelContainer: try container ?? makeContainer(),
            contexts: rates as any RateSource,
            fetchers: TestStoredRate.self,
            keepAliveTime: keepAliveTime
        )
        return (provider, rates)
    }

    func profiles(_ provider: QueryProvider) throws -> [String: String] {
        let rows = try provider.modelContainer.mainContext.fetch(FetchDescriptor<TestProfile>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.userID, $0.bio) })
    }

    func record(_ provider: QueryProvider, _ key: String) throws -> QueryRecord? {
        try ModelContext(provider.modelContainer).fetch(QueryRecord.descriptor(key: key)).first
    }

    func observe<F: QueryFetcher>(_ client: QueryObserver<F>) async -> Subscription<F> {
        let subscription = Subscription<F>()
        subscription.activate(client, cache: nil)
        await client.settle()
        return subscription
    }

    // MARK: Keys

    @Test("Record keys are a JSON array of the type name and, for a fetcher, its value with sorted keys")
    func recordKeys() {
        let user = String(reflecting: TestUser.self)
        let detail = String(reflecting: TestDetail.self)
        let rate = String(reflecting: TestRate.self)
        #expect(QueryRecord.Key.make(ModelFetcher<TestUser>()) == #"[""# + user + #""]"#)
        #expect(QueryRecord.Key.make(TestDetail(id: "42")) == #"[""# + detail + #"",{"id":"42"}]"#)
        #expect(QueryRecord.Key.make(TestRate(from: "USD", to: "EUR")) == #"[""# + rate + #"",{"from":"USD","to":"EUR"}]"#)
        #expect(QueryRecord.Key.decode(TestDetail.self, from: QueryRecord.Key.make(TestDetail(id: "42"))) == TestDetail(id: "42"))
        #expect(QueryRecord.Key.decode(ModelFetcher<TestUser>.self, from: QueryRecord.Key.make(ModelFetcher<TestUser>())) != nil)
        // A key only decodes as the type it names.
        #expect(QueryRecord.Key.decode(ModelFetcher<TestPost>.self, from: QueryRecord.Key.make(ModelFetcher<TestUser>())) == nil)
        #expect(QueryRecord.Key.decode(TestDetail.self, from: QueryRecord.Key.make(ModelFetcher<TestUser>())) == nil)
        #expect(QueryRecord.Key.decode(ModelFetcher<TestUser>.self, from: #"[""# + user + #"",{}]"#) == nil)
    }

    @Test("Tags with commas and percent signs match exactly")
    func tagEncoding() async throws {
        let tags: Set<String> = ["a,b", "50%", "plain"]
        #expect(QueryRecord.Tags.decode(QueryRecord.Tags.encode(tags)) == tags)

        let (provider, _, _) = try makeProvider()
        let context = ModelContext(provider.modelContainer)
        context.insert(QueryRecord(key: "x", type: "T", tags: QueryRecord.Tags.encode(["a,b"])))
        context.insert(QueryRecord(key: "y", type: "T", tags: QueryRecord.Tags.encode(["a"])))
        context.insert(QueryRecord(key: "z", type: "T", tags: QueryRecord.Tags.encode(["A"])))
        try context.save()

        await provider.invalidate(.tag("a"))
        let invalidated = try ModelContext(provider.modelContainer)
            .fetch(FetchDescriptor<QueryRecord>(predicate: #Predicate { $0.invalidated }))
            .map(\.key)
        #expect(invalidated == ["y"])
    }

    // MARK: Fetcher state

    @Test("Each fetcher value is its own key with its own state")
    func keyedState() async throws {
        let (provider, rates) = try makeRates()
        let usd = provider.client(for: TestRate(from: "USD", to: "EUR"))
        let gbp = provider.client(for: TestRate(from: "GBP", to: "EUR"))
        await usd.refresh()
        await gbp.refresh()

        #expect(usd.data == 1)
        #expect(gbp.data == 2)
        #expect(await rates.requests == ["USD-EUR", "GBP-EUR"])
    }

    @Test("A fetcher without a cache keeps its state in memory only")
    func inMemoryCache() async throws {
        let (provider, rates) = try makeRates(keepAliveTime: .zero)
        do {
            let client = provider.client(for: TestRate(from: "USD", to: "EUR"))
            let subscription = await observe(client)
            #expect(client.data == 1)

            client.sync()
            await client.settle()
            #expect(await rates.requests.count == 1)
            _ = subscription
        }
        #expect(try ModelContext(provider.modelContainer).fetch(FetchDescriptor<QueryRecord>()).isEmpty)

        // Once dropped, the next use fetches again.
        await eventually { provider.liveClients.isEmpty }
        #expect(try await provider.query(TestRate(from: "USD", to: "EUR")) == 2)
    }

    // MARK: Client lifetime

    @Test("Unused fetcher clients are dropped after the keep-alive time; models are kept")
    func clientLifetime() async throws {
        let (provider, _, _) = try makeProvider(keepAliveTime: .zero)
        weak var detail: DetailClient?
        weak var users: UsersClient?
        do {
            detail = provider.client(for: TestDetail(id: "1"))
            users = provider.client(for: TestUser.self)
        }
        await eventually { detail == nil }
        #expect(users != nil)
    }

    @Test("A client someone still holds is reused, never duplicated")
    func heldClientReused() async throws {
        let (provider, _, _) = try makeProvider(keepAliveTime: .zero)
        let held = provider.client(for: TestDetail(id: "1"))
        for _ in 0..<10 { await Task.yield() }
        #expect(provider.client(for: TestDetail(id: "1")) === held)
    }

    @Test("Dropping a client cancels its subscription")
    func dropCancelsSubscription() async throws {
        let (provider, _, server) = try makeProvider(subscribes: true, keepAliveTime: .zero)
        weak var weakClient: DetailClient?
        do {
            let client = provider.client(for: TestDetail(id: "1"))
            weakClient = client
            let subscription = await observe(client)
            await eventually { await server.subscriptionsStarted == 1 }
            _ = subscription
        }
        await eventually { weakClient == nil }
        await eventually { await server.subscriptionsEnded == 1 }
    }

    // MARK: Invalidation

    @Test("Invalidating a tag marks live and stored keys, and re-syncs observed ones")
    func invalidateByTag() async throws {
        let (provider, _, server) = try makeProvider()
        let one = provider.client(for: TestDetail(id: "1"))
        let subscription = await observe(one)
        await provider.client(for: TestDetail(id: "2")).refresh()
        provider.client(for: TestDetail(id: "2")).invalidate()
        await provider.client(for: TestDetail(id: "2")).settle()
        let stored = QueryRecord.Key.make(TestDetail(id: "3"))
        let context = ModelContext(provider.modelContainer)
        context.insert(QueryRecord(key: stored, type: String(reflecting: TestDetail.self), stateData: Data("{}".utf8), lastSyncedAt: .now, tags: QueryRecord.Tags.encode(["users"])))
        try context.save()
        let fetches = await server.fetchCount

        await provider.invalidate(.tag("user-1"))
        await one.settle()
        #expect(await server.fetchCount == fetches + 1)
        #expect(one.state.isStale == false)

        await provider.invalidate(.tag("users"))
        #expect(try record(provider, stored)?.invalidated == true)
        _ = subscription
    }

    @Test("Invalidating a type covers every key of it")
    func invalidateByType() async throws {
        let (provider, _, _) = try makeProvider()
        let one = provider.client(for: TestDetail(id: "1"))
        let two = provider.client(for: TestDetail(id: "2"))
        await one.refresh()
        await two.refresh()

        await provider.invalidate(.type(TestDetail.self))
        await one.settle()
        await two.settle()
        #expect(one.state.isStale)
        #expect(two.state.isStale)
        #expect(provider.client(for: TestUser.self).state.isStale == false)
    }

    @Test("invalidate waits for a request sent after it, even with a fetch in flight")
    func invalidateDuringFetch() async throws {
        let (provider, client, server) = try makeProvider()
        let subscription = await observe(client)
        await server.checkpoints.hold("fetch")
        client.sync(.forever(refreshAfter: .zero))
        await server.checkpoints.reached("fetch", count: 2)

        let invalidation = Task { await provider.invalidate(.type(TestUser.self)) }
        await eventually { client.state.isStale }
        await server.checkpoints.release("fetch")
        await invalidation.value

        // The fetch in flight may predate the change; a new one replaces it.
        #expect(await server.fetchCount == 3)
        #expect(client.state.isStale == false)
        _ = subscription
    }

    @Test("invalidate with refetch nil marks keys without fetching")
    func invalidateWithoutRefetch() async throws {
        let (provider, client, server) = try makeProvider()
        let subscription = await observe(client)
        let fetches = await server.fetchCount

        await provider.invalidate(.type(TestUser.self), refetch: nil)
        await client.settle()
        #expect(client.state.isStale)
        #expect(await server.fetchCount == fetches)
        _ = subscription
    }

    @Test("invalidate with refetch .inactive fetches stored keys without a client")
    func invalidateInactive() async throws {
        let (provider, _, server) = try makeProvider()
        await provider.waitForGarbageCollection()
        let stored = QueryRecord.Key.make(TestDetail(id: "3"))
        let context = ModelContext(provider.modelContainer)
        context.insert(QueryRecord(
            key: stored, type: String(reflecting: TestDetail.self),
            stateData: try JSONEncoder().encode(TestDetail.QueryData(version: 0)),
            lastSyncedAt: .now, tags: QueryRecord.Tags.encode(["users"])
        ))
        try context.save()

        await provider.invalidate(.tag("users"), refetch: .inactive)
        #expect(await server.fetchCount == 1)
        #expect(try record(provider, stored)?.invalidated == false)
        #expect(provider.getQueryState(for: TestDetail(id: "3")).isStale == false)
    }

    @Test("refetch waits for a fetch in flight, then sends a new request")
    func refetchAfterInFlight() async throws {
        let (provider, client, server) = try makeProvider()
        let subscription = await observe(client)
        await server.checkpoints.hold("fetch")
        client.sync(.forever(refreshAfter: .zero))
        await server.checkpoints.reached("fetch", count: 2)

        let refetch = Task { await provider.refetch(.type(TestUser.self)) }
        for _ in 0..<50 { await Task.yield() }
        await server.checkpoints.release("fetch")
        await refetch.value
        #expect(await server.fetchCount == 3)
        _ = subscription
    }

    @Test("reset waits for keys shown in a view to fetch again")
    func resetWaits() async throws {
        let (provider, client, server) = try makeProvider()
        let subscription = await observe(client)

        await provider.reset(.type(TestUser.self))
        #expect(client.data == .init(etag: 2))
        #expect(await server.fetchCount == 2)
        _ = subscription
    }

    // MARK: Eviction and garbage collection

    @Test("Garbage collection evicts expired stored keys and invalidates shared tags")
    func sweepStoredKeys() async throws {
        let (provider, _, _) = try makeProvider(keepAliveTime: .zero)
        do {
            await provider.client(for: TestDetail(id: "1")).refresh()
            await provider.client(for: TestDetail(id: "2")).refresh()
        }
        await eventually { provider.liveClients.count == 1 }
        #expect(try profiles(provider).count == 2)

        let expiredKey = QueryRecord.Key.make(TestDetail(id: "1"))
        let context = ModelContext(provider.modelContainer)
        try #require(try context.fetch(QueryRecord.descriptor(key: expiredKey)).first).gcTime = 0
        try context.save()

        await provider.collectGarbage()
        #expect(try profiles(provider) == ["2": "Grace"])
        #expect(try record(provider, expiredKey) == nil)
        #expect(try record(provider, QueryRecord.Key.make(TestDetail(id: "2")))?.invalidated == true)
    }

    @Test("Garbage collection deletes records of unlisted types and undecodable keys")
    func sweepUnknownRecords() async throws {
        let (provider, _, _) = try makeProvider()
        let context = ModelContext(provider.modelContainer)
        let old = Date.now.addingTimeInterval(-10)
        context.insert(QueryRecord(key: #"["Gone.Fetcher",{}]"#, type: "Gone.Fetcher", stateData: Data(), lastSyncedAt: old, gcTime: 0))
        context.insert(QueryRecord(key: #"[""# + String(reflecting: TestDetail.self) + #"",{"renamed":1}]"#, type: String(reflecting: TestDetail.self), stateData: Data(), lastSyncedAt: old, gcTime: 0))
        context.insert(QueryRecord(key: #"["Gone.Forever",{}]"#, type: "Gone.Forever", stateData: Data(), lastSyncedAt: old))
        try context.save()

        await provider.collectGarbage()
        let keys = try ModelContext(provider.modelContainer).fetch(FetchDescriptor<QueryRecord>()).map(\.key)
        #expect(keys.contains(#"["Gone.Forever",{}]"#))
        #expect(!keys.contains(#"["Gone.Fetcher",{}]"#))
        #expect(!keys.contains { $0.contains("renamed") })
    }

    @Test("A client created while its key is being evicted waits for the eviction")
    func clientWaitsForEviction() async throws {
        let container = try makeContainer()
        let provider = QueryProvider(modelContainer: container, contexts: TestUser.Context(server: FakeServer()), fetchers: TestSlowEvict.self)
        await provider.waitForGarbageCollection()
        let key = TestSlowEvict()
        let context = ModelContext(container)
        context.insert(TestProfile(userID: "slow", bio: "old"))
        context.insert(QueryRecord(key: QueryRecord.Key.make(key), type: String(reflecting: TestSlowEvict.self), stateData: try JSONEncoder().encode(41), lastSyncedAt: .now))
        try context.save()

        let removal = Task { await provider.remove(.type(TestSlowEvict.self)) }
        await eventually { EvictLatch.shared.hasEntered }
        let client = provider.client(for: key)
        #expect(client.state.isPending)
        let query = Task { try await provider.query(key, staleTime: .infinite) }
        for _ in 0..<50 { await Task.yield() }
        EvictLatch.shared.release()
        await removal.value

        // The fetch ran after the eviction, so its row survives and its data is fresh.
        #expect(try await query.value == 1)
        let bios = try ModelContext(container).fetch(FetchDescriptor<TestProfile>()).map(\.bio)
        #expect(bios == ["fetched"])
    }

    @Test("One type's failing evict doesn't keep other keys removed with it")
    func batchEvictFailure() async throws {
        let container = try makeContainer()
        let server = FakeServer()
        let provider = QueryProvider(
            modelContainer: container,
            contexts: TestUser.Context(server: server), TestNote.Context(server: server),
            fetchers: TestNote.self, TestDetail.self
        )
        await provider.waitForGarbageCollection()
        let detail = QueryRecord.Key.make(TestDetail(id: "1"))
        let context = ModelContext(container)
        context.insert(TestProfile(userID: "1", bio: "Ada"))
        context.insert(QueryRecord(key: detail, type: String(reflecting: TestDetail.self), stateData: Data("{}".utf8), lastSyncedAt: .now))
        context.insert(QueryRecord(key: TestNote.queryKey, type: TestNote.queryType, stateData: Data("{}".utf8), lastSyncedAt: .now))
        try context.save()

        await provider.remove(.all)
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(QueryRecord.descriptor(key: detail)).isEmpty)
        #expect(try fresh.fetch(FetchDescriptor<TestProfile>()).isEmpty)
        #expect(try fresh.fetch(QueryRecord.descriptor(key: TestNote.queryKey)).first?.stateData == nil)
    }

    @Test("A client created while remove runs is removed with the rest")
    func removeCoversNewClients() async throws {
        let (provider, _, server) = try makeProvider()
        let fetching = provider.client(for: TestDetail(id: "1"))
        await fetching.refresh()
        let stored = QueryRecord.Key.make(TestDetail(id: "2"))
        let context = ModelContext(provider.modelContainer)
        context.insert(TestProfile(userID: "2", bio: "Grace"))
        context.insert(QueryRecord(
            key: stored, type: String(reflecting: TestDetail.self),
            stateData: try JSONEncoder().encode(TestDetail.QueryData(version: 1)),
            lastSyncedAt: .now, tags: QueryRecord.Tags.encode(["users"])
        ))
        try context.save()
        await server.checkpoints.hold("fetch")
        let refresh = Task { await fetching.refresh() }
        await server.checkpoints.reached("fetch", count: 2)

        let removal = Task { await provider.remove(.type(TestDetail.self)) }
        await server.checkpoints.reached("fetch-cancelled")
        // Created while remove waits for the first key's fetch to stop.
        let late = provider.client(for: TestDetail(id: "2"))
        await server.checkpoints.release("fetch")
        await refresh.value
        await removal.value

        #expect(late.state.isPending)
        #expect(try record(provider, stored) == nil)
        #expect(try profiles(provider)["2"] == nil)
    }

    @Test("Empty tags survive encoding")
    func emptyTag() {
        #expect(QueryRecord.Tags.decode(QueryRecord.Tags.encode([""])) == [""])
        #expect(QueryRecord.Tags.decode(QueryRecord.Tags.encode(["", "a"])) == ["", "a"])
        #expect(QueryRecord.Tags.decode("").isEmpty)
    }

    @Test("remove finishes when a fetch it stops queries another key it removes")
    func removeWithNestedQuery() async throws {
        let server = FakeServer()
        let ref = ProviderRef()
        let provider = QueryProvider(
            modelContainer: try makeContainer(),
            contexts: TestUser.Context(server: server), TestNested.Context(server: server, ref: ref),
            fetchers: TestDetail.self, TestNested.self
        )
        ref.provider = provider
        await provider.waitForGarbageCollection()
        let nested = provider.client(for: TestNested())
        await server.checkpoints.hold("nested")
        let refresh = Task { await nested.refresh() }
        await server.checkpoints.reached("nested")

        let done = Flag()
        Task {
            await provider.remove(.all)
            done.value = true
        }
        for _ in 0..<50 { await Task.yield() }
        // The fetch being stopped queries TestDetail(9), which remove also matches.
        await server.checkpoints.release("nested")
        await eventually { done.value }
        // On a deadlock, `eventually` has recorded the failure; don't wait forever for it.
        guard done.value else { return }
        await refresh.value
        #expect(provider.getQueryData(for: TestDetail(id: "9")) == nil)
    }

    @Test("A fetch cancelled through URLSession's error is still a cancel, not a failure")
    func urlErrorCancel() async throws {
        let (provider, rates) = try makeRates()
        await rates.useURLErrors()
        let key = TestStoredRate(from: "USD")
        try await provider.query(key)
        await rates.checkpoints.hold("rate")

        let query = Task { try await provider.query(key, staleTime: .after(.zero)) }
        await rates.checkpoints.reached("rate", count: 2)
        await provider.cancel(.type(TestStoredRate.self))
        await rates.checkpoints.release("rate")

        await #expect(throws: CancellationError.self) { try await query.value }
        #expect(provider.client(for: key).error == nil)
        #expect(provider.client(for: key).state.isStale == false)
    }

    // MARK: Provider methods

    @Test("state(for:) reads stored state without creating a client")
    func stateWithoutClient() async throws {
        let container = try makeContainer()
        do {
            let (provider, _) = try makeRates(container)
            try await provider.query(TestStoredRate(from: "USD"))
        }
        let (provider, rates) = try makeRates(container)
        #expect(provider.getQueryData(for: TestStoredRate(from: "USD")) == 1)
        #expect(provider.getQueryState(for: TestStoredRate(from: "GBP")).isPending)
        #expect(provider.liveClients.isEmpty)
        #expect(await rates.requests.isEmpty)
    }

    @Test("query returns fresh state, and fetches when stale under staleTime")
    func queryStaleTime() async throws {
        let (provider, rates) = try makeRates()
        let key = TestStoredRate(from: "USD")
        #expect(try await provider.query(key) == 1)
        #expect(try await provider.query(key) == 1)
        #expect(try await provider.query(key, staleTime: .infinite) == 1)
        #expect(try await provider.query(key, staleTime: .after(.zero)) == 2)

        await provider.invalidate(.key(key))
        #expect(try await provider.query(key, staleTime: .infinite) == 3)
        #expect(await rates.requests.count == 3)
    }

    @Test("query throws when its fetch fails")
    func queryThrows() async throws {
        let (provider, rates) = try makeRates()
        await rates.failNext()
        await #expect(throws: ServerError.self) {
            try await provider.query(TestStoredRate(from: "USD"))
        }
    }

    @Test("prefetch fills the cache without waiting")
    func prefetch() async throws {
        let (provider, rates) = try makeRates()
        provider.prefetch(TestStoredRate(from: "USD"))
        await eventually { provider.getQueryData(for: TestStoredRate(from: "USD")) == 1 }
        #expect(await rates.requests.count == 1)
    }

    @Test("setQueryData stores fresh data without fetching")
    func setQueryData() async throws {
        let (provider, rates) = try makeRates()
        try await provider.setQueryData(for: TestStoredRate(from: "USD"), 9.5)
        #expect(provider.getQueryData(for: TestStoredRate(from: "USD")) == 9.5)
        #expect(try await provider.query(TestStoredRate(from: "USD")) == 9.5)
        #expect(await rates.requests.isEmpty)
    }

    @Test("cancel stops an in-flight fetch and keeps the previous state")
    func cancelFetch() async throws {
        let (provider, rates) = try makeRates()
        let key = TestStoredRate(from: "USD")
        try await provider.query(key)
        await rates.checkpoints.hold("rate")

        let query = Task { try await provider.query(key, staleTime: .after(.zero)) }
        await rates.checkpoints.reached("rate", count: 2)
        await provider.cancel(.type(TestStoredRate.self))
        await provider.client(for: key).settleOperations()
        await rates.checkpoints.release("rate")

        await #expect(throws: CancellationError.self) { try await query.value }
        #expect(provider.getQueryData(for: key) == 1)
    }

    @Test("remove evicts rows and state; keys sharing a tag are invalidated")
    func remove() async throws {
        let (provider, _, _) = try makeProvider()
        let one = provider.client(for: TestDetail(id: "1"))
        let two = provider.client(for: TestDetail(id: "2"))
        await one.refresh()
        await two.refresh()

        await provider.remove(.key(TestDetail(id: "1")))
        await two.settle()
        #expect(one.state.isPending)
        #expect(try profiles(provider) == ["2": "Grace"])
        #expect(try record(provider, QueryRecord.Key.make(TestDetail(id: "1"))) == nil)
        #expect(two.state.isStale)
    }

    @Test("reset refetches keys a view still shows")
    func reset() async throws {
        let (provider, _, server) = try makeProvider()
        let one = provider.client(for: TestDetail(id: "1"))
        let subscription = await observe(one)
        let fetches = await server.fetchCount

        await provider.reset(.tag("user-1"))
        await one.settle()
        #expect(await server.fetchCount == fetches + 1)
        #expect(try profiles(provider) == ["1": "Ada"])
        #expect(one.data != nil)
        _ = subscription
    }

    @Test("Rows a fetch in flight writes don't reappear after remove", arguments: [false, true])
    func removeDuringFetch(fetcherSaves: Bool) async throws {
        let (provider, client, server) = try makeProvider(saves: fetcherSaves)
        client.sync()
        await client.settle()
        #expect(try localUsers(client).count == 2)

        await server.checkpoints.hold("fetch")
        client.sync(.forever(refreshAfter: .zero))
        await server.checkpoints.reached("fetch", count: 2)
        let removal = Task { await provider.remove(.type(TestUser.self)) }
        await server.checkpoints.reached("fetch-cancelled")
        await server.checkpoints.release("fetch")
        await removal.value
        await client.settle()

        #expect(try localUsers(client).isEmpty)
        #expect(client.state.isPending)
    }

    @Test("A cancelled fetch doesn't save the rows it inserted")
    func cancelledFetchUnsaved() async throws {
        let (provider, client, server) = try makeProvider(saves: false)
        client.sync()
        await client.settle()
        _ = try await server.rename(id: "1", to: "Changed")

        await server.checkpoints.hold("fetch")
        client.sync(.forever(refreshAfter: .zero))
        await server.checkpoints.reached("fetch", count: 2)
        await provider.cancel(.type(TestUser.self))
        await server.checkpoints.reached("fetch-cancelled")
        await server.checkpoints.release("fetch")
        await client.settle()

        // The fixture's batch delete reaches the store on its own; its inserts must not.
        #expect(!(try localUsers(client)).values.contains("Changed"))
        #expect(client.data == .init(etag: 1))
    }

    @Test("Keys removed together don't refetch each other through a shared tag")
    func removeSharedTag() async throws {
        let (provider, _, server) = try makeProvider()
        let one = provider.client(for: TestDetail(id: "1"))
        let two = provider.client(for: TestDetail(id: "2"))
        let subscriptions = (await observe(one), await observe(two))
        let fetches = await server.fetchCount

        await provider.remove(.tag("users"))
        await one.settle()
        await two.settle()
        #expect(await server.fetchCount == fetches)
        #expect(one.state.isPending)
        #expect(two.state.isPending)
        #expect(try profiles(provider).isEmpty)
        _ = subscriptions
    }

    @Test("reset refetches each shown key once, after every key is removed")
    func resetSharedTag() async throws {
        let (provider, _, server) = try makeProvider()
        let one = provider.client(for: TestDetail(id: "1"))
        let two = provider.client(for: TestDetail(id: "2"))
        let subscriptions = (await observe(one), await observe(two))
        let fetches = await server.fetchCount

        await provider.reset(.tag("users"))
        await one.settle()
        await two.settle()
        #expect(await server.fetchCount == fetches + 2)
        #expect(one.data != nil)
        #expect(two.data != nil)
        #expect(try profiles(provider) == ["1": "Ada", "2": "Grace"])
        _ = subscriptions
    }

    @Test("refetch with type .inactive or .all fetches stored keys that have no client")
    func refetchStored() async throws {
        let (provider, _, server) = try makeProvider(keepAliveTime: .zero)
        do {
            await provider.client(for: TestDetail(id: "1")).refresh()
        }
        await eventually { provider.liveClients.count == 1 }
        let fetches = await server.fetchCount

        await provider.refetch(.tag("users"))
        #expect(await server.fetchCount == fetches)

        await provider.refetch(.tag("users"), type: .all)
        #expect(await server.fetchCount == fetches + 1)
    }

    @Test("Re-syncing after invalidation keeps a view's cache override")
    func resyncKeepsOverride() async throws {
        let (provider, client, _) = try makeProvider()
        let subscription = Subscription<ModelFetcher<TestUser>>()
        subscription.activate(client, cache: .swr(staleTime: .seconds(3600), gcTime: .seconds(7)))
        await client.settle()

        await provider.invalidate(.type(TestUser.self))
        await client.settleOperations()
        await client.settle()
        #expect(try record(provider, TestUser.queryKey)?.gcTime == 7)
        _ = subscription
    }
}
