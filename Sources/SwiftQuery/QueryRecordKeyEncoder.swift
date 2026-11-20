import Foundation

/// Encodes a fetcher for its record key.
///
/// Equal fetchers must always get the same key, in every process. `JSONEncoder` alone doesn't
/// ensure that: it writes a `Set`, and a dictionary whose key isn't a `String`, an `Int` or
/// `CodingKeyRepresentable` (as an array of keys and values), in iteration order, which depends
/// on the process's hash seed and on the collection's history. Here those list their elements
/// in a canonical order, sorted by each element's encoding.
///
/// Everything else is written exactly as `JSONEncoder` writes it with sorted keys and unescaped
/// slashes: the value is first encoded into a tree, which `JSONEncoder` then writes, so numbers,
/// strings, `Data`, `URL` and `Decimal` get its formatting, and `JSONDecoder` reads keys back to
/// refetch and evict keys that have no client.
enum QueryRecordKeyEncoder {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try write(jsonValue(value, codingPath: []))
    }

    fileprivate static func write(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    fileprivate static func jsonValue<T: Encodable>(_ value: T, codingPath: [any CodingKey]) throws -> JSONValue {
        let node = JSONNode()
        try encode(value, into: node, codingPath: codingPath)
        return node.freeze()
    }

    fileprivate static func encode<T: Encodable>(_ value: T, into node: JSONNode, codingPath: [any CodingKey]) throws {
        // Types `JSONEncoder` formats itself rather than through `encode(to:)`.
        if value is Data || value is URL || value is Decimal {
            node.content = .value(.leaf(value))
            return
        }
        if let unordered = value as? any UnorderedEncodable,
           let canonical = try unordered.canonicalValue(codingPath: codingPath) {
            node.content = .value(canonical)
            return
        }
        try value.encode(to: TreeEncoder(node: node, codingPath: codingPath))
    }

    fileprivate static func sortedByEncoding(_ values: [JSONValue]) throws -> [JSONValue] {
        try values
            .map { (value: $0, bytes: try write($0)) }
            .sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
            .map(\.value)
    }
}

// MARK: - Tree

/// An encoded value, written by `JSONEncoder` once complete.
fileprivate indirect enum JSONValue: Encodable {
    case null
    /// A value `JSONEncoder` formats itself: a primitive, `Data`, `URL` or `Decimal`.
    case leaf(any Encodable)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .leaf(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: AnyKey(key))
            }
        }
    }
}

/// A value being encoded. Containers hand out nested ones as references, so a nested container
/// written after its parent's other values still lands in the parent.
fileprivate final class JSONNode {
    enum Content {
        /// Nothing requested yet. `JSONEncoder` writes a value that encodes nothing as `{}`.
        case empty
        case value(JSONValue)
        case array([JSONNode])
        case object([String: JSONNode])
    }

    var content = Content.empty

    func freeze() -> JSONValue {
        switch content {
        case .empty: .object([:])
        case .value(let value): value
        case .array(let nodes): .array(nodes.map { $0.freeze() })
        case .object(let nodes): .object(nodes.mapValues { $0.freeze() })
        }
    }

    func ensureObject() {
        if case .object = content { return }
        content = .object([:])
    }

    func ensureArray() {
        if case .array = content { return }
        content = .array([])
    }

    func addChild(forKey key: String) -> JSONNode {
        ensureObject()
        let node = JSONNode()
        if case .object(var nodes) = content {
            nodes[key] = node
            content = .object(nodes)
        }
        return node
    }

    func appendChild() -> JSONNode {
        ensureArray()
        let node = JSONNode()
        if case .array(var nodes) = content {
            nodes.append(node)
            content = .array(nodes)
        }
        return node
    }

    var count: Int {
        if case .array(let nodes) = content { nodes.count } else { 0 }
    }
}

// MARK: - Unordered collections

/// A collection whose iteration order isn't determined by its value.
fileprivate protocol UnorderedEncodable {
    /// The value with its elements in canonical order, or `nil` to encode it normally.
    func canonicalValue(codingPath: [any CodingKey]) throws -> JSONValue?
}

extension Set: UnorderedEncodable where Element: Encodable {
    fileprivate func canonicalValue(codingPath: [any CodingKey]) throws -> JSONValue? {
        var elements: [JSONValue] = []
        for (index, element) in enumerated() {
            elements.append(try QueryRecordKeyEncoder.jsonValue(element, codingPath: codingPath + [AnyKey(index: index)]))
        }
        return .array(try QueryRecordKeyEncoder.sortedByEncoding(elements))
    }
}

