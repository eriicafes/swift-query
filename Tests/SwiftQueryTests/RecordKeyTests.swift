import Foundation
import SwiftData
import Testing
@testable import SwiftQuery

/// A fetcher keyed by a set.
struct TestTagged: QueryFetcher {
    let tags: Set<String>
    var cache: QueryCache? { .forever() }
    func fetch(query: QueryFetch<Void, Int>) async throws -> Int { 0 }
}

/// A key `JSONEncoder` can't write as an object, so a dictionary keyed by it is an array.
struct SampleGridPoint: Codable, Hashable, Sendable {
    var x: Int
    var y: Int
}

/// A fetcher keyed by a dictionary whose keys aren't strings or integers.
struct TestGrid: QueryFetcher {
    let cells: [SampleGridPoint: String]
    var cache: QueryCache? { .forever() }
    func fetch(query: QueryFetch<Void, Int>) async throws -> Int { 0 }
}

/// Counts fetches and evictions per key, across providers.
final class Tally: @unchecked Sendable {
    static let shared = Tally()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func add(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name, default: 0] } }
}

/// A fetcher whose type name contains colons when `T` is a labeled tuple.
struct TestPhantom<T>: QueryFetcher {
    let id: String
    let expires: Bool

    var cache: QueryCache? { expires ? .swr(staleTime: .seconds(3600), gcTime: .zero) : .forever() }

    func fetch(query: QueryFetch<Void, Int>) async throws -> Int {
        Tally.shared.add("fetch-\(id)")
        return (query.previous ?? 0) + 1
    }

    func evict(query: QueryEvict<Void>) throws {
        Tally.shared.add("evict-\(id)")
    }
}

typealias LabeledPhantom = TestPhantom<(a: Int, b: Int)>

// Values covering what `JSONEncoder` formats itself, for comparing output.

enum SampleShape: Codable, Hashable {
    case circle(radius: Double)
    case polygon([Int], label: String?)
    case empty
}

class SampleBase: Codable {
    var base = "base/value"
    init() {}
}

/// Encodes its superclass through `superEncoder()`.
final class SampleDerived: SampleBase {
    var extra = [1, 2, 3]

    enum CodingKeys: String, CodingKey { case extra }

    override init() { super.init() }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extra = try container.decode([Int].self, forKey: .extra)
        try super.init(from: container.superDecoder())
    }

    override func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(extra, forKey: .extra)
        try super.encode(to: container.superEncoder())
    }
}

/// Writes nested containers by hand, in an order unlike synthesized code.
struct SampleHandwritten: Encodable {
    enum Keys: String, CodingKey { case z, a, list }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        var list = container.nestedUnkeyedContainer(forKey: .list)
        try list.encode(1)
        try list.encodeNil()
        var inner = list.nestedContainer(keyedBy: Keys.self)
        try inner.encode("inner", forKey: .z)
        var deeper = list.nestedUnkeyedContainer()
        try deeper.encode(true)
        try encodeSuper(list.superEncoder())
        try container.encode(2.5, forKey: .z)
        var nested = container.nestedContainer(keyedBy: Keys.self, forKey: .a)
        try nested.encodeNil(forKey: .a)
    }

    private func encodeSuper(_ encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("from super")
    }
}

struct SampleEmpty: Codable {}

struct SampleWide: Codable {
    var text = "quote \" backslash \\ slash / tab \t newline \n emoji 🙂 accent é \u{0001}"
    var bool = true
    var int = Int.min
    var int8 = Int8.max
    var uint64 = UInt64.max
    var double = 0.1
    var whole = 1.0
    var huge = 1e300
    var tiny = -2.5e-12
    var float: Float = 0.1
    var decimal = Decimal(string: "12345678901234567890.123")!
    var date = Date(timeIntervalSinceReferenceDate: 123_456.789)
    var data = Data([0, 1, 2, 250, 255])
    var url = URL(string: "https://example.com/a/b?c=d")!
    var optional: String? = nil
    var present: String? = "here"
    var array = [[1, 2], [], [3]]
    var strings = ["b": 2, "a": 1, "c": 3]
    var ints = [10: "ten", 2: "two", -1: "minus"]
    var shapes: [SampleShape] = [.circle(radius: 2), .polygon([1, 2], label: nil), .empty]
    var empty = SampleEmpty()
}

