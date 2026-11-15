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
    /// How many streams started and how many ended (by cancellation).
    private(set) var streamsStarted = 0
    private(set) var streamsEnded = 0
    /// "start:<name>" and "end:<name>" for each rename, in order.
    private(set) var renameLog: [String] = []
    private var etag = 0
    private var failures: [any Error] = []

    init(users: [String: String] = ["1": "Ada", "2": "Grace"]) {
        self.users = users
    }

    func failNextFetch(_ error: any Error = ServerError()) { failures.append(error) }

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

    /// A stream that stays open until its task is cancelled.
    func stream() async {
        streamsStarted += 1
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        streamsEnded += 1
    }

    /// A stream that ends on its own right away.
    func shortStream() {
        streamsStarted += 1
        streamsEnded += 1
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
    struct Context: Sendable {
        let server: FakeServer
        var saves = true
        var streams = false
    }

    struct QueryData: Codable, Equatable {
        var etag: Int?
    }

    static var cache: QueryCache { .forever() }

    static func fetch(
        context: ModelContext,
        fetchContext: Context,
        previous: QueryData?
    ) async throws -> QueryData {
        let response = try await fetchContext.server.list(etag: previous?.etag)
        try context.delete(model: TestUser.self)
        for (id, name) in response.users {
            context.insert(TestUser(id: id, name: name))
        }
        if fetchContext.saves {
            try context.save()
        }
        return QueryData(etag: response.etag)
    }

    static func subscribe(
        container: ModelContainer,
        fetchContext: Context,
        previous: QueryData?,
        writer: QueryDataWriter<QueryData>
    ) -> Task<Void, Never>? {
        guard fetchContext.streams else { return nil }
        let server = fetchContext.server
        return Task { await server.stream() }
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
    static var cache: QueryCache { .swr() }
    static func fetch(context: ModelContext, fetchContext: Void, previous: Int?) async throws -> Int { 0 }
}

@MainActor
func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: TestUser.self, TestPost.self, TestFeed.self, TestNote.self, TestProfile.self, QueryRecord.self,
        configurations: ModelConfiguration(UUID().uuidString, isStoredInMemoryOnly: true)
    )
}

typealias UsersClient = ModelQueryClient<ModelFetcher<TestUser>>

@MainActor
func makeProvider(
    _ container: ModelContainer? = nil,
    server: FakeServer = FakeServer(),
    saves: Bool = true,
    streams: Bool = false,
    gracePeriod: Duration = .seconds(300)
) throws -> (QueryProvider, UsersClient, FakeServer) {
    let provider = QueryProvider(
        modelContainer: try container ?? makeContainer(),
        contexts: TestUser.Context(server: server, saves: saves, streams: streams),
        fetchers: TestUser.self, TestDetail.self,
        gracePeriod: gracePeriod
    )
    return (provider, provider.client(for: TestUser.self), server)
}

@MainActor
func localUsers(_ client: UsersClient) throws -> [String: String] {
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
    struct Context: Sendable {
        let server: FakeServer
    }
    struct QueryData: Codable, Equatable {
        var etag: Int?
    }
    static var cache: QueryCache { .forever() }

    static func fetch(
        context: ModelContext,
        fetchContext: Context,
        previous: QueryData?
    ) async throws -> QueryData {
        let response = try await fetchContext.server.list(etag: previous?.etag)
        try context.delete(model: TestNote.self)
        context.insert(TestNote(text: "note"))
        return QueryData(etag: response.etag)
    }

    static func evict(context: ModelContext) throws {
        throw EvictionError()
    }
}

/// A row a fetcher writes, owned by that fetcher's key.
@Model
final class TestProfile {
    var userID: String
    var bio: String
    init(userID: String, bio: String) {
        self.userID = userID
        self.bio = bio
    }
}

/// A persisted fetcher key: one user's profile, tagged with the users collection.
struct TestDetail: QueryFetcher {
    let id: String

    struct QueryData: Codable, Equatable {
        var version = 0
    }

    var cache: QueryCache? { .swr(staleTime: .seconds(3600)) }
    var tags: Set<String> { ["users", "user-\(id)"] }

    func fetch(context: ModelContext, fetchContext: TestUser.Context, previous: QueryData?) async throws -> QueryData {
        let id = id
        let response = try await fetchContext.server.list(etag: nil)
        try context.delete(model: TestProfile.self, where: #Predicate { $0.userID == id })
        context.insert(TestProfile(userID: id, bio: response.users[id] ?? "unknown"))
        return QueryData(version: response.etag)
    }

    func subscribe(
        container: ModelContainer,
        fetchContext: TestUser.Context,
        previous: QueryData?,
        writer: QueryDataWriter<QueryData>
    ) -> Task<Void, Never>? {
        guard fetchContext.streams else { return nil }
        let server = fetchContext.server
        return Task { await server.stream() }
    }

    func evict(context: ModelContext) throws {
        let id = id
        try context.delete(model: TestProfile.self, where: #Predicate { $0.userID == id })
    }
}

/// A source of rates, registered by protocol type.
protocol RateSource: Sendable {
    func rate(from: String, to: String) async throws -> Double
}

actor FakeRates: RateSource {
    nonisolated let checkpoints = Checkpoints()
    private(set) var requests: [String] = []
    private var failures = 0

    func failNext() { failures += 1 }

    func rate(from: String, to: String) async throws -> Double {
        requests.append("\(from)-\(to)")
        await checkpoints.pass("rate")
        if failures > 0 {
            failures -= 1
            throw ServerError()
        }
        return Double(requests.count)
    }
}

/// An in-memory fetcher whose state is the data itself.
struct TestRate: QueryFetcher {
    let from: String
    let to: String
    var cache: QueryCache? { nil }

    func fetch(context: ModelContext, fetchContext: any RateSource, previous: Double?) async throws -> Double {
        try await fetchContext.rate(from: from, to: to)
    }
}

/// A persisted fetcher whose state is the data itself.
struct TestStoredRate: QueryFetcher {
    let from: String
    var cache: QueryCache? { .forever() }
    var tags: Set<String> { ["rates"] }

    func fetch(context: ModelContext, fetchContext: any RateSource, previous: Double?) async throws -> Double {
        try await fetchContext.rate(from: from, to: "EUR")
    }
}

/// A context the provider builds itself.
struct DefaultCounter: DefaultFetchContext {
    let value = 7
}

struct TestDefaulted: QueryFetcher {
    var cache: QueryCache? { nil }
    func fetch(context: ModelContext, fetchContext: DefaultCounter, previous: Int?) async throws -> Int {
        fetchContext.value
    }
}

extension QueryModel {
    /// The model's record key.
    static var queryKey: String { String(reflecting: Self.self) }
}
