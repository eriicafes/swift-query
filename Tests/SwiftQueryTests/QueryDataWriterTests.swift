import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

/// A feed whose subscription hands its writer to the server.
actor FeedServer {
    /// Holds fetches in flight until a test releases them. Key: "fetch".
    nonisolated let checkpoints = Checkpoints()
    private(set) var requestedSeqs: [Int] = []
    private(set) var writer: QueryDataWriter<TestFeed.QueryData>?
    private var latest: Int
    private var failures = 0

    init(latest: Int = 3) {
        self.latest = latest
    }

    func failNextFetch() { failures += 1 }
    func setWriter(_ writer: QueryDataWriter<TestFeed.QueryData>) { self.writer = writer }

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

extension TestFeed: QueryModel {
    struct Context: Sendable {
        let server: FeedServer
    }

    struct QueryData: Codable, Equatable {
        var seq = 0
    }

    static var cache: QueryCache { .forever() }

    static func fetch(context: ModelContext, fetchContext: Context, previous: QueryData?) async throws -> QueryData {
        QueryData(seq: try await fetchContext.server.latest(after: previous?.seq ?? 0))
    }

    static func subscribe(
        container: ModelContainer,
        fetchContext: Context,
        previous: QueryData?,
        writer: QueryDataWriter<QueryData>
    ) -> Task<Void, Never>? {
        let server = fetchContext.server
        return Task { await server.setWriter(writer) }
    }
}

typealias FeedClient = ModelQueryClient<ModelFetcher<TestFeed>>

@MainActor
@Suite("Query data writer")
struct QueryDataWriterTests {
    func makeFeed(
        _ container: ModelContainer? = nil,
        server: FeedServer = FeedServer(),
        keepAliveTime: Duration = .seconds(300)
    ) throws -> (QueryProvider, FeedClient, FeedServer) {
        let provider = QueryProvider(
            modelContainer: try container ?? makeContainer(),
            contexts: TestFeed.Context(server: server),
            fetchers: TestFeed.self,
            keepAliveTime: keepAliveTime
        )
        return (provider, provider.client(for: TestFeed.self), server)
    }

    /// Attaches a view, which syncs the feed and subscribes, then returns the subscription's writer.
    func connect(
        _ client: FeedClient,
        _ server: FeedServer
    ) async throws -> (QueryDataWriter<TestFeed.QueryData>, Subscription<ModelFetcher<TestFeed>>) {
        let subscription = Subscription<ModelFetcher<TestFeed>>()
        subscription.activate(client, cache: nil)
        await client.settle()
        await eventually { await server.writer != nil }
        return (try #require(await server.writer), subscription)
    }

    @Test("Subscription writes are saved and published")
    func persistsAndPublishes() async throws {
        let container = try makeContainer()
        let server = FeedServer()
        do {
            let (_, client, _) = try makeFeed(container, server: server)
            let (writer, _) = try await connect(client, server)
            #expect(client.data == .init(seq: 3))

            await writer.update { $0.seq = max($0.seq, 7) }
            #expect(client.data == .init(seq: 7))
            #expect(client.state.isStale == false)
        }

        let (_, client, _) = try makeFeed(container, server: server)
        #expect(client.data == .init(seq: 7))
        await client.refresh()
        #expect(await server.requestedSeqs == [0, 7])
    }

    @Test("Writes during a fetch apply on top of its result")
    func writesDuringFetch() async throws {
        let (_, client, server) = try makeFeed()
        let (writer, _) = try await connect(client, server)
        await server.checkpoints.hold("fetch")

        let inFlight = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        await writer.update { $0.seq = max($0.seq, 10) }
        #expect(client.data == .init(seq: 3))

        await server.checkpoints.release("fetch")
        await inFlight.value
        #expect(client.data == .init(seq: 10))

        await client.refresh()
        #expect(await server.requestedSeqs.last == 10)
    }

    @Test("Writes queued behind a failed fetch apply to the stored state")
    func writesAfterFailedFetch() async throws {
        let (_, client, server) = try makeFeed()
        let (writer, _) = try await connect(client, server)
        await server.checkpoints.hold("fetch")
        await server.failNextFetch()

        let inFlight = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        await writer.update { $0.seq = max($0.seq, 5) }
        await server.checkpoints.release("fetch")
        await inFlight.value

        #expect(client.data == .init(seq: 5))
        #expect(client.state.isStale)
        #expect(client.error is ServerError)
    }

    @Test("Writes are dropped before any successful sync")
    func writesWithoutState() async throws {
        let (_, client, server) = try makeFeed()
        await server.failNextFetch()
        let (writer, _) = try await connect(client, server)
        #expect(client.state.isError)

        await writer.update { $0.seq = 99 }
        #expect(client.state.isError)

        await client.refresh()
        #expect(await server.requestedSeqs == [0, 0])
    }

    @Test("Writes beyond the queue limit are saved right away")
    func queueLimit() async throws {
        let (_, client, server) = try makeFeed()
        let (writer, _) = try await connect(client, server)
        await server.checkpoints.hold("fetch")

        let inFlight = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        let limit = QueryActor<ModelFetcher<TestFeed>>.pendingWriteLimit
        for seq in 1...limit {
            await writer.update { $0.seq = max($0.seq, seq) }
        }
        #expect(client.data == .init(seq: limit))

        await server.checkpoints.release("fetch")
        await inFlight.value
        #expect(client.data == .init(seq: 3))
    }
}
