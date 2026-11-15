import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

@MainActor
@Suite("Sync")
struct SyncTests {
    @Test("Initial sync fetches and publishes success")
    func initialSync() async throws {
        let (_, client, server) = try makeProvider()
        #expect(client.status.isPending)

        client.sync()
        await client.settle()

        #expect(client.status.value == .init(etag: 1))
        #expect(client.status.isStale == false)
        #expect(client.fetchStatus == .idle)
        #expect(client.error == nil)
        #expect(await server.fetchCount == 1)
        #expect(try localUsers(client) == ["1": "Ada", "2": "Grace"])
    }

    @Test("Concurrent syncs and refreshes share one fetch")
    func deduplication() async throws {
        let (_, client, server) = try makeProvider()
        await server.checkpoints.hold("fetch")

        client.sync()
        client.sync()
        client.sync(.swr(staleTime: .seconds(30)))
        let a = Task { await client.refresh() }
        let b = Task { await client.refresh() }
        await server.checkpoints.reached("fetch")
        // Two syncs and two refreshes join the fetch the first sync started.
        await eventually { await client.fetchJoins() == 4 }

        await server.checkpoints.release("fetch")
        await a.value
        await b.value
        await client.settle()
        #expect(await server.fetchCount == 1)
    }

    @Test("Loading then fetching fetch statuses")
    func fetchStatuses() async throws {
        let (_, client, server) = try makeProvider()
        await server.checkpoints.hold("fetch")

        client.sync()
        await server.checkpoints.reached("fetch")
        #expect(client.fetchStatus == .loading)
        await server.checkpoints.release("fetch")
        await client.settle()

        await server.checkpoints.hold("fetch")
        let refresh = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        #expect(client.fetchStatus == .fetching)
        await server.checkpoints.release("fetch")
        await refresh.value
        #expect(client.fetchStatus == .idle)
    }

    @Test(".forever() reuses the cache; refresh() always fetches")
    func foreverCache() async throws {
        let (_, client, server) = try makeProvider()

        client.sync()
        await client.settle()
        client.sync()
        await client.settle()
        #expect(await server.fetchCount == 1)

        await client.refresh()
        #expect(await server.fetchCount == 2)
        #expect(client.status.value == .init(etag: 2))
    }

    @Test("refreshAfter makes data stale")
    func refreshAfter() async throws {
        let (_, client, server) = try makeProvider()

        client.sync(.forever(refreshAfter: .zero))
        await client.settle()
        client.sync(.forever(refreshAfter: .zero))
        await client.settle()
        #expect(await server.fetchCount == 2)

        client.sync(.forever(refreshAfter: .seconds(3600)))
        await client.settle()
        #expect(await server.fetchCount == 2)
    }

    @Test("Invalidation marks stale without fetching; next sync fetches")
    func invalidation() async throws {
        let (_, client, server) = try makeProvider()
        client.sync()
        await client.settle()

        client.invalidate()
        await client.settle()
        #expect(client.status.isStale)
        #expect(await server.fetchCount == 1)

        client.sync()
        await client.settle()
        #expect(await server.fetchCount == 2)
        #expect(client.status.isStale == false)
    }

    @Test("Invalidation during a fetch survives that fetch")
    func invalidationDuringFetch() async throws {
        let (_, client, server) = try makeProvider()
        await server.checkpoints.hold("fetch")

        client.sync()
        await server.checkpoints.reached("fetch")
        client.invalidate()
        await client.settleOperations()
        await server.checkpoints.release("fetch")
        await client.settle()
        #expect(client.status.isStale)

        client.sync()
        await client.settle()
        #expect(await server.fetchCount == 2)
        #expect(client.status.isStale == false)
    }

