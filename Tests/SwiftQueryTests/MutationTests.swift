import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

@MainActor
@Suite("Mutations")
struct MutationTests {
    func rename(_ client: UsersClient, id: String, to name: String) -> OptimisticUpdate {
        { tx in
            let context = tx.modelContext
            let descriptor = FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == id })
            guard let user = try context.fetch(descriptor).first else { return }
            let previous = user.name
            user.name = name
            try context.save()
            tx.onRollback { context in
                guard let user = try context.fetch(descriptor).first else { return }
                user.name = previous
                try context.save()
            }
        }
    }

    func syncedClient() async throws -> (UsersClient, FakeServer, QueryProvider) {
        let (provider, client, server) = try makeProvider()
        client.attach(nil) // shown in a view, so mutations refetch it
        await client.settle()
        return (client, server, provider)
    }

    @Test("Successful mutation refreshes")
    func success() async throws {
        let (client, server, _) = try await syncedClient()

        let result = try await client.mutate {
            try await server.rename(id: "1", to: "Ada L.")
        }

        #expect(result == "Ada L.")
        #expect(await server.fetchCount == 2)
        #expect(try localUsers(client)["1"] == "Ada L.")
    }

    @Test("Optimistic update applies immediately and rolls back on failure")
    func rollback() async throws {
        let (client, server, _) = try await syncedClient()

        await server.checkpoints.hold("rename:Nope")
        let mutation = Task {
            try await client.mutate({
                try await server.rename(id: "1", to: "Nope", fail: true)
            }, optimistic: rename(client, id: "1", to: "Nope"))
        }
        await server.checkpoints.reached("rename:Nope")
        #expect(try localUsers(client)["1"] == "Nope")
        await server.checkpoints.release("rename:Nope")

        await #expect(throws: ServerError.self) { try await mutation.value }
        #expect(try localUsers(client)["1"] == "Ada")
        #expect(client.state.isError == false)
        #expect(client.error == nil)
        // A failed mutation still settles: the observed key refetches.
        #expect(await server.fetchCount == 2)
    }

    @Test("Refresh failure after a successful mutation does not roll back or throw")
    func refreshFailure() async throws {
        let (client, server, _) = try await syncedClient()
        await server.failNextFetch()

        let result = try await client.mutate({
            try await server.rename(id: "1", to: "Ada L.")
        }, optimistic: rename(client, id: "1", to: "Ada L."))

        #expect(result == "Ada L.")
        #expect(try localUsers(client)["1"] == "Ada L.")
        #expect(client.error is ServerError)
        #expect(client.state.isStale)
    }

    @Test("An older failed mutation does not roll back a newer change")
    func concurrentMutations() async throws {
        let (client, server, _) = try await syncedClient()

        await server.checkpoints.hold("rename:Old")
        let older = Task {
            try await client.mutate({
                try await server.rename(id: "1", to: "Old", fail: true)
            }, optimistic: rename(client, id: "1", to: "Old"))
        }
        await server.checkpoints.reached("rename:Old")
        let newer = Task {
            try await client.mutate({
                try await server.rename(id: "1", to: "New")
            }, optimistic: rename(client, id: "1", to: "New"))
        }

        _ = try await newer.value
        await server.checkpoints.release("rename:Old")
        await #expect(throws: ServerError.self) { try await older.value }
        await client.settle()

        #expect(try localUsers(client)["1"] == "New")
        #expect(await server.users["1"] == "New")
    }

    @Test("A mutation waits for a fetch that starts after it, not a stale in-flight one")
    func refetchAfterInFlight() async throws {
        let (client, server, _) = try await syncedClient()
        await server.checkpoints.hold("fetch")

        // This fetch was sent before the rename, so its response has the old name.
        let inFlight = Task { await client.refresh() }
        await server.checkpoints.reached("fetch", count: 2)

        let mutation = Task {
            try await client.mutate({
                try await server.rename(id: "1", to: "Ada L.")
            }, optimistic: rename(client, id: "1", to: "Ada L."))
        }
        await server.checkpoints.reached("rename:Ada L.")
        await server.checkpoints.release("fetch")
        _ = try await mutation.value

        #expect(try localUsers(client)["1"] == "Ada L.")
        #expect(await server.fetchCount == 3)
        await inFlight.value
    }

    @Test("Unsaved optimistic edits and rollbacks are saved")
    func savesOptimisticEdits() async throws {
        let (client, server, _) = try await syncedClient()
        let storedName = {
            try ModelContext(client.modelContainer)
                .fetch(FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == "1" })).first?.name
        }
        let unsavedRename: OptimisticUpdate = { tx in
            let user = try #require(try tx.modelContext.fetch(FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == "1" })).first)
            user.name = "Unsaved"
            tx.onRollback { context in
                let user = try #require(try context.fetch(FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == "1" })).first)
                user.name = "Ada"
            }
        }

        await server.checkpoints.hold("rename:Unsaved")
        let mutation = Task {
            try await client.mutate({
                try await server.rename(id: "1", to: "Unsaved", fail: true)
            }, optimistic: unsavedRename)
        }
        await server.checkpoints.reached("rename:Unsaved")
        #expect(try storedName() == "Unsaved")
        await server.checkpoints.release("rename:Unsaved")

        await #expect(throws: ServerError.self) { try await mutation.value }
        #expect(try storedName() == "Ada")
    }

    @Test("Cancelling the caller doesn't cancel a sent remote call")
    func cancelAfterSend() async throws {
        let (client, server, _) = try await syncedClient()

        await server.checkpoints.hold("rename:Sent")
        let mutation = Task {
            try await client.mutate({
                try await server.rename(id: "1", to: "Sent")
            }, optimistic: rename(client, id: "1", to: "Sent"))
        }
        await server.checkpoints.reached("rename:Sent")
        mutation.cancel()
        await server.checkpoints.release("rename:Sent")

        #expect(try await mutation.value == "Sent")
        #expect(await server.users["1"] == "Sent")
        #expect(try localUsers(client)["1"] == "Sent")
    }

    @Test("A caller cancelled before sending rolls back without calling the server")
    func cancelBeforeSend() async throws {
        let (client, server, _) = try await syncedClient()

        let mutation = Task {
            try await client.mutate({
                try await server.rename(id: "1", to: "Never")
            }, optimistic: rename(client, id: "1", to: "Never"))
        }
        mutation.cancel()

        await #expect(throws: CancellationError.self) { try await mutation.value }
        #expect(await server.renameLog.isEmpty)
        #expect(try localUsers(client)["1"] == "Ada")
    }

    @Test("A failed optimistic save runs the rollback and sends nothing")
    func optimisticSaveFailure() async throws {
        let (client, server, _) = try await syncedClient()
        let context = client.modelContainer.mainContext
        struct SaveFailure: Error {}
        var saves = 0

        #expect(throws: SaveFailure.self) {
            try QueryProvider.applyOptimistic(
                { context in
                    let user = try #require(try context.fetch(FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == "1" })).first)
                    user.name = "Broken"
                    return { _ in user.name = "Ada" }
                },
                in: context,
                save: { _ in
                    saves += 1
                    if saves == 1 { throw SaveFailure() }
                }
            )
        }
        #expect(saves == 2)
        #expect(try localUsers(client)["1"] == "Ada")
        #expect(await server.renameLog.isEmpty)
    }

    @Test("With autosave off, mutate doesn't save the main context")
    func autosaveOff() async throws {
        let (client, server, _) = try await syncedClient()
        let main = client.modelContainer.mainContext
        main.autosaveEnabled = false
        let draft = try #require(try main.fetch(FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == "2" })).first)
        draft.name = "Draft"

        let storedName = { (id: String) in
            try ModelContext(client.modelContainer)
                .fetch(FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == id })).first?.name
        }
        await server.checkpoints.hold("rename:Ada L.")
        let mutation = Task {
            try await client.mutate({
                try await server.rename(id: "1", to: "Ada L.")
            }, optimistic: { tx in
                let user = try #require(try tx.modelContext.fetch(FetchDescriptor<TestUser>(predicate: #Predicate { $0.id == "1" })).first)
                user.name = "Ada L."
            })
        }
        await server.checkpoints.reached("rename:Ada L.")
        #expect(try storedName("1") == "Ada")
        #expect(try storedName("2") == "Grace")
        #expect(main.hasChanges)
        await server.checkpoints.release("rename:Ada L.")
        _ = try await mutation.value
    }
}
