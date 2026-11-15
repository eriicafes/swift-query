import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

@MainActor
@Suite("Scoped mutations")
struct ScopedMutationTests {
    func rename(id: String, to name: String) -> @MainActor (ModelContext) throws -> MutationRollback? {
        { context in
            let descriptor = FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == id })
            guard let user = try context.fetch(descriptor).first else { return nil }
            let previous = user.name
            user.name = name
            try context.save()
            return { context in
                guard let user = try context.fetch(descriptor).first else { return }
                user.name = previous
                try context.save()
            }
        }
    }

    func syncedClient() async throws -> (UsersClient, FakeServer, QueryProvider) {
        let (provider, client, server) = try makeProvider()
        client.sync()
        await client.settle()
        return (client, server, provider)
    }

    /// How many mutations are pending (running or queued) in `scope`.
    func pending(_ provider: QueryProvider, _ scope: String) -> Int {
        provider.mutations.groups[AnyHashable(scope)]?.pending ?? 0
    }

    @Test("Same scope sends remote calls one at a time, in call order")
    func serialInOrder() async throws {
        let (client, server, provider) = try await syncedClient()
        await server.checkpoints.hold("rename:First")

        let first = Task {
            try await client.mutate(scope: "user-1") {
                try await server.rename(id: "1", to: "First")
            }
        }
        await server.checkpoints.reached("rename:First")
        let second = Task {
            try await client.mutate(scope: "user-1") {
                try await server.rename(id: "1", to: "Second")
            }
        }
        await eventually { pending(provider, "user-1") == 2 }
        #expect(await server.renameLog == ["start:First"])

        await server.checkpoints.release("rename:First")
        _ = try await (first.value, second.value)

        #expect(await server.renameLog == ["start:First", "end:First", "start:Second", "end:Second"])
        #expect(await server.users["1"] == "Second")
        #expect(try localUsers(client)["1"] == "Second")
    }

    @Test("Different scopes and unscoped mutations run in parallel")
    func parallelAcrossScopes() async throws {
        let (client, server, _) = try await syncedClient()
        await server.checkpoints.hold("rename:Slow")

        let slow = Task {
            try await client.mutate(scope: "user-1") {
                try await server.rename(id: "1", to: "Slow")
            }
        }
        await server.checkpoints.reached("rename:Slow")

        // Both finish while the first scope's call is still held.
        _ = try await client.mutate(scope: "user-2") {
            try await server.rename(id: "2", to: "Other")
        }
        _ = try await client.mutate {
            try await server.rename(id: "2", to: "Unscoped")
        }
        #expect(await !server.renameLog.contains("end:Slow"))

        await server.checkpoints.release("rename:Slow")
        _ = try await slow.value
    }

    @Test("Optimistic updates apply immediately while queued")
    func optimisticWhileQueued() async throws {
        let (client, server, provider) = try await syncedClient()
        await server.checkpoints.hold("rename:First")

        let first = Task {
            try await client.mutate(scope: "user-1", {
                try await server.rename(id: "1", to: "First")
            }, optimistic: rename(id: "1", to: "First"))
        }
        await server.checkpoints.reached("rename:First")
        let second = Task {
            try await client.mutate(scope: "user-1", {
                try await server.rename(id: "1", to: "Second")
            }, optimistic: rename(id: "1", to: "Second"))
        }
        await eventually { pending(provider, "user-1") == 2 }

        #expect(try localUsers(client)["1"] == "Second")
        #expect(await server.renameLog == ["start:First"])
        await server.checkpoints.release("rename:First")
        _ = try await (first.value, second.value)
        #expect(try localUsers(client)["1"] == "Second")
    }

    @Test("The scope refetches once, after its last mutation")
    func refetchOnDrain() async throws {
        let (client, server, provider) = try await syncedClient()
        await server.checkpoints.hold("rename:First")

        let first = Task {
            try await client.mutate(scope: "user-1") {
                try await server.rename(id: "1", to: "First")
            }
        }
        await server.checkpoints.reached("rename:First")
        let second = Task {
            try await client.mutate(scope: "user-1") {
                try await server.rename(id: "1", to: "Second")
            }
        }
        await eventually { pending(provider, "user-1") == 2 }
        await server.checkpoints.release("rename:First")
        _ = try await first.value
        _ = try await second.value

        #expect(await server.fetchCount == 2)
        #expect(provider.mutations.groups.isEmpty)
    }

    @Test("A failure doesn't cancel later mutations, and its error goes to its own caller")
    func failureIsolation() async throws {
        let (client, server, provider) = try await syncedClient()
        await server.checkpoints.hold("rename:Bad")

        let failing = Task {
            try await client.mutate(scope: "user-1", {
                try await server.rename(id: "1", to: "Bad", fail: true)
            }, optimistic: rename(id: "1", to: "Bad"))
        }
        await server.checkpoints.reached("rename:Bad")
        let next = Task {
            try await client.mutate(scope: "user-1", {
                try await server.rename(id: "1", to: "Good")
            }, optimistic: rename(id: "1", to: "Good"))
        }
        await eventually { pending(provider, "user-1") == 2 }
        await server.checkpoints.release("rename:Bad")

        await #expect(throws: ServerError.self) { try await failing.value }
        #expect(try await next.value == "Good")
        #expect(try localUsers(client)["1"] == "Good")
        #expect(await server.users["1"] == "Good")
        #expect(await server.fetchCount == 2)
    }

    @Test("A failed mutation rolls back when it is the newest in its scope")
    func rollbackWhenNewest() async throws {
        let (client, server, _) = try await syncedClient()
        await server.checkpoints.hold("rename:Other")

        let other = Task {
            try await client.mutate(scope: "user-2", {
                try await server.rename(id: "2", to: "Other")
            }, optimistic: rename(id: "2", to: "Other"))
        }
        await server.checkpoints.reached("rename:Other")

        await #expect(throws: ServerError.self) {
            try await client.mutate(scope: "user-1", {
                try await server.rename(id: "1", to: "Bad", fail: true)
            }, optimistic: rename(id: "1", to: "Bad"))
        }
        // A newer optimistic update in another scope doesn't block this rollback.
        #expect(try localUsers(client)["1"] == "Ada")
        await server.checkpoints.release("rename:Other")
        _ = try await other.value
    }

    @Test("A mutation cancelled while queued rolls back without calling the server")
    func cancelledWhileQueued() async throws {
        let (client, server, provider) = try await syncedClient()
        await server.checkpoints.hold("rename:First")

        let first = Task {
            try await client.mutate(scope: "user-1", {
                try await server.rename(id: "1", to: "First")
            }, optimistic: rename(id: "1", to: "First"))
        }
        await server.checkpoints.reached("rename:First")
        let queued = Task {
            try await client.mutate(scope: "user-1", {
                try await server.rename(id: "1", to: "Queued")
            }, optimistic: rename(id: "1", to: "Queued"))
        }
        await eventually { pending(provider, "user-1") == 2 }
        queued.cancel()

        await #expect(throws: CancellationError.self) { try await queued.value }
        await server.checkpoints.release("rename:First")
        _ = try await first.value
        #expect(await server.renameLog == ["start:First", "end:First"])
        #expect(try localUsers(client)["1"] == "First")
    }

    @Test("A scope spanning models refetches each one it touched")
    func crossModelScope() async throws {
        let server = FakeServer()
        let feed = FeedServer()
        let provider = QueryProvider(
            modelContainer: try makeContainer(),
            contexts: TestUser.Context(server: server), TestFeed.Context(server: feed),
            fetchers: TestUser.self, TestFeed.self
        )
        let users = provider.client(for: TestUser.self)
        let feeds = provider.client(for: TestFeed.self)
        await users.refresh()
        await feeds.refresh()
        await server.checkpoints.hold("rename:Shared")

        let first = Task {
            try await users.mutate(scope: "shared") {
                try await server.rename(id: "1", to: "Shared")
            }
        }
        await server.checkpoints.reached("rename:Shared")
        let second = Task {
            try await feeds.mutate(scope: "shared") {
                await server.renameLog.count
            }
        }
        await eventually { pending(provider, "shared") == 2 }
        await server.checkpoints.release("rename:Shared")
        _ = try await first.value
        let logCount = try await second.value

        // The feed mutation ran only after the user rename finished.
        #expect(logCount == 2)
        #expect(await server.fetchCount == 2)
        #expect(await feed.requestedSeqs.count == 2)
    }

    @Test("A queued mutation stops waiting as soon as it is cancelled")
    func cancelStopsWaiting() async throws {
        let (client, server, provider) = try await syncedClient()
        await server.checkpoints.hold("rename:First")

        let first = Task {
            try await client.mutate(scope: "user-1") {
                try await server.rename(id: "1", to: "First")
            }
        }
        await server.checkpoints.reached("rename:First")
        let queued = Task {
            try await client.mutate(scope: "user-1", {
                try await server.rename(id: "1", to: "Queued")
            }, optimistic: rename(id: "1", to: "Queued"))
        }
        await eventually { pending(provider, "user-1") == 2 }
        let third = Task {
            try await client.mutate(scope: "user-1") {
                try await server.rename(id: "1", to: "Third")
            }
        }
        await eventually { pending(provider, "user-1") == 3 }
        queued.cancel()

        // The first call is still held, so returning now proves the wait ended early.
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await server.renameLog == ["start:First"])

        await server.checkpoints.release("rename:First")
        _ = try await (first.value, third.value)
        #expect(await server.renameLog == ["start:First", "end:First", "start:Third", "end:Third"])
    }
}
