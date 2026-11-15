import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

@MainActor
@Suite("Provider")
struct ProviderTests {
    @Test("Lists models and fetchers together and shares one client per key")
    func registration() throws {
        let server = FakeServer()
        let provider = QueryProvider(
            modelContainer: try makeContainer(),
            contexts: TestUser.Context(server: server),
            fetchers: TestUser.self, TestPost.self, TestDetail.self
        )

        let users = provider.client(for: TestUser.self)
        #expect(users === provider.client(for: TestUser.self))
        // TestPost's Void context needs no registration.
        _ = provider.client(for: TestPost.self)
        #expect(provider.client(for: TestDetail(id: "1")) === provider.client(for: TestDetail(id: "1")))
        #expect(provider.client(for: TestDetail(id: "1")) !== provider.client(for: TestDetail(id: "2")))
        #expect(Set(provider.entries.keys) == [
            String(reflecting: TestUser.self), String(reflecting: TestPost.self), String(reflecting: TestDetail.self),
        ])
    }

    @Test("Contexts resolve by registered type, protocol cast, or DefaultFetchContext")
    func contextResolution() async throws {
        let rates = FakeRates()
        let provider = QueryProvider(
            modelContainer: try makeContainer(),
            contexts: rates as any RateSource
        )
        #expect(try await provider.query(TestRate(from: "USD", to: "EUR")) == 1)
        #expect(try await provider.query(TestDefaulted()) == 7)
        #expect(await rates.requests == ["USD-EUR"])
    }

    @Test("Garbage collection skips forever caches")
    func garbageCollection() async throws {
        let (provider, client, server) = try makeProvider()
        client.sync()
        await client.settle()

        await provider.collectGarbage()
        #expect(client.status.value == .init(etag: 1))
        #expect(await server.fetchCount == 1)
    }

    @Test("Garbage collection honors the cache policy of the most recent sync")
    func garbageCollectionUsesLastCache() async throws {
        let (provider, client, server) = try makeProvider()
        client.sync(.swr(staleTime: .seconds(3600), cacheTime: .zero))
        await client.settle()
        #expect(client.status.value == .init(etag: 1))

        await provider.collectGarbage()
        #expect(client.status.isPending)
        #expect(try localUsers(client).isEmpty)
        #expect(await server.fetchCount == 1)
    }

    @Test("The queryRecords configuration is a local-only store of QueryRecord")
    func queryRecordsConfiguration() {
        let configuration = ModelConfiguration.queryRecords
        #expect(configuration.name == "SwiftQuery")
        #expect(configuration.schema?.entities.map(\.name) == ["QueryRecord"])
    }
}