    @Test("Initial failure is an error; later failures keep stale success")
    func failures() async throws {
        let (_, client, server) = try makeProvider()

        await server.failNextFetch()
        client.sync()
        await client.settle()
        #expect(client.status.isError)
        #expect(client.error is ServerError)

        client.sync()
        await client.settle()
        #expect(client.status.value == .init(etag: 1))
        #expect(client.error == nil)

        await server.failNextFetch()
        await client.refresh()
        #expect(client.status.value == .init(etag: 1))
        #expect(client.status.isStale)
        #expect(client.error is ServerError)
        #expect(try localUsers(client) == ["1": "Ada", "2": "Grace"])
    }

    @Test("Sync state persists across providers")
    func persistence() async throws {
        let container = try makeContainer()
        let server = FakeServer()
        do {
            let (_, client, _) = try makeProvider(container, server: server)
            client.sync()
            await client.settle()
        }

        let (_, client, _) = try makeProvider(container, server: server)
        #expect(client.status.value == .init(etag: 1))

        client.sync()
        await client.settle()
        #expect(await server.fetchCount == 1)

        await client.refresh()
        #expect(await server.requestedEtags == [nil, 1])
    }

    @Test("A view starts the stream once; fetches alone never do")
    func subscribeOnAttach() async throws {
        let (_, client, server) = try makeProvider(streams: true)
        await client.refresh()
        #expect(await server.streamsStarted == 0)

        let first = Subscription<ModelFetcher<TestUser>>()
        let second = Subscription<ModelFetcher<TestUser>>()
        first.activate(client, cache: nil)
        second.activate(client, cache: nil)
        await client.settle()
        await client.refresh()
        await eventually { await server.streamsStarted == 1 }
        #expect(await client.subscriptions() == 1)
    }

    @Test("A cancelled stream restarts on the next sync from a view")
    func streamRestarts() async throws {
        let (_, client, server) = try makeProvider(streams: true)
        let subscription = Subscription<ModelFetcher<TestUser>>()
        subscription.activate(client, cache: nil)
        await client.settle()
        await eventually { await server.streamsStarted == 1 }

        client.cancelStream()
        await client.settleOperations()
        await eventually { await server.streamsEnded == 1 }
        #expect(await client.isStreaming() == false)

        // The scene becoming active again syncs, which restarts the stream.
        subscription.activate(client, cache: nil, phase: .background)
        subscription.activate(client, cache: nil, phase: .active)
        await client.settle()
        await eventually { await server.streamsStarted == 2 }
    }

    @Test("Expired SWR cache is evicted and refetched from default state")
    func swrExpiry() async throws {
        let (_, client, server) = try makeProvider()
        client.sync()
        await client.settle()

        client.sync(.swr(staleTime: .seconds(3600), cacheTime: .zero))
        await client.settle()

        #expect(await server.requestedEtags == [nil, nil])
        #expect(client.status.value == .init(etag: 2))
    }

    @Test("Observed caches are not evicted")
    func observedNotEvicted() async throws {
        let (_, client, server) = try makeProvider()
        let subscription = Subscription<ModelFetcher<TestUser>>()
        subscription.activate(client, cache: nil)
        subscription.activate(client, cache: nil)
        await client.settle()
        #expect(await server.fetchCount == 1)

        client.sync(.swr(staleTime: .seconds(3600), cacheTime: .zero))
        await client.settle()
        #expect(await server.fetchCount == 1)
    }

    @Test("Stored state that no longer decodes is treated as missing")
    func undecodableState() async throws {
        let container = try makeContainer()
        container.mainContext.insert(
            QueryRecord(key: TestUser.queryKey, stateData: Data("not json".utf8), lastSyncedAt: .now)
        )
        try container.mainContext.save()

        let (_, client, server) = try makeProvider(container)
        #expect(client.status.isPending)

        client.sync()
        await client.settle()
        #expect(await server.requestedEtags == [nil])
        #expect(client.status.value == .init(etag: 1))
    }

    @Test("Changes left unsaved by fetch are saved")
    func unsavedFetchChanges() async throws {
        let (_, client, _) = try makeProvider(saves: false)
        client.sync()
        await client.settle()
        #expect(try localUsers(client) == ["1": "Ada", "2": "Grace"])
    }

