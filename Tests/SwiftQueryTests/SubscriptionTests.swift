import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

/// A feed server with a live stream of sequence numbers.
actor FeedServer {
    /// Holds requests in flight until a test releases them. Keys: "fetch", "connect".
    nonisolated let checkpoints = Checkpoints()
    private(set) var requestedSeqs: [Int] = []
    private(set) var connects = 0
    /// How many streams have ended, by finishing or by their task being cancelled.
    private(set) var streamsEnded = 0
    /// The writer and subscription of the most recent stream that called `begin()`.
    private(set) var writer: QueryWriter<TestFeed.QueryData>?
    private(set) var subscription: QuerySubscription<TestFeed.Context, TestFeed.QueryData>?
    private var latest: Int
    private var fetchFailures = 0
    private var streams: [AsyncStream<Int>.Continuation] = []

    init(latest: Int = 3) {
        self.latest = latest
    }

    func failNextFetch() { fetchFailures += 1 }
    func failFetches(_ count: Int) { fetchFailures += count }
    func streamEnded() { streamsEnded += 1 }
    func setLatest(_ seq: Int) { latest = seq }

    func began(_ subscription: QuerySubscription<TestFeed.Context, TestFeed.QueryData>, _ writer: QueryWriter<TestFeed.QueryData>) {
        self.subscription = subscription
        self.writer = writer
    }

    /// Sends an event to every open stream.
    func publish(_ seq: Int) {
        latest = max(latest, seq)
        for stream in streams {
            stream.yield(seq)
        }
    }

    /// Ends every open stream, as a dropped connection would.
    func dropStreams() {
        for stream in streams {
            stream.finish()
        }
        streams = []
    }

    func latest(after seq: Int) async throws -> Int {
        requestedSeqs.append(seq)
        let snapshot = latest
        await checkpoints.pass("fetch")
        if fetchFailures > 0 {
            fetchFailures -= 1
            throw ServerError()
        }
        return snapshot
    }

    func connect() async -> AsyncStream<Int> {
        connects += 1
        await checkpoints.pass("connect")
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        continuation.onTermination = { _ in
            Task { await self.streamEnded() }
        }
        streams.append(continuation)
        return stream
    }
}

@Model
final class TestFeed {
    var seq: Int
    init(seq: Int) { self.seq = seq }
}

extension TestFeed: QueryModel {
    struct Context: Sendable {
        enum Mode: Sendable {
            /// Connects, calls `begin()`, and writes once synced.
            case live
            /// Returns without calling `begin()`.
            case none
        }

        let server: FeedServer
        var mode = Mode.live
    }

    struct QueryData: Codable, Equatable {
        var seq = 0
    }

    static var cache: QueryCache { .forever() }

    static func fetch(query: QueryFetch<Context, QueryData>) async throws -> QueryData {
        QueryData(seq: try await query.context.server.latest(after: query.previous?.seq ?? 0))
    }

    static func subscribe(query: QuerySubscription<Context, QueryData>) async throws {
        guard query.context.mode == .live else { return }
        let server = query.context.server
        let events = await server.connect()
        let writer = await query.begin()
        await server.began(query, writer)
        for await seq in events {
            try await writer.write { tx in
                guard seq > (tx.data?.seq ?? 0) else { return }  // already fetched
                tx.modelContext.insert(TestFeed(seq: seq))
                tx.data?.seq = seq
            }
        }
    }

    static func evict(query: QueryEvict<Context>) throws {
        try query.modelContext.delete(model: TestFeed.self)
    }
}

typealias FeedClient = QueryObserver<ModelFetcher<TestFeed>>

/// A fetcher key with the feed's stream, released after its keep-alive time like any fetcher.
struct TestFeedFetcher: QueryFetcher {
    var cache: QueryCache? { .forever() }

    func fetch(query: QueryFetch<TestFeed.Context, TestFeed.QueryData>) async throws -> TestFeed.QueryData {
        TestFeed.QueryData(seq: try await query.context.server.latest(after: query.previous?.seq ?? 0))
    }

