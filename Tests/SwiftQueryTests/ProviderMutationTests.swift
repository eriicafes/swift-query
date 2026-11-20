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
        let detailType = String(reflecting: TestDetail.self)

        #expect(QueryFilter.key(TestDetail(id: "1")).matches(key: detail, type: detailType, tags: tags))
        #expect(!QueryFilter.key(TestDetail(id: "2")).matches(key: detail, type: detailType, tags: tags))
        #expect(QueryFilter.key(provider.client(for: TestDetail(id: "1"))).matches(key: detail, type: detailType, tags: tags))
        #expect(QueryFilter.type(TestDetail.self).matches(key: detail, type: detailType, tags: tags))
        #expect(!QueryFilter.type(TestUser.self).matches(key: detail, type: detailType, tags: tags))
        #expect(QueryFilter.type(TestUser.self).matches(key: users.recordKey, type: users.typeName, tags: []))
        #expect(QueryFilter.key(users).matches(key: users.recordKey, type: users.typeName, tags: []))
        #expect(QueryFilter.tag("user-1").matches(key: detail, type: detailType, tags: tags))
        #expect(!QueryFilter.tag("user").matches(key: detail, type: detailType, tags: tags))
        #expect(QueryFilter.all.matches(key: detail, type: detailType, tags: tags))
    }

    @Test("Filters overlap when they may match a common key")
    func filterOverlap() {
        let one = QueryFilter.key(TestDetail(id: "1"))
        #expect(one.overlaps(.key(TestDetail(id: "1"))))
        #expect(!one.overlaps(.key(TestDetail(id: "2"))))
        #expect(one.overlaps(.type(TestDetail.self)))
        #expect(QueryFilter.type(TestDetail.self).overlaps(one))
        #expect(!one.overlaps(.type(TestUser.self)))
        #expect(!QueryFilter.type(TestDetail.self).overlaps(.type(TestUser.self)))
        // A filter alone doesn't say which keys a tag covers.
        #expect(one.overlaps(.tag("anything")))
        #expect(QueryFilter.tag("a").overlaps(.tag("b")))
        #expect(QueryFilter.all.overlaps(one))
    }

    @Test("Bulk operations take several filters")
    func variadicInvalidate() async throws {
        let (provider, users, _) = try await loaded(observed: false)
        let detail = provider.client(for: TestDetail(id: "1"))
        await detail.refresh()
        let other = provider.client(for: TestDetail(id: "2"))
        await other.refresh()

        await provider.invalidate(.type(TestUser.self), .key(TestDetail(id: "1")), .tag("user-1"))
        await users.settleOperations()
        await detail.settleOperations()
        await other.settleOperations()

        #expect(users.state.isStale)
        #expect(detail.state.isStale)
        #expect(!other.state.isStale)
    }

    @Test("refetch skips keys that were never fetched")
    func refetchSkipsUnfetched() async throws {
        let (provider, _, server) = try await loaded(observed: true)
        let detail = provider.client(for: TestDetail(id: "1"))
        let fetches = await server.fetchCount

        await provider.refetch(.tag("users"), type: .all)
        #expect(await server.fetchCount == fetches)
        #expect(detail.state.isPending)
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
        } }()
        #expect(try localUsers(users)["1"] == "Ada L.")
        await server.checkpoints.release("rename:Ada L.")
        await eventually { renames.isSuccess }
    }

    // MARK: Skipped rollbacks

    func renameRow(_ id: String, to name: String) -> OptimisticUpdate {
        { tx in
            let descriptor = FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == id })
            guard let user = try tx.modelContext.fetch(descriptor).first else { return }
            let previous = user.name
            user.name = name
            tx.onRollback { context in
                try context.fetch(descriptor).first?.name = previous
            }
        }
    }

    @Test("A skipped rollback runs after a newer overlapping mutation's if that one fails too")
    func handedOffRollback() async throws {
        // Overlapping filters on a key with no client, so nothing refetches the edited row.
        let overlap = QueryFilter.key(TestDetail(id: "1"))
        let (provider, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:First")

        let first = Task {
            try await provider.mutate(scope: "s", invalidates: [overlap], {
                try await server.rename(id: "1", to: "First", fail: true)
            }, optimistic: renameRow("1", to: "First"))
        }
        await server.checkpoints.reached("rename:First")
        let second = Task {
            try await provider.mutate(scope: "s", invalidates: [overlap], {
                try await server.rename(id: "1", to: "Second", fail: true)
            }, optimistic: renameRow("1", to: "Second"))
        }
        await eventually { (try? localUsers(users)["1"]) == "Second" }
        await server.checkpoints.release("rename:First")
        await #expect(throws: ServerError.self) { try await first.value }
        // The newer edit stays while its call is in flight.
        #expect(try localUsers(users)["1"] == "Second")
        await #expect(throws: ServerError.self) { try await second.value }
        // Both failed and nothing refetches here, so both rollbacks ran, newest first.
        #expect(try localUsers(users)["1"] == "Ada")
    }

    @Test("A skipped rollback is dropped when the newer overlapping mutation succeeds")
    func droppedRollback() async throws {
        // Overlapping filters on a key with no client, so nothing refetches the edited row.
        let overlap = QueryFilter.key(TestDetail(id: "1"))
        let (provider, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:First")

        let first = Task {
            try await provider.mutate(scope: "s", invalidates: [overlap], {
                try await server.rename(id: "1", to: "First", fail: true)
            }, optimistic: renameRow("1", to: "First"))
        }
        await server.checkpoints.reached("rename:First")
        let second = Task {
            try await provider.mutate(scope: "s", invalidates: [overlap], {
                try await server.rename(id: "1", to: "Second")
            }, optimistic: renameRow("1", to: "Second"))
        }
        await eventually { (try? localUsers(users)["1"]) == "Second" }
        await server.checkpoints.release("rename:First")
        await #expect(throws: ServerError.self) { try await first.value }
        _ = try await second.value
        #expect(try localUsers(users)["1"] == "Second")
    }

    @Test("Query data edited twice in one failed update is fully restored")
    func dataRollbackOrder() async throws {
        let (provider, _, server) = try await loaded(observed: false)
        let key = TestDetail(id: "1")
        await provider.client(for: key).refresh()
        let before = try #require(provider.getQueryData(for: key))
        await server.checkpoints.hold("rename:x")

        let mutation = Task {
            try await provider.mutate({
                try await server.rename(id: "1", to: "x", fail: true)
            }, optimistic: { tx in
                tx.setQueryData(for: key) { $0.version += 10 }
                tx.setQueryData(for: key) { $0.version += 100 }
            })
        }
        await server.checkpoints.reached("rename:x")
        // Both edits are stored before the call fails.
        await provider.client(for: key).settleOperations()
        #expect(provider.getQueryData(for: key)?.version == before.version + 110)
        await server.checkpoints.release("rename:x")
        await #expect(throws: ServerError.self) { try await mutation.value }
        #expect(provider.getQueryData(for: key) == before)
    }

    @Test("An optimistic update that throws refetches the query data it changed")
    func throwingUpdateRefetches() async throws {
        let (provider, _, server) = try await loaded(observed: false)
        let key = TestDetail(id: "1")
        let detail = provider.client(for: key)
        detail.attach(nil)
        await detail.settle()
        let fetches = await server.fetchCount

        #expect(throws: ServerError.self) {
            try provider.beginMutation(scope: nil, invalidates: [], optimistic: { tx in
                tx.setQueryData(for: key) { $0.version += 10 }
                throw ServerError()
            })
        }
        await eventually { await server.fetchCount == fetches + 1 }
        await detail.settle()
        #expect(detail.state.isStale == false)
        detail.detach()
    }

    @Test("A rollback isn't handed past a mutation that succeeds in between")
    func handOffToOldest() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        let overlap = QueryFilter.key(TestDetail(id: "1"))
        for name in ["First", "Middle", "Last"] {
            await server.checkpoints.hold("rename:\(name)")
        }
        func start(_ name: String, fail: Bool) -> Task<Void, any Error> {
            Task {
                try await provider.mutate(invalidates: [overlap], {
                    _ = try await server.rename(id: "1", to: name, fail: fail)
                }, optimistic: renameRow("1", to: name))
            }
        }
        let first = start("First", fail: true)
        await server.checkpoints.reached("rename:First")
        let middle = start("Middle", fail: false)
        await server.checkpoints.reached("rename:Middle")
        let last = start("Last", fail: true)
        await server.checkpoints.reached("rename:Last")

        await server.checkpoints.release("rename:First")
        await #expect(throws: ServerError.self) { try await first.value }
        await server.checkpoints.release("rename:Middle")
        try await middle.value
        await server.checkpoints.release("rename:Last")
        await #expect(throws: ServerError.self) { try await last.value }
        // The server has "Middle"; First's rollback was dropped when Middle succeeded.
        #expect(try localUsers(users)["1"] == "Middle")
    }

    @Test("Query data restores follow a handed-off rollback")
    func dataRestoresHandedOff() async throws {
        let (provider, _, server) = try await loaded(observed: false)
        let key = TestDetail(id: "1")
        await provider.client(for: key).refresh()
        let before = try #require(provider.getQueryData(for: key))
        await server.checkpoints.hold("rename:A")
        await server.checkpoints.hold("rename:B")
        func start(_ name: String) -> Task<Void, any Error> {
            Task {
                try await provider.mutate({
                    _ = try await server.rename(id: "1", to: name, fail: true)
                }, optimistic: { tx in tx.setQueryData(for: key) { $0.version += 1 } })
            }
        }
        let a = start("A")
        await server.checkpoints.reached("rename:A")
        let b = start("B")
        await server.checkpoints.reached("rename:B")
        await provider.client(for: key).settleOperations()
        // The refetches after the failures fail too, so only the restores decide the data.
        await server.failNextFetch()
        await server.failNextFetch()

        await server.checkpoints.release("rename:A")
        await #expect(throws: ServerError.self) { try await a.value }
        await server.checkpoints.release("rename:B")
        await #expect(throws: ServerError.self) { try await b.value }
        #expect(provider.getQueryData(for: key) == before)
    }

    @Test("A shared scope alone doesn't hold back a rollback")
    func scopeAloneDoesNotDefer() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:First")
        await server.checkpoints.hold("rename:Second")

        let first = Task {
            try await provider.mutate(scope: "s", {
                try await server.rename(id: "1", to: "First", fail: true)
            }, optimistic: renameRow("1", to: "First"))
        }
        await server.checkpoints.reached("rename:First")
        let second = Task {
            try await provider.mutate(scope: "s", {
                try await server.rename(id: "2", to: "Second")
            }, optimistic: renameRow("2", to: "Second"))
        }
        await eventually { (try? localUsers(users)["2"]) == "Second" }
        await server.checkpoints.release("rename:First")
        await #expect(throws: ServerError.self) { try await first.value }
        // Rolled back at once, though a newer mutation in its scope is still pending.
        #expect(try localUsers(users)["1"] == "Ada")
        await server.checkpoints.release("rename:Second")
        _ = try await second.value
        #expect(try localUsers(users)["1"] == "Ada")
    }

    @Test("refetch waits for an optimistic mutation covering the key")
    func refetchRespectsHold() async throws {
        let (provider, _, server) = try await loaded(observed: false)
        let key = TestDetail(id: "1")
        await provider.client(for: key).refresh()
        await server.checkpoints.hold("rename:x")
        let mutation = Task {
            try await provider.mutate({
                _ = try await server.rename(id: "1", to: "x")
            }, optimistic: { tx in tx.setQueryData(for: key) { $0.version += 10 } })
        }
        await server.checkpoints.reached("rename:x")
        let fetches = await server.fetchCount

        await provider.refetch(.key(key), type: .all)
        #expect(await server.fetchCount == fetches)

        await server.checkpoints.release("rename:x")
        try await mutation.value
        #expect(await server.fetchCount == fetches + 1)
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

    @Test("Overlapping unscoped calls through one mutation observer don't roll back over each other")
    func observerOverlappingCalls() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        let renames = MutationObserver<Void, String>(provider: provider, invalidates: [.type(TestUser.self)])
        await server.checkpoints.hold("rename:Old")

        _ = { renames.mutate({
            try await server.rename(id: "1", to: "Old", fail: true)
        }, optimistic: renameRow("1", to: "Old")) }()
        await server.checkpoints.reached("rename:Old")
        try await renames.mutate({
            try await server.rename(id: "1", to: "New")
        }, optimistic: renameRow("1", to: "New"))
        await server.checkpoints.release("rename:Old")
        await eventually { !renames.isMutating }
        await users.settle()

        // Rolling back would restore "Ada" over the newer edit; the key refetches instead.
        #expect(try localUsers(users)["1"] == "New")
    }

    @Test("Overlapping unscoped provider mutations don't roll back over each other")
    func providerOverlappingMutations() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        await server.checkpoints.hold("rename:Old")

        let older = Task {
            try await provider.mutate(invalidates: [.key(users)]) {
                try await server.rename(id: "1", to: "Old", fail: true)
            } optimistic: { tx in try renameRow("1", to: "Old")(tx) }
        }
        await server.checkpoints.reached("rename:Old")
        try await provider.mutate(invalidates: [.type(TestUser.self)]) {
            try await server.rename(id: "1", to: "New")
        } optimistic: { tx in try renameRow("1", to: "New")(tx) }
        await server.checkpoints.release("rename:Old")
        await #expect(throws: ServerError.self) { try await older.value }
        await users.settle()

        #expect(try localUsers(users)["1"] == "New")
    }

    @Test("Rollbacks run newest first, and also when the optimistic update throws")
    func rollbackOrder() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        var log: [String] = []
        struct Failure: Error {}

        await #expect(throws: ServerError.self) {
            try await provider.mutate {
                try await server.rename(id: "1", to: "X", fail: true)
            } optimistic: { tx in
                tx.onRollback { _ in log.append("first") }
                tx.onRollback { _ in log.append("second") }
            }
        }
        #expect(log == ["second", "first"])

        log = []
        await #expect(throws: Failure.self) {
            try await provider.mutate {
                try await server.rename(id: "1", to: "Never")
            } optimistic: { tx in
                try renameRow("1", to: "Half")(tx)
                tx.onRollback { _ in log.append("undone") }
                throw Failure()
            }
        }
        #expect(log == ["undone"])
        #expect(try localUsers(users)["1"] == "Ada")
        #expect(await server.renameLog.isEmpty == false) // only the first mutation was sent
        #expect(await server.renameLog.contains("start:Never") == false)
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
            }
        }
        await server.checkpoints.reached("rename:Old")
        try await users.mutate {
            try await server.rename(id: "2", to: "New")
        } optimistic: { tx in
            tx.setQueryData(for: TestDetail(id: "1")) { $0.version = 99 }
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
        await provider.invalidate(.all)
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
        await provider.invalidate(.type(TestUser.self))
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

    // MARK: Explicit fetches during a hold

    @Test("query returns the optimistic data while a mutation covering the key is in flight, then fetches once it settles")
    func queryHeld() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        let fetches = await server.fetchCount
        await server.checkpoints.hold("rename:Held")

        let mutation = Task {
            try await provider.mutate(invalidates: [.type(TestUser.self)], {
                try await server.rename(id: "1", to: "Held")
            }, optimistic: { tx in
                tx.setQueryData(for: TestUser.self) { $0.etag = 99 }
            })
        }
        await server.checkpoints.reached("rename:Held")
        #expect(try await provider.query(TestUser.self, staleTime: .after(.zero)) == .init(etag: 99))
        await users.settle()
        #expect(await server.fetchCount == fetches)

        // No view shows the key, so only the deferred query fetches it.
        await server.checkpoints.release("rename:Held")
        _ = try await mutation.value
        await users.settle()
        #expect(await server.fetchCount == fetches + 1)
        #expect(users.data == .init(etag: 2))
    }

    @Test("refresh during a hold returns at once and fetches once the mutation settles")
    func refreshHeld() async throws {
        let (_, users, server) = try await loaded(observed: false)
        let fetches = await server.fetchCount
        await server.checkpoints.hold("rename:Held")

        let mutation = Task {
            try await users.mutate({
                try await server.rename(id: "1", to: "Held")
            }, optimistic: renameRow("1", to: "Held"))
        }
        await server.checkpoints.reached("rename:Held")
        await users.refresh()
        await users.settle()
        #expect(await server.fetchCount == fetches)
        #expect(try localUsers(users)["1"] == "Held")

        await server.checkpoints.release("rename:Held")
        _ = try await mutation.value
        await users.settle()
        #expect(await server.fetchCount == fetches + 1)
        #expect(try localUsers(users)["1"] == "Held")
    }

    @Test("A mutation's remote call can query the key its own optimistic update covers", .timeLimit(.minutes(1)))
    func queryInsideMutation() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        let seen = try await provider.mutate(invalidates: [.type(TestUser.self)], {
            try await provider.query(TestUser.self, staleTime: .after(.zero))
        }, optimistic: { tx in
            tx.setQueryData(for: TestUser.self) { $0.etag = 99 }
        })
        #expect(seen == .init(etag: 99))
        await users.settle()
        #expect(users.data == .init(etag: 2))
        #expect(await server.fetchCount == 2)
    }

    @Test("A refetch waiting on an in-flight fetch defers when a hold starts meanwhile")
    func refetchHeldWhileWaiting() async throws {
        let (provider, users, server) = try await loaded(observed: false)
        let fetches = await server.fetchCount
        await server.checkpoints.hold("fetch")
        let inFlight = Task { await users.refresh() }
        await server.checkpoints.reached("fetch", count: fetches + 1)
        let refetch = Task { await provider.refetch(.type(TestUser.self), type: .all) }
        // The refetch is waiting for the fetch in flight before the hold starts.
        await eventually { await users.refetchWaits() == 1 }

        await server.checkpoints.hold("rename:Held")
        let mutation = Task {
            try await users.mutate({
                try await server.rename(id: "1", to: "Held")
            }, optimistic: renameRow("1", to: "Held"))
        }
        await server.checkpoints.reached("rename:Held")
        await users.settleOperations()
        await server.checkpoints.release("fetch")
        await inFlight.value
        await refetch.value
        await users.settle()
        #expect(await server.fetchCount == fetches + 1)

        await server.checkpoints.release("rename:Held")
        _ = try await mutation.value
        await users.settle()
        #expect(await server.fetchCount == fetches + 2)
        #expect(try localUsers(users)["1"] == "Held")
    }
}
