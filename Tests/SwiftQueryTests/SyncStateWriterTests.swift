import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

/// A feed whose fetch hands its writer to the server, standing in for a stream task.
actor FeedServer {
    /// Holds fetches in flight until a test releases them. Key: "fetch".
    nonisolated let checkpoints = Checkpoints()
    private(set) var requestedSeqs: [Int] = []
    private(set) var writer: SyncStateWriter<TestFeed>?
    private var latest: Int
    private var failures = 0

    init(latest: Int = 3) {
        self.latest = latest
    }

    func failNextFetch() { failures += 1 }
    func setWriter(_ writer: SyncStateWriter<TestFeed>) { self.writer = writer }

    func latest(after seq: Int) async throws -> Int {
        requestedSeqs.append(seq)
        let snapshot = latest
        await checkpoints.pass("fetch")
        if failures > 0 {
            failures -= 1
            throw ServerError()
        }
        return snapshot
    }
}

@Model
final class TestFeed {
    var seq: Int
    init(seq: Int) { self.seq = seq }
}

extension TestFeed: SyncedModel {
    struct SyncContext: Sendable {
        let server: FeedServer
    }

    struct SyncState: Codable, Equatable {
        var seq = 0
    }

    static var defaultState: SyncState { .init() }
    static var cache: QueryCache { .forever() }

    static func fetch(
        context: ModelContext,
        syncContext: SyncContext,
        syncState: inout SyncState,
        writer: SyncStateWriter<TestFeed>
    ) async throws -> Task<Void, Never>? {
        await syncContext.server.setWriter(writer)
        syncState.seq = try await syncContext.server.latest(after: syncState.seq)
        return nil
    }
}

@MainActor
@Suite("Sync state writer")
struct SyncStateWriterTests {
    func makeFeed(
        _ container: ModelContainer? = nil,
        server: FeedServer = FeedServer()
    ) throws -> (QueryProvider, ModelQueryClient<TestFeed>, FeedServer) {
        let provider = QueryProvider(
            modelContainer: try container ?? makeContainer(),
            for: .model(TestFeed.self, .init(server: server))
        )
        return (provider, provider.client(for: TestFeed.self), server)
    }

    @Test("Stream writes are saved and published")
    func persistsAndPublishes() async throws {
        let container = try makeContainer()
        let server = FeedServer()
        do {
            let (_, client, _) = try makeFeed(container, server: server)
            await client.refresh()
            #expect(client.state.value == .init(seq: 3))

            let writer = try #require(await server.writer)
            await writer.update { $0.seq = max($0.seq, 7) }
            #expect(client.state.value == .init(seq: 7))
            #expect(client.state.isStale == false)
        }

        let (_, client, _) = try makeFeed(container, server: server)
        #expect(client.state.value == .init(seq: 7))
        await client.refresh()
        #expect(await server.requestedSeqs == [0, 7])
    }

    @Test("Writes during a fetch apply on top of its result")
    func writesDuringFetch() async throws {
        let (_, client, server) = try makeFeed()
        await client.refresh()
        let writer = try #require(await server.writer)
        await server.checkpoints.hold("fetch")

        let inFlight = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        await writer.update { $0.seq = max($0.seq, 10) }
        #expect(client.state.value == .init(seq: 3))

        await server.checkpoints.release("fetch")
        await inFlight.value
        #expect(client.state.value == .init(seq: 10))

        await client.refresh()
        #expect(await server.requestedSeqs.last == 10)
    }

    @Test("Writes queued behind a failed fetch apply to the stored state")
    func writesAfterFailedFetch() async throws {
        let (_, client, server) = try makeFeed()
        await client.refresh()
        let writer = try #require(await server.writer)
        await server.checkpoints.hold("fetch")
        await server.failNextFetch()

        let inFlight = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        await writer.update { $0.seq = max($0.seq, 5) }
        await server.checkpoints.release("fetch")
        await inFlight.value

        #expect(client.state.value == .init(seq: 5))
        #expect(client.state.isStale)
        #expect(client.error is ServerError)
    }

    @Test("Writes are dropped before any successful sync")
    func writesWithoutState() async throws {
        let (_, client, server) = try makeFeed()
        await server.failNextFetch()
        await client.refresh()
        #expect(client.state.isError)

        let writer = try #require(await server.writer)
        await writer.update { $0.seq = 99 }
        #expect(client.state.isError)

        await client.refresh()
        #expect(await server.requestedSeqs == [0, 0])
    }

    @Test("Writes after unregister are ignored")
    func writesAfterUnregister() async throws {
        let container = try makeContainer()
        let (provider, client, server) = try makeFeed(container)
        await client.refresh()
        let writer = try #require(await server.writer)

        provider.unregister(TestFeed.self)
        await client.settle()
        await writer.update { $0.seq = 99 }

        let record = try #require(
            try container.mainContext.fetch(QueryRecord.descriptor(key: TestFeed.queryKey)).first
        )
        let stored = try JSONDecoder().decode(TestFeed.SyncState.self, from: try #require(record.stateData))
        #expect(stored == .init(seq: 3))
    }

    @Test("A QueryModel's writer-taking fetch forwards to its plain fetch")
    func queryModelForwards() async throws {
        let container = try makeContainer()
        let server = FakeServer()
        let actor = ModelQueryActor<TestUser>(
            modelContainer: container,
            syncContext: .init(server: server),
            publisher: { _ in }
        )
        var state = TestUser.defaultState
        try await TestUser.fetch(
            context: ModelContext(container),
            syncContext: .init(server: server),
            syncState: &state,
            writer: SyncStateWriter(target: WriterTarget(actor))
        )
        #expect(state == .init(etag: 1))
        #expect(await server.fetchCount == 1)
    }

    @Test("Writes beyond the queue limit are saved right away")
    func queueLimit() async throws {
        let (_, client, server) = try makeFeed()
        await client.refresh()
        let writer = try #require(await server.writer)
        await server.checkpoints.hold("fetch")

        let inFlight = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        let limit = ModelQueryActor<TestFeed>.pendingWriteLimit
        for seq in 1...limit {
            await writer.update { $0.seq = max($0.seq, seq) }
        }
        #expect(client.state.value == .init(seq: limit))

        await server.checkpoints.release("fetch")
        await inFlight.value
        #expect(client.state.value == .init(seq: 3))
    }
}