@MainActor
@Suite("Record keys")
struct RecordKeyTests {
    func jsonEncoderOutput<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func keyEncoderOutput<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try QueryRecordKeyEncoder.encode(value), as: UTF8.self)
    }

    @Test("Values without unordered collections encode exactly as JSONEncoder does, so stored keys don't change")
    func matchesJSONEncoder() throws {
        #expect(try keyEncoderOutput(SampleWide()) == jsonEncoderOutput(SampleWide()))
        #expect(try keyEncoderOutput(SampleDerived()) == jsonEncoderOutput(SampleDerived()))
        #expect(try keyEncoderOutput(SampleHandwritten()) == jsonEncoderOutput(SampleHandwritten()))
        #expect(try keyEncoderOutput(SampleEmpty()) == jsonEncoderOutput(SampleEmpty()))
        #expect(try keyEncoderOutput(SampleShape.polygon([3], label: "x")) == jsonEncoderOutput(SampleShape.polygon([3], label: "x")))
        #expect(try keyEncoderOutput("top level") == jsonEncoderOutput("top level"))
        #expect(try keyEncoderOutput(TestDetail(id: "42")) == jsonEncoderOutput(TestDetail(id: "42")))
    }

    @Test("Equal sets give the same key whatever their insertion order or capacity")
    func setKeys() throws {
        let letters = (0..<26).map { String(UnicodeScalar(UInt8(97 + $0))) }
        let forward = Set(letters)
        var backward = Set<String>(minimumCapacity: 1000)
        for letter in letters.reversed() {
            backward.insert(letter)
        }
        #expect(forward == backward)

        let key = QueryRecord.Key.make(TestTagged(tags: forward))
        #expect(key == QueryRecord.Key.make(TestTagged(tags: backward)))
        let sorted = letters.map { "\"\($0)\"" }.joined(separator: ",")
        #expect(key == #"[""# + String(reflecting: TestTagged.self) + #"",{"tags":["# + sorted + "]}]")
        #expect(QueryRecord.Key.decode(TestTagged.self, from: key) == TestTagged(tags: forward))
        #expect(QueryFilter.key(TestTagged(tags: forward)) == QueryFilter.key(TestTagged(tags: backward)))
    }

    @Test("Dictionaries written as key-value arrays give the same key whatever their order")
    func dictionaryKeys() throws {
        var forward: [SampleGridPoint: String] = [:]
        var backward = [SampleGridPoint: String](minimumCapacity: 1000)
        let points = (0..<20).map { SampleGridPoint(x: $0 % 5, y: $0 / 5) }
        for point in points {
            forward[point] = "\(point.x),\(point.y)"
        }
        for point in points.reversed() {
            backward[point] = "\(point.x),\(point.y)"
        }

        let key = QueryRecord.Key.make(TestGrid(cells: forward))
        #expect(key == QueryRecord.Key.make(TestGrid(cells: backward)))
        #expect(QueryRecord.Key.decode(TestGrid.self, from: key) == TestGrid(cells: forward))
    }

    @Test("Sets nested in arrays and enums are ordered too")
    func nestedSets() throws {
        let a: [Set<Int>] = [Set(0..<50), [7]]
        var shuffled = Set<Int>(minimumCapacity: 500)
        for value in (0..<50).reversed() { shuffled.insert(value) }
        let b: [Set<Int>] = [shuffled, [7]]
        #expect(try keyEncoderOutput(a) == keyEncoderOutput(b))
        #expect(try keyEncoderOutput(a) == "[[" + (0..<50).map(String.init).sorted().joined(separator: ",") + "],[7]]")
    }

    @Test("A type name containing colons is never parsed out of a key: filters use the stored type")
    func colonTypeNames() throws {
        let name = String(reflecting: LabeledPhantom.self)
        #expect(name.contains(":"))
        let fetcher = LabeledPhantom(id: "x", expires: false)
        let key = QueryRecord.Key.make(fetcher)
        #expect(QueryRecord.Key.typeName(LabeledPhantom.self) == name)
        // The key is a JSON array whose first element is exactly the type name.
        let parts = try JSONSerialization.jsonObject(with: Data(key.utf8)) as? [Any]
        #expect(parts?.first as? String == name)
        #expect(parts?.count == 2)
        #expect(QueryRecord.Key.decode(LabeledPhantom.self, from: key) == fetcher)
        #expect(QueryRecord.Key.decode(TestDetail.self, from: key) == nil)
        #expect(QueryFilter.type(LabeledPhantom.self).matches(key: key, type: name, tags: []))
        #expect(!QueryFilter.type(TestDetail.self).matches(key: key, type: name, tags: []))
        #expect(QueryFilter.type(LabeledPhantom.self).overlaps(.key(fetcher)))
        #expect(!QueryFilter.type(TestDetail.self).overlaps(.key(fetcher)))
    }

    @Test("Type filters match a record's stored type, not its key's text")
    func typeFiltersUseStoredType() async throws {
        let (provider, _, _) = try makeProvider()
        let detailKey = QueryRecord.Key.make(TestDetail(id: "1"))
        // A key naming TestDetail, stored as another type's.
        let otherKey = #"[""# + String(reflecting: TestDetail.self) + #"",{"id":"2"}]"#
        let context = ModelContext(provider.modelContainer)
        context.insert(QueryRecord(key: otherKey, type: "Other.Type", stateData: Data("{}".utf8), lastSyncedAt: .now))
        context.insert(QueryRecord(key: detailKey, type: String(reflecting: TestDetail.self), stateData: Data("{}".utf8), lastSyncedAt: .now))
        try context.save()

        await provider.invalidate(.type(TestDetail.self), refetch: nil)
        let records = try ModelContext(provider.modelContainer).fetch(FetchDescriptor<QueryRecord>())
        #expect(records.first { $0.key == detailKey }?.invalidated == true)
        #expect(records.first { $0.key == otherKey }?.invalidated == false)
    }

    @Test("Stored keys of a type whose name contains colons are refetched and evicted")
    func colonTypeNamesInStore() async throws {
        let container = try makeContainer()
        let kept = LabeledPhantom(id: "colon-kept", expires: false)
        let expiring = LabeledPhantom(id: "colon-expiring", expires: true)
        let first = QueryProvider(modelContainer: container, fetchers: LabeledPhantom.self)
        #expect(try await first.query(kept) == 1)
        #expect(try await first.query(expiring) == 1)

        // A second provider sees both keys only in the store: its launch sweep evicts the
        // expired one through the type's `evict`, and an inactive refetch finds the other.
        let second = QueryProvider(modelContainer: container, fetchers: LabeledPhantom.self)
        await second.waitForGarbageCollection()
        #expect(Tally.shared.count("evict-colon-expiring") == 1)
        #expect(try ModelContext(container).fetch(QueryRecord.descriptor(key: QueryRecord.Key.make(expiring))).isEmpty)

        await second.refetch(.type(LabeledPhantom.self), type: .inactive)
        #expect(Tally.shared.count("fetch-colon-kept") == 2)
        #expect(second.getQueryData(for: kept) == 2)
        _ = first
    }
}
