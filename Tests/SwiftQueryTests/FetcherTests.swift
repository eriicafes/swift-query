import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

@MainActor
@Suite("Fetchers")
struct FetcherTests {
    typealias DetailClient = ModelQueryClient<TestDetail>

    func makeRates(
        _ container: ModelContainer? = nil,
        rates: FakeRates = FakeRates(),
        gracePeriod: Duration = .seconds(300)
    ) throws -> (QueryProvider, FakeRates) {
        let provider = QueryProvider(
            modelContainer: try container ?? makeContainer(),
            contexts: rates as any RateSource,
            fetchers: TestStoredRate.self,
            gracePeriod: gracePeriod
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

    func observe<F: QueryFetcher>(_ client: ModelQueryClient<F>) async -> Subscription<F> {
        let subscription = Subscription<F>()
        subscription.activate(client, cache: nil)
        await client.settle()
        return subscription
    }

    // MARK: Keys

    @Test("Record keys are the type name, plus the fetcher as sorted JSON")
    func recordKeys() {
        #expect(QueryRecord.Key.make(ModelFetcher<TestUser>()) == String(reflecting: TestUser.self))
        #expect(QueryRecord.Key.make(TestDetail(id: "42")) == String(reflecting: TestDetail.self) + #":{"id":"42"}"#)
        #expect(QueryRecord.Key.make(TestRate(from: "USD", to: "EUR")) == String(reflecting: TestRate.self) + #":{"from":"USD","to":"EUR"}"#)
        #expect(QueryRecord.Key.decode(TestDetail.self, from: QueryRecord.Key.make(TestDetail(id: "42"))) == TestDetail(id: "42"))
    }

    @Test("Tags with commas and percent signs match exactly")
    func tagEncoding() throws {
        let tags: Set<String> = ["a,b", "50%", "plain"]
        #expect(QueryRecord.Tags.decode(QueryRecord.Tags.encode(tags)) == tags)

        let (provider, _, _) = try makeProvider()
        let context = ModelContext(provider.modelContainer)
        context.insert(QueryRecord(key: "x", tags: QueryRecord.Tags.encode(["a,b"])))
        context.insert(QueryRecord(key: "y", tags: QueryRecord.Tags.encode(["a"])))
        context.insert(QueryRecord(key: "z", tags: QueryRecord.Tags.encode(["A"])))
        try context.save()

        provider.invalidate(tag: "a")
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

        #expect(usd.status.value == 1)
        #expect(gbp.status.value == 2)
        #expect(await rates.requests == ["USD-EUR", "GBP-EUR"])
    }

    @Test("A fetcher without a cache keeps its state in memory only")
    func inMemoryCache() async throws {
        let (provider, rates) = try makeRates(gracePeriod: .zero)
        do {
            let client = provider.client(for: TestRate(from: "USD", to: "EUR"))
            let subscription = await observe(client)
            #expect(client.status.value == 1)

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

    @Test("Unused fetcher clients are dropped after the grace period; models are kept")
    func clientLifetime() async throws {
        let (provider, _, _) = try makeProvider(gracePeriod: .zero)
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
        let (provider, _, _) = try makeProvider(gracePeriod: .zero)
        let held = provider.client(for: TestDetail(id: "1"))
        for _ in 0..<10 { await Task.yield() }
        #expect(provider.client(for: TestDetail(id: "1")) === held)
    }

    @Test("Dropping a client cancels its stream")
    func dropCancelsStream() async throws {
        let (provider, _, server) = try makeProvider(streams: true, gracePeriod: .zero)
        weak var weakClient: DetailClient?
        do {
            let client = provider.client(for: TestDetail(id: "1"))
            weakClient = client
            let subscription = await observe(client)
            await eventually { await server.streamsStarted == 1 }
            _ = subscription
        }
        await eventually { weakClient == nil }
        await eventually { await server.streamsEnded == 1 }
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
        context.insert(QueryRecord(key: stored, stateData: Data("{}".utf8), lastSyncedAt: .now, tags: QueryRecord.Tags.encode(["users"])))
        try context.save()
        let fetches = await server.fetchCount

        provider.invalidate(tag: "user-1")
        await one.settle()
        #expect(await server.fetchCount == fetches + 1)
        #expect(one.status.isStale == false)

        provider.invalidate(tag: "users")
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

        provider.invalidate(TestDetail.self)
        await one.settle()
        await two.settle()
        #expect(one.status.isStale)
        #expect(two.status.isStale)
        #expect(provider.client(for: TestUser.self).status.isStale == false)
    }

    // MARK: Eviction and garbage collection

    @Test("Garbage collection evicts expired stored keys and invalidates shared tags")
    func sweepStoredKeys() async throws {
        let (provider, _, _) = try makeProvider(gracePeriod: .zero)
        do {
            await provider.client(for: TestDetail(id: "1")).refresh()
            await provider.client(for: TestDetail(id: "2")).refresh()
        }
        await eventually { provider.liveClients.count == 1 }
        #expect(try profiles(provider).count == 2)

        let expiredKey = QueryRecord.Key.make(TestDetail(id: "1"))
        let context = ModelContext(provider.modelContainer)
        try #require(try context.fetch(QueryRecord.descriptor(key: expiredKey)).first).cacheTime = 0
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
        context.insert(QueryRecord(key: "Gone.Fetcher:{}", stateData: Data(), lastSyncedAt: old, cacheTime: 0))
        context.insert(QueryRecord(key: String(reflecting: TestDetail.self) + ":{\"renamed\":1}", stateData: Data(), lastSyncedAt: old, cacheTime: 0))
        context.insert(QueryRecord(key: "Gone.Forever:{}", stateData: Data(), lastSyncedAt: old))
        try context.save()

        await provider.collectGarbage()
        let keys = try ModelContext(provider.modelContainer).fetch(FetchDescriptor<QueryRecord>()).map(\.key)
        #expect(keys.contains("Gone.Forever:{}"))
        #expect(!keys.contains("Gone.Fetcher:{}"))
        #expect(!keys.contains { $0.contains("renamed") })
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
        #expect(provider.status(for: TestStoredRate(from: "USD")).value == 1)
        #expect(provider.status(for: TestStoredRate(from: "GBP")).isPending)
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

        provider.invalidate(key)
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
        await eventually { provider.status(for: TestStoredRate(from: "USD")).value == 1 }
        #expect(await rates.requests.count == 1)
    }

    @Test("setState stores fresh state without fetching")
    func setState() async throws {
        let (provider, rates) = try makeRates()
        try await provider.setState(for: TestStoredRate(from: "USD"), 9.5)
        #expect(provider.status(for: TestStoredRate(from: "USD")).value == 9.5)
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
        provider.cancel(TestStoredRate.self)
        await provider.client(for: key).settleOperations()
        await rates.checkpoints.release("rate")

        await #expect(throws: CancellationError.self) { try await query.value }
        #expect(provider.status(for: key).value == 1)
    }

    @Test("remove evicts rows and state; keys sharing a tag are invalidated")
    func remove() async throws {
        let (provider, _, _) = try makeProvider()
        let one = provider.client(for: TestDetail(id: "1"))
        let two = provider.client(for: TestDetail(id: "2"))
        await one.refresh()
        await two.refresh()

        await provider.remove(TestDetail(id: "1"))
        await two.settle()
        #expect(one.status.isPending)
        #expect(try profiles(provider) == ["2": "Grace"])
        #expect(try record(provider, QueryRecord.Key.make(TestDetail(id: "1"))) == nil)
        #expect(two.status.isStale)
    }

    @Test("reset refetches keys a view still shows")
    func reset() async throws {
        let (provider, _, server) = try makeProvider()
        let one = provider.client(for: TestDetail(id: "1"))
        let subscription = await observe(one)
        let fetches = await server.fetchCount

        await provider.reset(tag: "user-1")
        await one.settle()
        #expect(await server.fetchCount == fetches + 1)
        #expect(try profiles(provider) == ["1": "Ada"])
        #expect(one.status.value != nil)
        _ = subscription
    }

    @Test("refetch with includeStored fetches stored keys that have no client")
    func refetchStored() async throws {
        let (provider, _, server) = try makeProvider(gracePeriod: .zero)
        do {
            await provider.client(for: TestDetail(id: "1")).refresh()
        }
        await eventually { provider.liveClients.count == 1 }
        let fetches = await server.fetchCount

        await provider.refetch(tag: "users")
        #expect(await server.fetchCount == fetches)

        await provider.refetch(tag: "users", includeStored: true)
        #expect(await server.fetchCount == fetches + 1)
    }

    @Test("Re-syncing after invalidation keeps a view's cache override")
    func resyncKeepsOverride() async throws {
        let (provider, client, _) = try makeProvider()
        let subscription = Subscription<ModelFetcher<TestUser>>()
        subscription.activate(client, cache: .swr(staleTime: .seconds(3600), cacheTime: .seconds(7)))
        await client.settle()

        provider.invalidate(TestUser.self)
        await client.settleOperations()
        await client.settle()
        #expect(try record(provider, TestUser.queryKey)?.cacheTime == 7)
        _ = subscription
    }
}
