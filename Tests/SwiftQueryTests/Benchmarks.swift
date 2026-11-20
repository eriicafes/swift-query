import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

/// Times the provider's bulk operations over many stored keys, and how long they block the main
/// actor. Skipped unless `SWIFTQUERY_BENCH` is set; run in release for realistic numbers:
///
/// ```sh
/// SWIFTQUERY_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter Benchmarks
/// ```
///
/// `SWIFTQUERY_BENCH_SIZES` (comma-separated record counts) and `SWIFTQUERY_BENCH_BYTES`
/// (comma-separated state sizes) override the defaults.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTQUERY_BENCH"] != nil))
@MainActor
struct Benchmarks {
    enum Operation: String, CaseIterable {
        case invalidateTag = "invalidate(.tag)"
        case refetchInactiveNoData = "refetch(.inactive), no data"
        case collectGarbage = "collectGarbage()"
        case collectGarbageUnlisted = "collectGarbage(), no evict"
        case removeAll = "remove(.all)"
    }

    static let sizes = list("SWIFTQUERY_BENCH_SIZES", default: [1_000, 5_000])
    static let stateBytes = list("SWIFTQUERY_BENCH_BYTES", default: [256, 16_384])

    @Test("Bulk operations over stored keys")
    func bulkOperations() async throws {
        var rows: [String] = []
        for count in Self.sizes {
            for bytes in Self.stateBytes {
                for operation in Operation.allCases {
                    let result = try await measure(operation, count: count, bytes: bytes)
                    rows.append(
                        "\(operation.rawValue.padding(toLength: 28, withPad: " ", startingAt: 0))"
                            + " records \(String(count).leftPad(6))"
                            + "  state \(String(bytes).leftPad(6)) B"
                            + "  total \(result.total.ms.leftPad(9))"
                            + "  longest main-actor stall \(result.stall.ms.leftPad(9))"
                    )
                }
            }
        }
        print("\n" + rows.joined(separator: "\n") + "\n")
    }

    /// Seeds `count` stored keys with no client, then runs `operation` once.
    private func measure(_ operation: Operation, count: Int, bytes: Int) async throws -> (total: Duration, stall: Duration) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftquery-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(
            for: TestUser.self, TestPost.self, TestFeed.self, TestNote.self, TestProfile.self, QueryRecord.self,
            configurations: ModelConfiguration(url: directory.appending(path: "bench.store"))
        )
        let (provider, _, _) = try makeProvider(container)
        await provider.waitForGarbageCollection()

        // Every key is expired, so garbage collection evicts all of them. Records have data
        // unless the operation needs keys without it.
        let state = operation == .refetchInactiveNoData ? nil : Data(repeating: 0x61, count: bytes)
        let seed = ModelContext(container)
        for index in 0..<count {
            let id = String(index)
            seed.insert(TestProfile(userID: id, bio: "user \(id)"))
            // An unlisted type's records are deleted without running `evict`.
            let key = operation == .collectGarbageUnlisted
                ? #"["Gone.Fetcher",{"id":""# + id + #""}]"#
                : QueryRecord.Key.make(TestDetail(id: id))
            seed.insert(QueryRecord(
                key: key,
                type: operation == .collectGarbageUnlisted ? "Gone.Fetcher" : String(reflecting: TestDetail.self),
                stateData: state,
                lastSyncedAt: .distantPast,
                tags: QueryRecord.Tags.encode(TestDetail(id: id).tags),
                gcTime: 0
            ))
        }
        try seed.save()

        let watcher = StallWatcher()
        watcher.start()
        let clock = ContinuousClock()
        let start = clock.now
        switch operation {
        case .invalidateTag: await provider.invalidate(.tag("users"))
        case .refetchInactiveNoData: await provider.refetch(.all, type: .inactive)
        case .collectGarbage, .collectGarbageUnlisted: await provider.collectGarbage()
        case .removeAll: await provider.remove(.all)
        }
        let total = clock.now - start
        let stall = await watcher.stop()
        return (total, stall)
    }

    private static func list(_ name: String, default value: [Int]) -> [Int] {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return value }
        let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parsed.isEmpty ? value : parsed
    }
}

/// Measures the longest gap between main-actor ticks scheduled every millisecond, so work that
/// blocks the main actor shows up even when the operation itself is async.
@MainActor
private final class StallWatcher {
    private var task: Task<Duration, Never>?
    private var running = false

    func start() {
        running = true
        // Taken now, so an operation that blocks before the first tick still counts.
        let clock = ContinuousClock()
        let started = clock.now
        task = Task { @MainActor [unowned self] in
            var longest = Duration.zero
            var last = started
            while running {
                try? await Task.sleep(for: .milliseconds(1))
                let now = clock.now
                longest = max(longest, now - last)
                last = now
            }
            return longest
        }
    }

    func stop() async -> Duration {
        // Let a tick that was blocked by the operation record its gap first.
        try? await Task.sleep(for: .milliseconds(5))
        running = false
        return await task?.value ?? .zero
    }
}

private extension Duration {
    var ms: String {
        let (seconds, attoseconds) = components
        let millis = Double(seconds) * 1_000 + Double(attoseconds) / 1e15
        return String(format: "%.1f ms", millis)
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