extension Dictionary: UnorderedEncodable where Key: Encodable, Value: Encodable {
    fileprivate func canonicalValue(codingPath: [any CodingKey]) throws -> JSONValue? {
        // These are written as objects, whose keys `JSONEncoder` sorts. The same test as
        // `Dictionary.encode(to:)`.
        if Key.self == String.self || Key.self == Int.self || Key.self is any CodingKeyRepresentable.Type {
            return nil
        }
        // Otherwise `[key, value, key, value, ...]`, with pairs sorted by key, then by value for
        // keys that encode alike.
        var pairs: [(key: JSONValue, keyBytes: Data, value: JSONValue, valueBytes: Data)] = []
        for (index, (key, value)) in enumerated() {
            let encodedKey = try QueryRecordKeyEncoder.jsonValue(key, codingPath: codingPath + [AnyKey(index: index * 2)])
            let encodedValue = try QueryRecordKeyEncoder.jsonValue(value, codingPath: codingPath + [AnyKey(index: index * 2 + 1)])
            pairs.append((encodedKey, try QueryRecordKeyEncoder.write(encodedKey), encodedValue, try QueryRecordKeyEncoder.write(encodedValue)))
        }
        pairs.sort {
            $0.keyBytes != $1.keyBytes
                ? $0.keyBytes.lexicographicallyPrecedes($1.keyBytes)
                : $0.valueBytes.lexicographicallyPrecedes($1.valueBytes)
        }
        return .array(pairs.flatMap { [$0.key, $0.value] })
    }
}

// MARK: - Encoder

/// A coding key for an object's key or an array position.
fileprivate struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
    }

    init(index: Int) {
        stringValue = "Index \(index)"
        intValue = index
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.init(index: intValue)
    }
}

fileprivate struct TreeEncoder: Encoder {
    let node: JSONNode
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.ensureObject()
        return KeyedEncodingContainer(KeyedContainer<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        node.ensureArray()
        return UnkeyedContainer(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValueContainer(node: node, codingPath: codingPath)
    }
}

fileprivate struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: JSONNode
    let codingPath: [any CodingKey]

    mutating func encodeNil(forKey key: Key) throws {
        node.addChild(forKey: key.stringValue).content = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try QueryRecordKeyEncoder.encode(value, into: node.addChild(forKey: key.stringValue), codingPath: codingPath + [key])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = node.addChild(forKey: key.stringValue)
        child.ensureObject()
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(node: child, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let child = node.addChild(forKey: key.stringValue)
        child.ensureArray()
        return UnkeyedContainer(node: child, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> any Encoder {
        TreeEncoder(node: node.addChild(forKey: "super"), codingPath: codingPath + [AnyKey("super")])
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        TreeEncoder(node: node.addChild(forKey: key.stringValue), codingPath: codingPath + [key])
    }
}

fileprivate struct UnkeyedContainer: UnkeyedEncodingContainer {
    let node: JSONNode
    let codingPath: [any CodingKey]
    var count: Int { node.count }

    private var nextKey: AnyKey { AnyKey(index: count) }

    mutating func encodeNil() throws {
        node.appendChild().content = .value(.null)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let path = codingPath + [nextKey]
        try QueryRecordKeyEncoder.encode(value, into: node.appendChild(), codingPath: path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let path = codingPath + [nextKey]
        let child = node.appendChild()
        child.ensureObject()
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(node: child, codingPath: path))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let path = codingPath + [nextKey]
        let child = node.appendChild()
        child.ensureArray()
        return UnkeyedContainer(node: child, codingPath: path)
    }

    mutating func superEncoder() -> any Encoder {
        let path = codingPath + [nextKey]
        return TreeEncoder(node: node.appendChild(), codingPath: path)
    }
}

fileprivate struct SingleValueContainer: SingleValueEncodingContainer {
    let node: JSONNode
    let codingPath: [any CodingKey]

    mutating func encodeNil() throws { node.content = .value(.null) }
    mutating func encode(_ value: Bool) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: String) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: Double) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: Float) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: Int) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: Int8) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: Int16) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: Int32) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: Int64) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: UInt) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: UInt8) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: UInt16) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: UInt32) throws { node.content = .value(.leaf(value)) }
    mutating func encode(_ value: UInt64) throws { node.content = .value(.leaf(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try QueryRecordKeyEncoder.encode(value, into: node, codingPath: codingPath)
    }
}
