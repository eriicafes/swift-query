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
        #expect(client.data == .init(etag: 1))
        #expect(await server.fetchCount == 1)
    }

    @Test("Garbage collection honors the cache policy of the most recent sync")
    func garbageCollectionUsesLastCache() async throws {
        let (provider, client, server) = try makeProvider()
        await provider.waitForGarbageCollection() // the launch sweep
        client.sync(.swr(staleTime: .seconds(3600), gcTime: .zero))
        await client.settle()
        #expect(client.data == .init(etag: 1))

        await provider.collectGarbage()
        #expect(client.state.isPending)
        #expect(try localUsers(client).isEmpty)
        #expect(await server.fetchCount == 1)
    }

    @Test("The provider sweeps expired data at launch")
    func launchSweep() async throws {
        let container = try makeContainer()
        let key = QueryRecord.Key.make(TestDetail(id: "1"))
        let context = ModelContext(container)
        context.insert(TestProfile(userID: "1", bio: "Ada"))
        context.insert(QueryRecord(key: key, type: String(reflecting: TestDetail.self), stateData: Data("{}".utf8), lastSyncedAt: .distantPast, gcTime: 0))
        try context.save()

        let (provider, _, _) = try makeProvider(container)
        await provider.waitForGarbageCollection()

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(QueryRecord.descriptor(key: key)).isEmpty)
        #expect(try fresh.fetch(FetchDescriptor<TestProfile>()).isEmpty)
    }

    @Test("The app going to the background sweeps expired data, with no view showing a key")
    func backgroundSweep() async throws {
        let (provider, _, _) = try makeProvider()
        await provider.waitForGarbageCollection()
        let key = QueryRecord.Key.make(TestDetail(id: "1"))
        let context = ModelContext(provider.modelContainer)
        context.insert(QueryRecord(key: key, type: String(reflecting: TestDetail.self), stateData: Data("{}".utf8), lastSyncedAt: .distantPast, gcTime: 0))
        try context.save()

        // A private center, so other tests' providers aren't swept.
        let center = NotificationCenter()
        provider.observeBackground(on: center)
        center.post(name: QueryProvider.backgroundNotification, object: nil)
        await eventually {
            await provider.waitForGarbageCollection()
            return (try? ModelContext(provider.modelContainer).fetch(QueryRecord.descriptor(key: key)).isEmpty) == true
        }
    }

    @Test("A model's subscription is cancelled after the keep-alive time; the client is kept")
    func modelSubscriptionStops() async throws {
        let (provider, client, server) = try makeProvider(subscribes: true, keepAliveTime: .zero)
        do {
            let subscription = Subscription<ModelFetcher<TestUser>>()
            subscription.activate(client, cache: nil)
            await client.settle()
            await eventually { await server.subscriptionsStarted == 1 }
            _ = subscription
        }
        await eventually { await server.subscriptionsEnded == 1 }
        #expect(await client.isSubscribed() == false)

        // A new view starts it again.
        let subscription = Subscription<ModelFetcher<TestUser>>()
        subscription.activate(client, cache: nil)
        await client.settle()
        await eventually { await server.subscriptionsStarted == 2 }
        _ = provider
    }
}
