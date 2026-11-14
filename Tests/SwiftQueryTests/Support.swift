import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

struct ServerError: Error, Equatable {
    var message = "server error"
}

/// An in-memory stand-in for a remote API.
actor FakeServer {
    /// Holds requests in flight until a test releases them. Keys: "fetch", "rename:<name>".
    nonisolated let checkpoints = Checkpoints()
    private(set) var users: [String: String]
    private(set) var fetchCount = 0
    private(set) var requestedEtags: [Int?] = []
    private(set) var streams: [Task<Void, Never>] = []
    /// "start:<name>" and "end:<name>" for each rename, in order.
    private(set) var renameLog: [String] = []
    private var etag = 0
    private var failures: [any Error] = []
    private var streaming = false

    init(users: [String: String] = ["1": "Ada", "2": "Grace"]) {
        self.users = users
    }

    func failNextFetch(_ error: any Error = ServerError()) { failures.append(error) }
    func setStreaming(_ streaming: Bool) { self.streaming = streaming }

    func list(etag requested: Int?) async throws -> (users: [String: String], etag: Int) {
        fetchCount += 1
        requestedEtags.append(requested)
        // The response reflects the server when the request arrived, like a real round trip.
        let snapshot = users
        await checkpoints.pass("fetch")
        if !failures.isEmpty { throw failures.removeFirst() }
        etag += 1
        return (snapshot, etag)
    }

    func makeStream() -> Task<Void, Never>? {
        guard streaming else { return nil }
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(3600)) }
        streams.append(task)
        return task
    }

    func rename(id: String, to name: String, fail: Bool = false) async throws -> String {
        renameLog.append("start:\(name)")
        defer { renameLog.append("end:\(name)") }
        await checkpoints.pass("rename:\(name)")
        if fail { throw ServerError(message: "rename failed") }
        users[id] = name
        return name
    }
}

@Model
final class TestUser {
    @Attribute(.unique)
    var id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

extension TestUser: QueryModel {
    struct SyncContext: Sendable {
        let server: FakeServer
        var saves = true
    }

    struct SyncState: Codable, Equatable {
        var etag: Int?
    }

    static var defaultState: SyncState { .init(etag: nil) }
    static var cache: QueryCache { .forever() }

    static func fetch(
        context: ModelContext,
        syncContext: SyncContext,
        syncState: inout SyncState
    ) async throws -> Task<Void, Never>? {
        let response = try await syncContext.server.list(etag: syncState.etag)
        try context.delete(model: TestUser.self)
        for (id, name) in response.users {
            context.insert(TestUser(id: id, name: name))
        }
        if syncContext.saves {
            try context.save()
        }
        syncState.etag = response.etag
        return await syncContext.server.makeStream()
    }

    static func evict(context: ModelContext) throws {
        try context.delete(model: TestUser.self)
    }
}

@Model
final class TestPost {
    var title: String
    init(title: String) { self.title = title }
}

extension TestPost: QueryModel {
    typealias SyncContext = Void
    struct SyncState: Codable {}
    static var defaultState: SyncState { .init() }
    static var cache: QueryCache { .swr() }
    static func fetch(context: ModelContext, syncContext: Void, syncState: inout SyncState) async throws -> Task<Void, Never>? {
        nil
    }
}

@MainActor
func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: TestUser.self, TestPost.self, TestFeed.self, TestNote.self, QueryRecord.self,
        configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
    )
}

@MainActor
func makeProvider(
    _ container: ModelContainer? = nil,
    server: FakeServer = FakeServer(),
    saves: Bool = true
) throws -> (QueryProvider, ModelQueryClient<TestUser>, FakeServer) {
    let provider = QueryProvider(
        modelContainer: try container ?? makeContainer(),
        for: .model(TestUser.self, .init(server: server, saves: saves))
    )
    return (provider, provider.client(for: TestUser.self), server)
}

@MainActor
func localUsers(_ client: ModelQueryClient<TestUser>) throws -> [String: String] {
    let users = try client.modelContainer.mainContext.fetch(FetchDescriptor<TestUser>())
    return Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0.name) })
}

/// A flag that observation callbacks can set from any isolation.
final class Flag: @unchecked Sendable {
    var value = false
}

/// Lets tests hold a fake request in flight and wait for it to start, instead of sleeping.
actor Checkpoints {
    private var held: Set<String> = []
    private var reachedCounts: [String: Int] = [:]
    private var reachWaiters: [String: [(count: Int, continuation: CheckedContinuation<Void, Never>)]] = [:]
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Requests reaching `key` from now on wait until it is released.
    func hold(_ key: String) {
        held.insert(key)
    }

    /// Lets every request waiting at `key` continue, and stops holding new ones.
    func release(_ key: String) {
        held.remove(key)
        for waiter in releaseWaiters.removeValue(forKey: key) ?? [] {
            waiter.resume()
        }
    }

    /// Waits until requests have reached `key` at least `count` times in total.
    func reached(_ key: String, count: Int = 1) async {
        guard reachedCounts[key, default: 0] < count else { return }
        await withCheckedContinuation { continuation in
            reachWaiters[key, default: []].append((count, continuation))
        }
    }

    /// Called by fake requests: records the arrival, then waits if `key` is held.
    func pass(_ key: String) async {
        let total = reachedCounts[key, default: 0] + 1
        reachedCounts[key] = total
        let waiters = reachWaiters[key] ?? []
        reachWaiters[key] = waiters.filter { $0.count > total }
        for waiter in waiters where waiter.count <= total {
            waiter.continuation.resume()
        }
        if held.contains(key) {
            await withCheckedContinuation { continuation in
                releaseWaiters[key, default: []].append(continuation)
            }
        }
    }
}

/// Waits until `condition` holds, yielding between checks. The deadline is only a safety net
/// against hangs; ordering never depends on it.
@MainActor
func eventually(
    _ condition: @MainActor () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        if ContinuousClock.now >= deadline {
            Issue.record("Condition was never met", sourceLocation: sourceLocation)
            return
        }
        await Task.yield()
    }
}

/// A model whose eviction always fails, to check that a failed eviction never leaves
/// metadata claiming deleted data is fresh.
@Model
final class TestNote {
    var text: String
    init(text: String) { self.text = text }
}

struct EvictionError: Error {}

extension TestNote: QueryModel {
    struct SyncContext: Sendable {
        let server: FakeServer
    }
    struct SyncState: Codable, Equatable {
        var etag: Int?
    }
    static var defaultState: SyncState { .init() }
    static var cache: QueryCache { .forever() }

    static func fetch(
        context: ModelContext,
        syncContext: SyncContext,
        syncState: inout SyncState
    ) async throws -> Task<Void, Never>? {
        let response = try await syncContext.server.list(etag: syncState.etag)
        try context.delete(model: TestNote.self)
        context.insert(TestNote(text: "note"))
        syncState.etag = response.etag
        return nil
    }

    static func evict(context: ModelContext) throws {
        throw EvictionError()
    }
}
