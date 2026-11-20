import Foundation
import Observation
import SwiftData
import Testing
@testable import SwiftQuery

@MainActor
@Suite("Record lifecycle and observer state")
struct RecordLifecycleTests {
    func records(_ container: ModelContainer, _ key: String) throws -> [QueryRecord] {
        try ModelContext(container).fetch(QueryRecord.descriptor(key: key))
    }

    func rateProvider(_ rates: FakeRates, container: ModelContainer? = nil) throws -> QueryProvider {
        QueryProvider(
            modelContainer: try container ?? makeContainer(),
            contexts: rates as any RateSource,
            fetchers: TestStoredRate.self
        )
    }

    // MARK: Records are stored once they have state

    @Test("A key whose fetch never succeeds stores no record, through syncs, views and invalidation")
    func failingKeyStoresNothing() async throws {
        let rates = FakeRates()
        let provider = try rateProvider(rates)
        let fetcher = TestStoredRate(from: "XXX")
        let key = QueryRecord.Key.make(fetcher)

        await rates.failNext()
        await #expect(throws: ServerError.self) { try await provider.query(fetcher) }
        let client = provider.client(for: fetcher)
        await rates.failNext()
        client.attach(nil)
        await client.settle()
        client.invalidate()
        await provider.invalidate(.tag("rates"), refetch: nil)
        client.detach()
        await client.settle()

        #expect(client.state.isError)
        #expect(try records(provider.modelContainer, key).isEmpty)
    }

    @Test("A key's first successful fetch stores its record, keeping what was recorded before it")
    func firstSuccessStores() async throws {
        let rates = FakeRates()
        let provider = try rateProvider(rates)
        let fetcher = TestStoredRate(from: "USD")
        let key = QueryRecord.Key.make(fetcher)

        await rates.failNext()
        await #expect(throws: ServerError.self) { try await provider.query(fetcher) }
        #expect(try records(provider.modelContainer, key).isEmpty)

        #expect(try await provider.query(fetcher) == 2)
        let stored = try records(provider.modelContainer, key)
        #expect(stored.count == 1)
        #expect(stored.first?.stateData == (try JSONEncoder().encode(2.0)))
        #expect(stored.first?.tags == QueryRecord.Tags.encode(["rates"]))
        #expect(stored.first?.lastSyncedAt != nil)
        #expect(stored.first?.invalidated == false)
    }

    @Test("Removing a key a view shows doesn't leave a record behind when the view goes")
    func removedKeyStaysRemoved() async throws {
        let (provider, _, _) = try makeProvider()
        let detail = provider.client(for: TestDetail(id: "1"))
        detail.attach(nil)
        await detail.settle()
        let key = detail.recordKey
        #expect(try records(provider.modelContainer, key).count == 1)

        await provider.remove(.key(detail))
        detail.detach()
        await detail.settle()
        #expect(try records(provider.modelContainer, key).isEmpty)
    }

    @Test("Evicting a model's data deletes its record, through its client or the store")
    func modelRecordsDeleted() async throws {
        let container = try makeContainer()
        let (provider, users, _) = try makeProvider(container)
        users.sync()
        await users.settle()
        #expect(try records(container, TestUser.queryKey).count == 1)

        // Through the live client.
        await provider.remove(.type(TestUser.self))
        #expect(try records(container, TestUser.queryKey).isEmpty)
        #expect(try localUsers(users).isEmpty)

        users.sync()
        await users.settle()
        #expect(try records(container, TestUser.queryKey).count == 1)

        // Through the store, by a provider with no client for the key.
        let other = QueryProvider(
            modelContainer: container,
            contexts: TestUser.Context(server: FakeServer()),
            fetchers: TestUser.self
        )
        await other.remove(.type(TestUser.self))
        #expect(try records(container, TestUser.queryKey).isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<TestUser>()).isEmpty)
    }