    func subscribe(query: QuerySubscription<TestFeed.Context, TestFeed.QueryData>) async throws {
        let server = query.context.server
        let events = await server.connect()
        let writer = await query.begin()
        await server.began(query, writer)
        for await seq in events {
            try await writer.write { tx in tx.data?.seq = seq }
        }
    }
}

@MainActor
@Suite("Subscriptions")
struct SubscriptionTests {
    func makeFeed(
        server: FeedServer = FeedServer(),
        mode: TestFeed.Context.Mode = .live
    ) throws -> (QueryProvider, FeedClient, FeedServer) {
        let provider = QueryProvider(
            modelContainer: try makeContainer(),
            contexts: TestFeed.Context(server: server, mode: mode),
            fetchers: TestFeed.self
        )
        provider.streamBackoff = .milliseconds(10)
        return (provider, provider.client(for: TestFeed.self), server)
    }

    /// Shows the feed in a view and waits until its stream is synced.
    func connect(
        _ client: FeedClient,
        _ server: FeedServer,
        cache: QueryCache? = nil
    ) async throws -> (QueryWriter<TestFeed.QueryData>, Subscription<ModelFetcher<TestFeed>>) {
        let view = Subscription<ModelFetcher<TestFeed>>()
        view.activate(client, cache: cache)
        await eventually { await server.writer != nil }
        let writer = try #require(await server.writer)
        try await writer.synced()
        await client.settle()
        return (writer, view)
    }

    func rows(_ client: FeedClient) throws -> [Int] {
        try client.modelContainer.mainContext.fetch(FetchDescriptor<TestFeed>()).map(\.seq).sorted()
    }

    @Test("A view's first sync fetches once, after the stream connects")
    func coldStartFetchesOnce() async throws {
        let (_, client, server) = try makeFeed()
        await server.checkpoints.hold("connect")
        let view = Subscription<ModelFetcher<TestFeed>>()
        view.activate(client, cache: nil)
        await server.checkpoints.reached("connect")
        #expect(await server.requestedSeqs.isEmpty)

        await server.checkpoints.release("connect")
        await eventually { client.data == .init(seq: 3) }
        #expect(await server.requestedSeqs == [0])
        #expect(await client.subscriptions() == 1)
        _ = view
    }

    @Test("Events are written once synced, and events the fetch already has are skipped")
    func writesEvents() async throws {
        let (_, client, server) = try makeFeed()
        let (_, view) = try await connect(client, server)

        await server.publish(5)
        await eventually { client.data == .init(seq: 5) }
        #expect(try rows(client) == [5])

        await server.publish(4)
        await server.publish(6)
        await eventually { client.data == .init(seq: 6) }
        #expect(try rows(client) == [5, 6])
        _ = view
    }

    @Test("A write during a fetch waits for it and sees its result")
    func writeWaitsForFetch() async throws {
        let (_, client, server) = try makeFeed()
        let (_, view) = try await connect(client, server)
        await server.setLatest(7)
        await server.checkpoints.hold("fetch")

        let refresh = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        await server.publish(6)
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.data == .init(seq: 3))
        #expect(try rows(client).isEmpty)

