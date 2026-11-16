import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

@MainActor
@Suite("Filters and provider mutations")
struct ProviderMutationTests {
    /// A provider with the users collection loaded; `observed` attaches it as a view would.
    func loaded(observed: Bool) async throws -> (QueryProvider, UsersClient, FakeServer) {
        let (provider, client, server) = try makeProvider()
        if observed {
            client.attach(nil)
            await client.settle()
        } else {
            await client.refresh()
        }
        return (provider, client, server)
    }

    // MARK: Filters

    @Test("Filters match by key, type, tag, or everything")
    func filterMatching() throws {
        let (provider, users, _) = try makeProvider()
        let detail = QueryRecord.Key.make(TestDetail(id: "1"))
        let tags: Set<String> = ["users", "user-1"]

        #expect(QueryFilter.key(TestDetail(id: "1")).matches(key: detail, tags: tags))
        #expect(!QueryFilter.key(TestDetail(id: "2")).matches(key: detail, tags: tags))
        #expect(QueryFilter.key(provider.client(for: TestDetail(id: "1"))).matches(key: detail, tags: tags))
        #expect(QueryFilter.type(TestDetail.self).matches(key: detail, tags: tags))
        #expect(!QueryFilter.type(TestUser.self).matches(key: detail, tags: tags))
        #expect(QueryFilter.type(TestUser.self).matches(key: users.recordKey, tags: []))
        #expect(QueryFilter.key(users).matches(key: users.recordKey, tags: []))
        #expect(QueryFilter.tag("user-1").matches(key: detail, tags: tags))
        #expect(!QueryFilter.tag("user").matches(key: detail, tags: tags))
        #expect(QueryFilter.all.matches(key: detail, tags: tags))
    }

    @Test("Bulk operations take several filters")
    func variadicInvalidate() async throws {
        let (provider, users, _) = try await loaded(observed: false)
        let detail = provider.client(for: TestDetail(id: "1"))
        await detail.refresh()
        let other = provider.client(for: TestDetail(id: "2"))
        await other.refresh()

        provider.invalidate(.type(TestUser.self), .key(TestDetail(id: "1")), .tag("user-1"))
        await users.settleOperations()
        await detail.settleOperations()
        await other.settleOperations()

        #expect(users.state.isStale)
        #expect(detail.state.isStale)
        #expect(!other.state.isStale)
    }

    @Test("refetch fetches active keys by default, and inactive ones on request")
    func refetchTypes() async throws {
        let (provider, users, _) = try await loaded(observed: true)
        let detail = provider.client(for: TestDetail(id: "1"))
        await detail.refresh()
        let version = detail.data?.version
        let etag = users.data?.etag

        await provider.refetch(.all)
        #expect(users.data?.etag != etag)
        #expect(detail.data?.version == version)

        await provider.refetch(.all, type: .inactive)
        #expect(detail.data?.version != version)
    }

    // MARK: Provider mutations

    @Test("A provider mutation refetches observed keys it invalidates and marks the rest stale")
    func providerMutation() async throws {
        let (provider, users, server) = try await loaded(observed: true)
        let detail = provider.client(for: TestDetail(id: "1"))
        await detail.refresh()
        let fetches = await server.fetchCount

        let result = try await provider.mutate(invalidates: [.type(TestUser.self), .type(TestDetail.self)]) {
            try await server.rename(id: "1", to: "Ada L.")
        }

        #expect(result == "Ada L.")
        #expect(try localUsers(users)["1"] == "Ada L.")
        // Only the observed users collection refetched; the detail is stale until its next sync.
        #expect(await server.fetchCount == fetches + 1)
        await detail.settleOperations()
        #expect(detail.state.isStale)
    }