    @Test("The launch sweep deletes records no client can use again, without running evict")
    func orphansDeletedAtLaunch() async throws {
        let container = try makeContainer()
        let detail = String(reflecting: TestDetail.self)
        let current = QueryRecord.Key.make(TestDetail(id: "1"))
        // Still decodes, but encodes back to another key: stored before a property was removed.
        let reshaped = #"[""# + detail + #"",{"id":"2","removed":1}]"#
        // No longer decodes: stored before a property was added.
        let undecodable = #"[""# + detail + #"",{"name":"2"}]"#
        let unlisted = #"["Gone.Forever",{}]"#
        let context = ModelContext(container)
        context.insert(TestProfile(userID: "2", bio: "Grace"))
        let state = Data("{}".utf8)
        context.insert(QueryRecord(key: current, type: detail, stateData: state, lastSyncedAt: .now, gcTime: 86_400))
        context.insert(QueryRecord(key: reshaped, type: detail, stateData: state, lastSyncedAt: .now))
        context.insert(QueryRecord(key: undecodable, type: detail, stateData: state, lastSyncedAt: .now))
        context.insert(QueryRecord(key: unlisted, type: "Gone.Forever", stateData: state, lastSyncedAt: .now))
        context.insert(QueryRecord(key: TestUser.queryKey, type: TestUser.queryType, stateData: state, lastSyncedAt: .now))
        try context.save()

        let (provider, _, _) = try makeProvider(container)
        await provider.waitForGarbageCollection()

        #expect(try records(container, current).count == 1)
        #expect(try records(container, TestUser.queryKey).count == 1)
        #expect(try records(container, reshaped).isEmpty)
        #expect(try records(container, undecodable).isEmpty)
        #expect(try records(container, unlisted).isEmpty)
        // `evict` didn't run for the reshaped key, which decodes to id "2".
        #expect(try ModelContext(container).fetch(FetchDescriptor<TestProfile>()).map(\.userID) == ["2"])
    }

    @Test("Sweeps after launch don't look for orphaned records")
    func orphansOnlyAtLaunch() async throws {
        let (provider, _, _) = try makeProvider()
        await provider.waitForGarbageCollection()
        let unlisted = #"["Gone.Forever",{}]"#
        let context = ModelContext(provider.modelContainer)
        context.insert(QueryRecord(key: unlisted, type: "Gone.Forever", stateData: Data("{}".utf8), lastSyncedAt: .now))
        try context.save()

        await provider.collectGarbage()
        let center = NotificationCenter()
        provider.observeBackground(on: center)
        center.post(name: QueryProvider.backgroundNotification, object: nil)
        await eventually { await provider.waitForGarbageCollection(); return true }
        #expect(try records(provider.modelContainer, unlisted).count == 1)
    }

    // MARK: Errors

    @Test("A snapshot that doesn't change the error doesn't reassign it")
    func errorAssignedOnlyWhenChanged() async throws {
        let rates = FakeRates()
        let provider = QueryProvider(modelContainer: try makeContainer(), contexts: rates as any RateSource)
        let fetcher = TestRate(from: "USD", to: "EUR")
        await rates.failNext()
        await #expect(throws: ServerError.self) { try await provider.query(fetcher) }
        let client = provider.client(for: fetcher)
        #expect(client.error is ServerError)

        let changed = Flag()
        withObservationTracking {
            _ = client.error
        } onChange: {
            changed.value = true
        }
        // The fetch starting publishes a snapshot with the same error.
        await rates.checkpoints.hold("rate")
        client.sync()
        await rates.checkpoints.reached("rate", count: 2)
        await eventually { client.isFetching }
        #expect(!changed.value)

        // A success clears it.
        await rates.checkpoints.release("rate")
        await client.settle()
        #expect(changed.value)
        #expect(client.error == nil)
        #expect(client.data == 2)

        // A new failure sets it again.
        await rates.failNext()
        await client.refresh()
        #expect(client.error is ServerError)
    }

    // MARK: Optimistic updates

    @Test("Query data that can't be encoded isn't applied optimistically")
    func unencodableOptimisticUpdate() async throws {
        let rates = FakeRates()
        let provider = QueryProvider(modelContainer: try makeContainer(), contexts: rates as any RateSource)
        let fetcher = TestRate(from: "USD", to: "EUR")
        #expect(try await provider.query(fetcher) == 1)
        let client = provider.client(for: fetcher)

        // JSON can't hold NaN.
        #expect(client.applyOptimistic { $0 = .nan } == nil)
        #expect(client.data == 1)
        await client.settle()
        #expect(client.data == 1)

        // A mutation whose update can't apply doesn't invalidate the key for it.
        try await provider.mutate({ () }, optimistic: { tx in
            tx.setQueryData(for: fetcher) { $0 = .nan }
        })
        #expect(client.data == 1)
        #expect(client.state.isStale == false)
        #expect(await rates.requests.count == 1)
    }
}