    @Test("Expiry is skipped while a fetch is in flight")
    func noEvictionDuringFetch() async throws {
        let (_, client, server) = try makeProvider()
        client.sync()
        await client.settle()
        await server.checkpoints.hold("fetch")

        let inFlight = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        client.sync(.swr(staleTime: .seconds(3600), cacheTime: .zero))
        await client.settleOperations()
        await server.checkpoints.release("fetch")
        await inFlight.value
        await client.settle()

        #expect(await server.requestedEtags == [nil, 1])
        #expect(try localUsers(client).count == 2)
    }

    @Test("Scene activation re-syncs; body re-evaluations don't")
    func sceneActivation() async throws {
        let (_, client, server) = try makeProvider()
        let subscription = Subscription<ModelFetcher<TestUser>>()
        let cache = QueryCache.forever(refreshAfter: .zero)

        subscription.activate(client, cache: cache, phase: .active)
        await client.settle()
        subscription.activate(client, cache: cache, phase: .active)
        subscription.activate(client, cache: cache, phase: .background)
        await client.settle()
        #expect(await server.fetchCount == 1)

        subscription.activate(client, cache: cache, phase: .active)
        await client.settle()
        #expect(await server.fetchCount == 2)
    }

    @Test("Duplicate query records collapse to the most recently synced")
    func duplicateRecords() async throws {
        let container = try makeContainer()
        let state = try JSONEncoder().encode(TestUser.State(etag: 5))
        container.mainContext.insert(QueryRecord(key: TestUser.queryKey))
        container.mainContext.insert(QueryRecord(key: TestUser.queryKey, stateData: state, lastSyncedAt: .now))
        try container.mainContext.save()

        let (_, client, server) = try makeProvider(container)
        client.sync()
        await client.settle()

        #expect(client.status.value == .init(etag: 5))
        #expect(await server.fetchCount == 0)
        let records = try container.mainContext.fetch(FetchDescriptor<QueryRecord>())
        #expect(records.count == 1)
    }

    @Test("Unchanged snapshots don't invalidate observers")
    func quietSnapshots() async throws {
        let (_, client, _) = try makeProvider()
        client.sync()
        await client.settle()

        let state = Flag(), error = Flag(), fetchStatus = Flag()
        withObservationTracking { _ = client.status } onChange: { state.value = true }
        withObservationTracking { _ = client.error } onChange: { error.value = true }
        withObservationTracking { _ = client.fetchStatus } onChange: { fetchStatus.value = true }
        client.sync()
        await client.settle()
        #expect(state.value == false)
        #expect(error.value == false)
        #expect(fetchStatus.value == false)
    }

    @Test("Access time is written at most once per resolution window")
    func throttledAccessWrites() async throws {
        let (_, client, _) = try makeProvider()
        client.sync()
        await client.settle()
        let accessedAt = {
            try ModelContext(client.modelContainer)
                .fetch(QueryRecord.descriptor(key: TestUser.queryKey)).first?.lastAccessedAt
        }
        let first = try accessedAt()
        #expect(first != nil)

        client.sync()
        await client.settle()
        #expect(try accessedAt() == first)
    }

    @Test("A failed eviction leaves the data and refetches it")
    func failedEviction() async throws {
        let server = FakeServer()
        let provider = QueryProvider(
            modelContainer: try makeContainer(),
            contexts: TestNote.Context(server: server),
            fetchers: TestNote.self
        )
        let client = provider.client(for: TestNote.self)
        await client.refresh()

        client.sync(.swr(staleTime: .seconds(3600), cacheTime: .zero))
        await client.settle()
        #expect(client.error is EvictionError)
        let notes = try client.modelContainer.mainContext.fetch(FetchDescriptor<TestNote>())
        #expect(notes.count == 1)

        client.sync()
        await client.settle()
        #expect(await server.requestedEtags == [nil, nil])
        #expect(client.status.value == .init(etag: 2))
    }
}