    @Test("A failed mutation still invalidates its keys")
    func failureInvalidates() async throws {
        let (provider, _, server) = try await loaded(observed: true)
        let fetches = await server.fetchCount

        await #expect(throws: ServerError.self) {
            try await provider.mutate(invalidates: [.type(TestUser.self)]) {
                try await server.rename(id: "1", to: "Nope", fail: true)
            }
        }
        #expect(await server.fetchCount == fetches + 1)
    }

    @Test("A scope settles once across client, provider and mutation client calls")
    func scopeSettlesOnce() async throws {
        let (provider, users, server) = try await loaded(observed: true)
        let renames = MutationObserver<Void, String>(provider: provider, scope: "user-1")
        let fetches = await server.fetchCount
        await server.checkpoints.hold("rename:A")

        let first = Task {
            try await users.mutate(scope: "user-1") { try await server.rename(id: "1", to: "A") }
        }
        await server.checkpoints.reached("rename:A")
        let second = Task {
            try await provider.mutate(scope: "user-1", invalidates: [.type(TestUser.self)]) {
                try await server.rename(id: "1", to: "B")
            }
        }
        let third = Task {
            try await renames.mutate(invalidates: [.key(users), .tag("users")]) {
                try await server.rename(id: "1", to: "C")
            }
        }
        await eventually { provider.mutations.groups[AnyHashable("user-1")]?.pending == 3 }
        #expect(provider.isMutating(scope: "user-1"))
        await server.checkpoints.release("rename:A")
        _ = try await (first.value, second.value, third.value)

        #expect(await server.renameLog == ["start:A", "end:A", "start:B", "end:B", "start:C", "end:C"])
        #expect(await server.fetchCount == fetches + 1)
        #expect(try localUsers(users)["1"] == "C")
        #expect(!provider.isMutating(scope: "user-1"))
    }

    @Test("isMutating covers the client, the provider and the scope")
    func isMutating() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:Held")

        let mutation = Task {
            try await users.mutate(scope: "user-1") { try await server.rename(id: "1", to: "Held") }
        }
        await server.checkpoints.reached("rename:Held")
        #expect(users.isMutating)
        #expect(provider.isMutating)
        #expect(provider.isMutating(scope: "user-1"))
        #expect(!provider.isMutating(scope: "user-2"))

        await server.checkpoints.release("rename:Held")
        _ = try await mutation.value
        #expect(!users.isMutating)
        #expect(!provider.isMutating)
        #expect(!provider.isMutating(scope: "user-1"))
    }

    // MARK: Optimistic query data

    @Test("setQueryData updates query data at once and cancels the in-flight fetch")
    func optimisticQueryData() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("fetch")
        let fetch = Task { await users.refresh() }
        await server.checkpoints.reached("fetch", count: 2)
        await server.checkpoints.hold("rename:Ada L.")

        let mutation = Task {
            try await provider.mutate {
                try await server.rename(id: "1", to: "Ada L.")
            } optimistic: { tx in
                tx.setQueryData(for: TestUser.self) { $0.etag = 99 }
                return nil
            }
        }
        await server.checkpoints.reached("rename:Ada L.")
        #expect(users.data?.etag == 99)

        await server.checkpoints.release("fetch")
        await fetch.value
        #expect(users.data?.etag == 99)
        #expect(provider.getQueryData(for: TestUser.self)?.etag == 99)

        await server.checkpoints.release("rename:Ada L.")
        _ = try await mutation.value
        // Settling invalidated the key, which isn't shown in a view.
        await users.settleOperations()
        #expect(users.state.isStale)
    }

    @Test("setQueryData is restored when the mutation fails")
    func optimisticQueryDataRestored() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        let etag = users.data?.etag

        await #expect(throws: ServerError.self) {
            try await provider.mutate {
                try await server.rename(id: "1", to: "Nope", fail: true)
            } optimistic: { tx in
                tx.setQueryData(for: TestUser.self) { $0.etag = 99 }
                #expect(users.data?.etag == 99)
                return nil
            }
        }
        await users.settleOperations()
        #expect(users.data?.etag == etag)
        #expect(users.state.isStale)
    }

    @Test("setQueryData isn't restored over data that changed since")
    func optimisticQueryDataNotRestored() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:Nope")

        let mutation = Task {
            try await provider.mutate {
                try await server.rename(id: "1", to: "Nope", fail: true)
            } optimistic: { tx in
                tx.setQueryData(for: TestUser.self) { $0.etag = 99 }
                return nil
            }
        }
        await server.checkpoints.reached("rename:Nope")
        try await provider.setQueryData(for: TestUser.self, .init(etag: 5))
        await server.checkpoints.release("rename:Nope")

        await #expect(throws: ServerError.self) { try await mutation.value }
        await users.settleOperations()
        #expect(users.data?.etag == 5)
    }

    @Test("setQueryData does nothing for a key without data")
    func optimisticQueryDataWithoutData() async throws {
        let (provider, _, server) = try makeProvider()
        try await provider.mutate {
            try await server.rename(id: "1", to: "Ada L.")
        } optimistic: { tx in
            tx.setQueryData(for: TestDetail(id: "1")) { $0.version = 99 }
            return nil
        }
        #expect(provider.getQueryData(for: TestDetail(id: "1")) == nil)
    }

    // MARK: Mutation client

    @Test("A mutation client tracks the latest call's status, input and result")
    func mutationClient() async throws {
        let (provider, _, server) = try makeProvider()
        let renames = MutationObserver<String, String>(provider: provider)
        #expect(renames.isIdle)
        await server.checkpoints.hold("rename:Ada L.")

        // A synchronous closure picks the form that returns right away.
        _ = { renames.mutate("Ada L.") { name in try await server.rename(id: "1", to: name) } }()
        #expect(renames.isPending)
        #expect(renames.variables == "Ada L.")
        #expect(renames.data == nil)

        await server.checkpoints.release("rename:Ada L.")
        await eventually { renames.isSuccess }
        #expect(renames.data == "Ada L.")

        // The awaited form returns the result and throws.
        #expect(try await renames.mutate("Grace H.") { name in try await server.rename(id: "2", to: name) } == "Grace H.")
        await #expect(throws: ServerError.self) {
            try await renames.mutate("Nope") { name in try await server.rename(id: "1", to: name, fail: true) }
        }
        #expect(renames.isError)
        #expect(renames.error is ServerError)
        #expect(renames.variables == "Nope")
        #expect(renames.data == nil)

        renames.reset()
        #expect(renames.isIdle)
        #expect(renames.error == nil)
        #expect(renames.variables == nil)
    }

    @Test("A fire-and-forget mutation reports failures through error")
    func mutationClientFailure() async throws {
        let (provider, _, server) = try makeProvider()
        let follow = MutationObserver<Void, Void>(provider: provider)

        _ = { follow.mutate { _ = try await server.rename(id: "1", to: "Nope", fail: true) } }()
        await eventually { !follow.isPending }
        #expect(follow.isError)
        #expect(follow.error is ServerError)
    }

    @Test("An older call finishing late doesn't overwrite the latest call's state")
    func mutationClientLatestCall() async throws {
        let (provider, _, server) = try makeProvider()
        let renames = MutationObserver<String, String>(provider: provider)
        await server.checkpoints.hold("rename:Old")

        _ = { renames.mutate("Old") { name in try await server.rename(id: "1", to: name, fail: true) } }()
        await server.checkpoints.reached("rename:Old")
        try await renames.mutate("New") { name in try await server.rename(id: "2", to: name) }
        // The latest call is done, but the older one still runs.
        #expect(!renames.isPending)
        #expect(renames.isMutating)
        await server.checkpoints.release("rename:Old")
        await eventually { await server.renameLog.contains("end:Old") }
        await eventually { !provider.isMutating }
        #expect(!renames.isMutating)

        #expect(renames.isSuccess)
        #expect(renames.variables == "New")
        #expect(renames.data == "New")
    }

    @Test("A call's scope replaces the default; its filters add to the defaults")
    func mutationClientDefaults() async throws {
        let (provider, users, server) = try await loaded(observed: true)
        let detail = provider.client(for: TestDetail(id: "1"))
        await detail.refresh()
        let renames = MutationObserver<Void, String>(
            provider: provider, scope: "default", invalidates: [.type(TestUser.self)]
        )
        let fetches = await server.fetchCount
        await server.checkpoints.hold("rename:Scoped")

        let mutation = Task {
            try await renames.mutate(scope: "override", invalidates: [.key(TestDetail(id: "1"))]) {
                try await server.rename(id: "1", to: "Scoped")
            }
        }
        await server.checkpoints.reached("rename:Scoped")
        #expect(provider.isMutating(scope: "override"))
        #expect(!provider.isMutating(scope: "default"))
        await server.checkpoints.release("rename:Scoped")
        _ = try await mutation.value

        #expect(await server.fetchCount == fetches + 1)
        #expect(try localUsers(users)["1"] == "Scoped")
        await detail.settleOperations()
        #expect(detail.state.isStale)
    }

    @Test("The input form passes its input to the optimistic update")
    func mutationClientOptimisticInput() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        let renames = MutationObserver<String, String>(provider: provider)
        await server.checkpoints.hold("rename:Ada L.")

        _ = { renames.mutate("Ada L.") { name in
            try await server.rename(id: "1", to: name)
        } optimistic: { tx, name in
            let user = try tx.modelContext.fetch(FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == "1" })).first
            user?.name = name
            return nil
        } }()
        #expect(try localUsers(users)["1"] == "Ada L.")
        await server.checkpoints.release("rename:Ada L.")
        await eventually { renames.isSuccess }
    }

    // MARK: Skipped rollbacks

    func renameRow(_ id: String, to name: String) -> @MainActor (OptimisticContext) throws -> MutationRollback? {
        { tx in
            let descriptor = FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == id })
            guard let user = try tx.modelContext.fetch(descriptor).first else { return nil }
            let previous = user.name
            user.name = name
            return { context in
                try context.fetch(descriptor).first?.name = previous
            }
        }
    }

    @Test("Unscoped calls through one mutation observer roll back independently")
    func observerCallsRollBackIndependently() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        let renames = MutationObserver<Void, String>(provider: provider)
        await server.checkpoints.hold("rename:Old")

        _ = { renames.mutate({
            try await server.rename(id: "1", to: "Old", fail: true)
        }, optimistic: renameRow("1", to: "Old")) }()
        await server.checkpoints.reached("rename:Old")
        try await renames.mutate({
            try await server.rename(id: "2", to: "New")
        }, optimistic: renameRow("2", to: "New"))
        await server.checkpoints.release("rename:Old")
        await eventually { !renames.isMutating }

        #expect(try localUsers(users)["1"] == "Ada")
        #expect(try localUsers(users)["2"] == "New")
    }

    @Test("A skipped rollback refetches the client's data once no optimistic mutation covers it, even when no view shows it")
    func skippedRollbackRefetches() async throws {
        let (_, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:Old")

        let older = Task {
            try await users.mutate({
                try await server.rename(id: "1", to: "Old", fail: true)
            }, optimistic: renameRow("1", to: "Old"))
        }
        await server.checkpoints.reached("rename:Old")
        await server.checkpoints.hold("rename:New")
        let newer = Task {
            try await users.mutate({
                try await server.rename(id: "2", to: "New")
            }, optimistic: renameRow("2", to: "New"))
        }
        await server.checkpoints.reached("rename:New")
        let fetches = await server.fetchCount

        await server.checkpoints.release("rename:Old")
        await #expect(throws: ServerError.self) { try await older.value }
        // The newer mutation is still in flight, so the refetch waits for it instead of
        // overwriting its edit with the server's older data.
        #expect(await server.fetchCount == fetches)
        #expect(try localUsers(users)["2"] == "New")

        await server.checkpoints.release("rename:New")
        _ = try await newer.value
        // The rollback was skipped, so the server's data replaced the older edit.
        #expect(await server.fetchCount == fetches + 1)
        #expect(try localUsers(users)["1"] == "Ada")
        #expect(try localUsers(users)["2"] == "New")
    }

    @Test("Query data is restored even when a newer optimistic mutation touched other keys")
    func queryDataRestoredAfterNewerMutation() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        let detail = provider.client(for: TestDetail(id: "1"))
        await detail.refresh()
        let etag = users.data?.etag
        await server.checkpoints.hold("rename:Old")

        let older = Task {
            try await users.mutate {
                try await server.rename(id: "1", to: "Old", fail: true)
            } optimistic: { tx in
                tx.setQueryData(for: TestUser.self) { $0.etag = 99 }
                return nil
            }
        }
        await server.checkpoints.reached("rename:Old")
        try await users.mutate {
            try await server.rename(id: "2", to: "New")
        } optimistic: { tx in
            tx.setQueryData(for: TestDetail(id: "1")) { $0.version = 99 }
            return nil
        }
        await server.checkpoints.release("rename:Old")
        await #expect(throws: ServerError.self) { try await older.value }
        await users.settleOperations()

        #expect(users.data?.etag == etag)
    }

    // MARK: Pending mutations

    func markerCount(_ provider: QueryProvider) throws -> Int {
        let prefix = QueryRecord.Key.markerPrefix
        return try ModelContext(provider.modelContainer)
            .fetchCount(FetchDescriptor<QueryRecord>(predicate: #Predicate { $0.key.starts(with: prefix) }))
    }

    @Test("Keys of an optimistic mutation that never settled refetch at the next launch")
    func pendingMutationRecovered() async throws {
        let container = try makeContainer()
        let server = FakeServer()
        let (provider, users, _) = try makeProvider(container, server: server)
        await users.refresh()
        await server.checkpoints.hold("rename:Lost")

        let mutation = Task {
            try await provider.mutate(invalidates: [.type(TestUser.self), .tag("user-1")], {
                try await server.rename(id: "1", to: "Lost")
            }, optimistic: renameRow("1", to: "Lost"))
        }
        await server.checkpoints.reached("rename:Lost")
        #expect(try markerCount(provider) == 1)
        // Stored after the mutation started, and still covered by its tag filter.
        await provider.client(for: TestDetail(id: "1")).refresh()

        // A relaunch: a new provider opens the store while the mutation never settled.
        let (relaunched, relaunchedUsers, _) = try makeProvider(container, server: server)
        #expect(try markerCount(relaunched) == 0)
        #expect(relaunchedUsers.state.isStale)
        #expect(relaunched.getQueryState(for: TestDetail(id: "1")).isStale)
        let fetches = await server.fetchCount
        relaunchedUsers.sync()
        await relaunchedUsers.settle()
        #expect(await server.fetchCount == fetches + 1)
        #expect(try localUsers(relaunchedUsers)["1"] == "Ada")

        await server.checkpoints.release("rename:Lost")
        _ = try await mutation.value
    }

    @Test("Settling deletes the mutation's pending marker")
    func pendingMarkerDeleted() async throws {
        let (provider, _, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:Held")

        let mutation = Task {
            try await provider.mutate(scope: "user-1", invalidates: [.tag("users")], {
                try await server.rename(id: "1", to: "Held")
            }, optimistic: renameRow("1", to: "Held"))
        }
        await server.checkpoints.reached("rename:Held")
        #expect(try markerCount(provider) == 1)
        // Markers are bookkeeping, never matched by filters.
        provider.invalidate(.all)
        await provider.remove(.all)
        #expect(try markerCount(provider) == 1)

        await server.checkpoints.release("rename:Held")
        _ = try await mutation.value
        #expect(try markerCount(provider) == 0)
    }

    @Test("Mutations without an optimistic update aren't marked")
    func plainMutationDoesNotMark() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:Plain")

        let mutation = Task {
            try await users.mutate { try await server.rename(id: "1", to: "Plain") }
        }
        await server.checkpoints.reached("rename:Plain")
        #expect(try markerCount(provider) == 0)
        await server.checkpoints.release("rename:Plain")
        _ = try await mutation.value
    }

    // MARK: Holds

    @Test("Syncs don't fetch a key an optimistic mutation in flight covers")
    func syncsHeld() async throws {
        let (provider, users, server) = try await loaded(observed: true)
        let fetches = await server.fetchCount
        await server.checkpoints.hold("rename:Held")

        let mutation = Task {
            try await users.mutate({
                try await server.rename(id: "1", to: "Held")
            }, optimistic: renameRow("1", to: "Held"))
        }
        await server.checkpoints.reached("rename:Held")
        provider.invalidate(.type(TestUser.self))
        users.sync()
        await users.settle()
        #expect(await server.fetchCount == fetches)
        #expect(try localUsers(users)["1"] == "Held")

        await server.checkpoints.release("rename:Held")
        _ = try await mutation.value
        #expect(await server.fetchCount == fetches + 1)
        #expect(try localUsers(users)["1"] == "Held")
    }

    @Test("Another mutation settling defers its refetch until the optimistic one settles")
    func settleDeferred() async throws {
        let (provider, users, server) = try await loaded(observed: true)
        let fetches = await server.fetchCount
        await server.checkpoints.hold("rename:Optimistic")

        let optimistic = Task {
            try await provider.mutate(scope: "a", invalidates: [.type(TestUser.self)], {
                try await server.rename(id: "1", to: "Optimistic")
            }, optimistic: renameRow("1", to: "Optimistic"))
        }
        await server.checkpoints.reached("rename:Optimistic")
        try await provider.mutate(scope: "b", invalidates: [.type(TestUser.self)]) {
            try await server.rename(id: "2", to: "Plain")
        }
        #expect(await server.fetchCount == fetches)
        #expect(try localUsers(users)["1"] == "Optimistic")

        await server.checkpoints.release("rename:Optimistic")
        _ = try await optimistic.value
        #expect(await server.fetchCount == fetches + 1)
        #expect(try localUsers(users)["2"] == "Plain")
    }

    @Test("A covered key without data still fetches")
    func emptyKeyNotHeld() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:Held")
        let mutation = Task {
            try await users.mutate(invalidates: [.tag("users")], {
                try await server.rename(id: "1", to: "Held")
            }, optimistic: renameRow("1", to: "Held"))
        }
        await server.checkpoints.reached("rename:Held")

        let detail = provider.client(for: TestDetail(id: "1"))
        detail.attach(nil)
        await detail.settle()
        #expect(detail.data != nil)

        await server.checkpoints.release("rename:Held")
        _ = try await mutation.value
    }

    @Test("query returns the optimistic data when an optimistic update cancels its fetch")
    func queryAfterOptimisticCancel() async throws {
        let (provider, _, server) = try await loaded(observed: false)
        await server.checkpoints.hold("fetch")
        let query = Task { try await provider.query(TestUser.self, staleTime: .after(.zero)) }
        await server.checkpoints.reached("fetch", count: 2)
        await server.checkpoints.hold("rename:Ada L.")

        let mutation = Task {
            try await provider.mutate {
                try await server.rename(id: "1", to: "Ada L.")
            } optimistic: { tx in
                tx.setQueryData(for: TestUser.self) { $0.etag = 99 }
                return nil
            }
        }
        await server.checkpoints.reached("rename:Ada L.")
        await server.checkpoints.release("fetch")
        #expect(try await query.value.etag == 99)

        await server.checkpoints.release("rename:Ada L.")
        _ = try await mutation.value
    }

    @Test("A provider created with recoversInterruptedMutations off leaves pending mutations alone")
    func recoveryOptOut() async throws {
        let container = try makeContainer()
        let server = FakeServer()
        let (provider, users, _) = try makeProvider(container, server: server)
        await users.refresh()
        await server.checkpoints.hold("rename:Held")
        let mutation = Task {
            try await users.mutate({
                try await server.rename(id: "1", to: "Held")
            }, optimistic: renameRow("1", to: "Held"))
        }
        await server.checkpoints.reached("rename:Held")

        let extensionProvider = QueryProvider(
            modelContainer: container,
            contexts: TestUser.Context(server: server),
            fetchers: TestUser.self, TestDetail.self,
            recoversInterruptedMutations: false
        )
        #expect(try markerCount(extensionProvider) == 1)
        #expect(!extensionProvider.getQueryState(for: TestUser.self).isStale)

        await server.checkpoints.release("rename:Held")
        _ = try await mutation.value
        _ = provider
    }
}