        await server.checkpoints.release("fetch")
        await refresh.value
        await client.settle()
        // The fetch already had 6, so the waiting write skipped it.
        #expect(client.data == .init(seq: 7))
        #expect(try rows(client).isEmpty)
        _ = view
    }

    @Test("begin() during a fetch that started earlier waits for a fetch that starts after it")
    func beginDuringFetch() async throws {
        let (_, client, server) = try makeFeed()
        await server.checkpoints.hold("fetch")
        let refresh = Task { await client.refresh() }
        await server.checkpoints.reached("fetch")

        let view = Subscription<ModelFetcher<TestFeed>>()
        view.activate(client, cache: nil)
        await eventually { await server.writer != nil }
        await server.checkpoints.release("fetch")
        await refresh.value

        let writer = try #require(await server.writer)
        try await writer.synced()
        #expect(await server.requestedSeqs.count == 2)
        _ = view
    }

    @Test("A failed begin() fetch holds writes and is retried")
    func beginFetchRetries() async throws {
        let (_, client, server) = try makeFeed()
        await server.failNextFetch()
        let view = Subscription<ModelFetcher<TestFeed>>()
        view.activate(client, cache: nil)
        await eventually { await server.writer != nil }
        let writer = try #require(await server.writer)

        try await writer.synced()
        #expect(await server.requestedSeqs.count == 2)
        #expect(client.data == .init(seq: 3))
        _ = view
    }

    @Test("A begin() fetch retry waits for an optimistic mutation's hold, then runs after it settles")
    func beginRetryDuringHold() async throws {
        let (provider, client, server) = try makeFeed()
        // Stored data, so the mutation's hold keeps syncs from fetching the key.
        await client.refresh()
        await server.checkpoints.hold("fetch")
        let view = Subscription<ModelFetcher<TestFeed>>()
        view.activate(client, cache: nil)
        await server.checkpoints.reached("fetch", count: 2)

        let gate = Checkpoints()
        await gate.hold("mutation")
        let mutation = Task {
            try await provider.mutate(
                invalidates: [.type(TestFeed.self)],
                { await gate.pass("mutation") },
                optimistic: { _ in }
            )
        }
        await gate.reached("mutation")

        // The begin() fetch fails while the key is held; its retry must not fetch.
        await server.failNextFetch()
        await server.checkpoints.release("fetch")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.requestedSeqs.count == 2)
        let writer = try #require(await server.writer)
        let syncedDuringHold = try await writer.write(.now) { tx in tx.isSynced }
        #expect(syncedDuringHold == false)

        await gate.release("mutation")
        try await mutation.value
        try await writer.synced()
        #expect(await server.requestedSeqs.count == 3)
        #expect(client.data == .init(seq: 3))
        _ = view
    }

    @Test("Once synced, a failed refetch lets writes resume")
    func failedRefetchKeepsSync() async throws {
        let (_, client, server) = try makeFeed()
        let (_, view) = try await connect(client, server)
        await server.failNextFetch()
        await client.refresh()
        #expect(client.error is ServerError)

        await server.publish(9)
        await eventually { client.data == .init(seq: 9) }
        #expect(try rows(client) == [9])
        _ = view
    }

    @Test("A write that doesn't wait runs during a fetch, whose result then wins for the data")
    func writeNow() async throws {
        let (_, client, server) = try makeFeed()
        let (writer, view) = try await connect(client, server)
        await server.checkpoints.hold("fetch")
        let refresh = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)

        let wasSynced = try await writer.write(.now) { tx in
            tx.modelContext.insert(TestFeed(seq: 50))
            tx.data?.seq = 50
            return tx.isSynced
        }
        #expect(wasSynced == false)
        #expect(client.data == .init(seq: 50))

        await server.checkpoints.release("fetch")
        await refresh.value
        #expect(client.data == .init(seq: 3))
        // Rows only the write touched stay.
        #expect(try rows(client) == [50])
        _ = view
    }

    @Test("A write that throws leaves rows and data unchanged")
    func throwingWrite() async throws {
        let (_, client, server) = try makeFeed()
        let (writer, view) = try await connect(client, server)

        await #expect(throws: ServerError.self) {
            try await writer.write { tx in
                tx.modelContext.insert(TestFeed(seq: 60))
                tx.data?.seq = 60
                throw ServerError()
            }
        }
        #expect(client.data == .init(seq: 3))
        #expect(try rows(client).isEmpty)
        _ = view
    }

    @Test("A stream that ends while shown restarts, and its begin() fetches what was missed")
    func streamRestarts() async throws {
        let (_, client, server) = try makeFeed()
        let (_, view) = try await connect(client, server)
        await server.dropStreams()
        await server.setLatest(12)

        await eventually { await server.connects == 2 }
        await eventually { client.data == .init(seq: 12) }
        #expect(await server.requestedSeqs == [0, 3])
        _ = view
    }

    @Test("A stream that returns without begin() means no live updates")
    func noLiveUpdates() async throws {
        let (_, client, server) = try makeFeed(mode: .none)
        let view = Subscription<ModelFetcher<TestFeed>>()
        view.activate(client, cache: nil)
        await eventually { client.data == .init(seq: 3) }
        await client.settle()
        #expect(await server.requestedSeqs == [0])
        #expect(await client.subscriptions() == 0)
        #expect(await client.isSubscribed() == false)
        _ = view
    }

    @Test("Staleness doesn't refetch while a stream is synced; invalidation does")
    func staleWhileSubscribed() async throws {
        let (provider, client, server) = try makeFeed()
        let cache = QueryCache.swr(staleTime: .zero)
        let (_, view) = try await connect(client, server, cache: cache)

        view.activate(client, cache: cache, phase: .background)
        view.activate(client, cache: cache, phase: .active)
        await client.settle()
        #expect(await server.requestedSeqs.count == 1)
        #expect(client.state.isStale == false)

        await provider.invalidate(.type(TestFeed.self))
        #expect(await server.requestedSeqs.count == 2)
        _ = view
    }

    @Test("A write reads rows as the store has them, not as an earlier write left them")
    func writeReadsCurrentRows() async throws {
        let (_, client, server) = try makeFeed()
        let (writer, view) = try await connect(client, server)
        try await writer.write { tx in tx.modelContext.insert(TestFeed(seq: 5)) }

        // Another context, such as a fetch's, changes the row.
        let other = ModelContext(client.modelContainer)
        let row = try #require(try other.fetch(FetchDescriptor<TestFeed>()).first)
        row.seq = 8
        try other.save()

        let seen = try await writer.write { tx in
            try tx.modelContext.fetch(FetchDescriptor<TestFeed>()).map(\.seq)
        }
        #expect(seen == [8])
        _ = view
    }

    @Test("query() doesn't refetch data a synced stream keeps current")
    func queryWhileLive() async throws {
        let (_, client, server) = try makeFeed()
        let (_, view) = try await connect(client, server, cache: .swr(staleTime: .zero))
        #expect(try await client.query(staleTime: nil) == .init(seq: 3))
        #expect(await server.requestedSeqs.count == 1)
        _ = view
    }

    @Test("When a synced stream stops, the key shows stale again")
    func staleAfterStreamStops() async throws {
        let (_, client, server) = try makeFeed()
        let (_, view) = try await connect(client, server, cache: .swr(staleTime: .zero))
        #expect(client.state.isStale == false)

        client.unsubscribe()
        await eventually { client.state.isStale }
        _ = view
    }

    @Test("A second begin() doesn't fetch again")
    func beginTwice() async throws {
        let (_, client, server) = try makeFeed()
        let (_, view) = try await connect(client, server)
        let subscription = try #require(await server.subscription)
        _ = await subscription.begin()
        await client.settle()
        #expect(await server.requestedSeqs.count == 1)
        _ = view
    }

    @Test("Removing the key cancels a waiting write and evicts its rows")
    func removeDuringWrite() async throws {
        let (provider, client, server) = try makeFeed()
        let (writer, view) = try await connect(client, server)
        await server.checkpoints.hold("fetch")
        let refresh = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)

        let write = Task {
            try await writer.write { tx in tx.modelContext.insert(TestFeed(seq: 77)) }
        }
        let remove = Task { await provider.remove(.type(TestFeed.self)) }
        await #expect(throws: CancellationError.self) { try await write.value }

        await server.checkpoints.release("fetch")
        await refresh.value
        await remove.value
        #expect(try rows(client).isEmpty)
        _ = view
    }

    @Test("Cancelling the begin() fetch stops that request, and the stream syncs after a backoff")
    func cancelBeginFetch() async throws {
        let (provider, client, server) = try makeFeed()
        await server.checkpoints.hold("fetch")
        let view = Subscription<ModelFetcher<TestFeed>>()
        view.activate(client, cache: nil)
        await server.checkpoints.reached("fetch")

        await provider.cancel(.type(TestFeed.self))
        await server.checkpoints.release("fetch")
        await client.settle()
        // The cancelled request stays stopped; the stream syncs with a retry after a backoff.
        #expect(await server.requestedSeqs.count == 1)
        #expect(client.state.isPending)
        await eventually { client.data == .init(seq: 3) }
        #expect(await server.requestedSeqs.count == 2)
        _ = view
    }

    @Test("A write waiting for sync stops when its own task is cancelled")
    func cancelWaitingWrite() async throws {
        let (_, client, server) = try makeFeed()
        let (writer, view) = try await connect(client, server)
        await server.checkpoints.hold("fetch")
        let refresh = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)

        let stopped = Flag()
        let write = Task {
            do {
                try await writer.write { tx in tx.modelContext.insert(TestFeed(seq: 70)) }
            } catch is CancellationError {
                stopped.value = true
            }
        }
        await eventually { await client.waitingWrites() == 1 }
        write.cancel()
        // Stops before the fetch it was waiting for finishes.
        await eventually { stopped.value }

        await server.checkpoints.release("fetch")
        await refresh.value
        #expect(try rows(client).isEmpty)
        _ = view
    }

    @Test("Removing a key whose view waits for begin() starts no fetch")
    func removeBeforeBegin() async throws {
        let (provider, client, server) = try makeFeed()
        await server.checkpoints.hold("connect")
        let view = Subscription<ModelFetcher<TestFeed>>()
        view.activate(client, cache: nil)
        await server.checkpoints.reached("connect")

        let remove = Task { await provider.remove(.type(TestFeed.self)) }
        for _ in 0..<50 { await Task.yield() }
        await server.checkpoints.release("connect")
        await remove.value
        await client.settle()
        #expect(await client.fetchStarts() == 0)
        #expect(await server.requestedSeqs.isEmpty)
        _ = view
    }

    @Test("reset waits for a streaming key to fetch again, from nothing rather than the evicted cursor")
    func resetStreamingKey() async throws {
        let (provider, client, server) = try makeFeed()
        let (_, view) = try await connect(client, server)
        #expect(await server.requestedSeqs == [0])

        await provider.reset(.type(TestFeed.self))
        #expect(client.data == .init(seq: 3))
        #expect(await server.requestedSeqs == [0, 0])
        _ = view
    }

    @Test("A released fetcher key stops its stream, even while a write waits for sync")
    func releasedKeyStopsStream() async throws {
        let server = FeedServer()
        let provider = QueryProvider(
            modelContainer: try makeContainer(),
            contexts: TestFeed.Context(server: server),
            fetchers: TestFeedFetcher.self,
            keepAliveTime: .milliseconds(20)
        )
        provider.streamBackoff = .milliseconds(10)
        await server.failFetches(1_000)
        do {
            let client = provider.client(for: TestFeedFetcher())
            client.attach(nil)
            await eventually { await server.writer != nil }
            // The begin() fetch keeps failing, so this event's write waits for sync.
            await server.publish(5)
            client.detach()
        }
        await eventually { await server.streamsEnded == 1 }
    }

    @Test("The expiry check when a view returns doesn't evict a key whose stream is running")
    func expiryKeepsLiveStream() async throws {
        let (_, client, server) = try makeFeed()
        let (_, view) = try await connect(client, server, cache: .swr(staleTime: .seconds(3600), gcTime: .zero))
        await server.publish(5)
        await eventually { client.data == .init(seq: 5) }
        client.detach()
        client.attach(.swr(staleTime: .seconds(3600), gcTime: .zero))
        await client.settle()

        #expect(try rows(client) == [5])
        #expect(await client.subscriptions() == 1)
        client.detach()
        _ = view
    }

    @Test("A key with a running stream isn't garbage-collected")
    func liveStreamNotCollected() async throws {
        let (_, client, server) = try makeFeed()
        do {
            let (_, view) = try await connect(client, server, cache: .swr(staleTime: .zero, gcTime: .zero))
            await server.publish(5)
            await eventually { client.data == .init(seq: 5) }
            _ = view
        }
        await client.settleOperations()
        #expect(await client.isSubscribed())
        #expect(await client.collectGarbage() == false)
        #expect(try rows(client) == [5])
    }
}
