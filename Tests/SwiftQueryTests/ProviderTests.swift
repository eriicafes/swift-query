import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

@MainActor
@Suite("Provider")
struct ProviderTests {
    @Test("Registers heterogeneous models and shares one client per type")
    func registration() throws {
        let server = FakeServer()
        let provider = QueryProvider(
            modelContainer: try makeContainer(),
            for:
                .model(TestUser.self, .init(server: server)),
                .model(TestPost.self, ())
        )

        let users = provider.client(for: TestUser.self)
        #expect(users === provider.client(for: TestUser.self))
        _ = provider.client(for: TestPost.self)

        provider.register(TestUser.self, context: .init(server: FakeServer()))
        #expect(users === provider.client(for: TestUser.self))
    }

    @Test("Unregister cancels the stream")
    func unregister() async throws {
        let (provider, client, server) = try makeProvider()
        await server.setStreaming(true)
        await client.refresh()

        provider.unregister(TestUser.self)
        await client.settle()
        #expect(await server.streams[0].isCancelled)
    }

    @Test("Garbage collection skips forever caches")
    func garbageCollection() async throws {
        let (provider, client, server) = try makeProvider()
        client.sync()
        await client.settle()

        await provider.collectGarbage()
        #expect(client.state.value == .init(etag: 1))
        #expect(await server.fetchCount == 1)
    }

    @Test("Unregister cancels an in-flight fetch and retires the client")
    func unregisterInFlight() async throws {
        let (provider, client, server) = try makeProvider()
        await server.checkpoints.hold("fetch")

        let inFlight = Task { await client.refresh() }
        await server.checkpoints.reached("fetch")
        provider.unregister(TestUser.self)
        await client.settleOperations()
        // The fake request ignores cancellation, so it finishes; its result must be discarded.
        await server.checkpoints.release("fetch")
        await inFlight.value

        #expect(client.state.isPending)
        #expect(client.error == nil)
        #expect(client.fetchState == .idle)

        client.sync()
        await client.settle()
        #expect(await server.fetchCount == 1)
    }

    @Test("Unregistered models have no client for views to activate")
    func registeredClientLookup() throws {
        let (provider, client, _) = try makeProvider()
        #expect(provider.registeredClient(for: TestUser.self) === client)
        #expect(provider.registeredClient(for: TestPost.self) == nil)

        provider.unregister(TestUser.self)
        #expect(provider.registeredClient(for: TestUser.self) == nil)
    }

    @Test("Garbage collection honors the cache policy of the most recent sync")
    func garbageCollectionUsesLastCache() async throws {
        let (provider, client, server) = try makeProvider()
        client.sync(.swr(staleTime: .seconds(3600), cacheTime: .zero))
        await client.settle()
        #expect(client.state.value == .init(etag: 1))

        await provider.collectGarbage()
        #expect(client.state.isPending)
        #expect(try localUsers(client).isEmpty)
        #expect(await server.fetchCount == 1)
    }
}
