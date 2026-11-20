import Foundation
import SwiftData

/// Bulk work on stored records of keys without a live client, off the main actor.
///
/// Each call uses a fresh context and saves once, so a batch over many records is one write.
/// The provider orders calls and makes clients created meanwhile wait for the ones covering
/// their key; see ``QueryProvider``.
actor QueryRecordStore {
    /// Decodes a key and runs its type's `evict`.
    typealias Evictor = @Sendable (_ key: String, _ context: ModelContext) throws -> Void
    /// Whether a key is one its type still produces: it decodes, and its value encodes back to
    /// the same key. A key stored before the type's stored properties changed fails, even when
    /// it still decodes.
    typealias KeyCheck = @Sendable (_ key: String) -> Bool

    private let container: ModelContainer
    /// The listed types' evictors, by type name.
    private let evictors: [String: Evictor]
    /// The listed types' key checks, by type name.
    private let keyChecks: [String: KeyCheck]

    init(container: ModelContainer, evictors: [String: Evictor], keyChecks: [String: KeyCheck]) {
        self.container = container
        self.evictors = evictors
        self.keyChecks = keyChecks
    }

    // MARK: Reading

    /// Keys matching any of `filters`, except `excluded` ones, that have state.
    func keysWithState(matching filters: [QueryFilter], except excluded: Set<String>) -> [StoredKey] {
        let context = newContext()
        return records(matching: filters, except: excluded, in: context, properties: [\.key, \.type], withState: true)
            .map(StoredKey.init)
            .uniqued()
    }

    /// Keys whose SWR cache expired at `now`, except `excluded` ones.
    func expiredKeys(except excluded: Set<String>, now: Date) -> [StoredKey] {
        let context = newContext()
        var descriptor = FetchDescriptor<QueryRecord>(predicate: #Predicate { $0.gcTime != nil && $0.stateData != nil })
        descriptor.propertiesToFetch = [\.key, \.type, \.gcTime, \.lastAccessedAt, \.lastSyncedAt]
        let records = (try? context.fetch(descriptor)) ?? []
        return records
            .filter { !excluded.contains($0.key) && !QueryRecord.Key.isMarker($0.key) && Self.isExpired($0, now: now) }
            .map(StoredKey.init)
            .uniqued()
    }

    /// Keys no client can ever use again, except `excluded` ones: those of types that aren't
    /// listed, and those their listed type can no longer produce, after its stored properties
    /// changed. Types and their shapes only change between launches, so this runs at launch.
    func orphanedKeys(except excluded: Set<String>) -> [StoredKey] {
        let context = newContext()
        var descriptor = FetchDescriptor<QueryRecord>()
        descriptor.propertiesToFetch = [\.key, \.type]
        let records = (try? context.fetch(descriptor)) ?? []
        return records
            .filter { record in
                guard !excluded.contains(record.key), !QueryRecord.Key.isMarker(record.key) else { return false }
                guard let check = keyChecks[record.type] else { return true }
                return !check(record.key)
            }
            .map(StoredKey.init)
            .uniqued()
    }

    // MARK: Writing

    /// Marks keys matching any of `filters`, except `excluded` ones, as invalidated, saving once.
    /// If that save fails, each key is marked and saved on its own. Returns whether every key
    /// was marked.
    @discardableResult
    func markInvalidated(_ filters: [QueryFilter], except excluded: Set<String>) -> Bool {
        let context = newContext()
        let records = records(matching: filters, except: excluded, in: context, properties: [\.key, \.invalidated])
            .filter { !$0.invalidated }
        guard !records.isEmpty else { return true }
        let keys = Set(records.map(\.key))
        for record in records {
            record.invalidated = true
        }
        if (try? context.save()) != nil { return true }
        context.rollback()
        var marked = true
        for key in keys {
            let single = newContext()
            for record in (try? single.fetch(QueryRecord.descriptor(key: key))) ?? [] {
                record.invalidated = true
            }
            if (try? single.save()) == nil {
                marked = false
            }
        }
        return marked
    }

    /// Evicts keys matching any of `filters`, except `excluded` ones.
    func evict(matching filters: [QueryFilter], except excluded: Set<String>) -> Evicted {
        let context = newContext()
        return evict(records(matching: filters, except: excluded, in: context, properties: [\.key, \.type, \.tags]), in: context)
    }

    /// Evicts `keys` whose SWR cache is still expired at `now`. A key used since it was found
    /// expired is kept.
    func evictExpired(_ keys: [String], now: Date) -> Evicted {
        guard !keys.isEmpty else { return Evicted() }
        let context = newContext()
        var descriptor = FetchDescriptor<QueryRecord>(predicate: #Predicate {
            keys.contains($0.key) && $0.gcTime != nil && $0.stateData != nil
        })
        descriptor.propertiesToFetch = [\.key, \.type, \.tags, \.gcTime, \.lastAccessedAt, \.lastSyncedAt]
        let records = ((try? context.fetch(descriptor)) ?? []).filter { Self.isExpired($0, now: now) }
        return evict(records, in: context)
    }

    /// Deletes the records of orphaned `keys`, saving once, or one key at a time if that fails.
    /// Nothing is evicted: an unlisted type has no `evict`, and an outdated key may decode to a
    /// current one, whose rows its `evict` would delete.
    func deleteOrphans(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        let context = newContext()
        let descriptor = FetchDescriptor<QueryRecord>(predicate: #Predicate { keys.contains($0.key) })
        for record in (try? context.fetch(descriptor)) ?? [] {
            context.delete(record)
        }
        guard context.hasChanges else { return }
        if (try? context.save()) != nil { return }
        context.rollback()
        for key in keys {
            let single = newContext()
            for record in (try? single.fetch(QueryRecord.descriptor(key: key))) ?? [] {
                single.delete(record)
            }
            if single.hasChanges {
                try? single.save()
            }
        }
    }

    // MARK: Helpers

    /// Deletes the records, saving once, then runs the listed types' `evict` for each key whose
    /// record was deleted. If the batch can't be saved, each key is evicted on its own so one bad
    /// record doesn't keep the rest.
    private func evict(_ records: [QueryRecord], in context: ModelContext) -> Evicted {
        guard !records.isEmpty else { return Evicted() }
        var batch = Evicted()
        var types: [String: String] = [:]
        for record in records {
            batch.add(record.key, tags: QueryRecord.Tags.decode(record.tags))
            types[record.key] = record.type
            context.delete(record)
        }
        if (try? context.save()) != nil {
            runEvictors(for: types)
            return batch
        }
        context.rollback()
        var evicted = Evicted()
        var evictedTypes: [String: String] = [:]
        for key in batch.keys {
            let single = newContext()
            let records = (try? single.fetch(QueryRecord.descriptor(key: key))) ?? []
            guard let first = records.first else { continue }
            let tags = QueryRecord.Tags.decode(first.tags)
            let type = first.type
            for record in records {
                single.delete(record)
            }
            if (try? single.save()) != nil {
                evicted.add(key, tags: tags)
                evictedTypes[key] = type
            }
        }
        runEvictors(for: evictedTypes)
        return evicted
    }

    /// Runs the `evict` of each key's listed type, given by `types` (key to type name), in one
    /// context saved once. If one throws or the save fails, everything is undone and each key
    /// runs in its own context, so a failing `evict` only loses its own changes.
    private func runEvictors(for types: [String: String]) {
        let listed = types.keys.sorted().compactMap { key in
            types[key].flatMap { evictors[$0] }.map { (key, $0) }
        }
        guard !listed.isEmpty else { return }
        let context = newContext()
        do {
            for (key, evict) in listed {
                try evict(key, context)
            }
            if context.hasChanges {
                try context.save()
            }
            return
        } catch {
            context.rollback()
        }
        for (key, evict) in listed {
            let single = newContext()
            if (try? evict(key, single)) != nil, single.hasChanges {
                try? single.save()
            }
        }
    }

    /// Records matching any of `filters`, except `excluded` keys and pending mutation markers,
    /// each once, and with `withState` only those that have state. Only `properties` are loaded
    /// up front.
    private func records(
        matching filters: [QueryFilter],
        except excluded: Set<String>,
        in context: ModelContext,
        properties: [PartialKeyPath<QueryRecord>],
        withState: Bool = false
    ) -> [QueryRecord] {
        var seen = Set<PersistentIdentifier>()
        var records: [QueryRecord] = []
        for filter in filters {
            var descriptor = withState ? filter.descriptorWithState() : filter.descriptor()
            descriptor.propertiesToFetch = properties
            for record in (try? context.fetch(descriptor)) ?? []
            where !excluded.contains(record.key) && !QueryRecord.Key.isMarker(record.key)
                && seen.insert(record.persistentModelID).inserted {
                records.append(record)
            }
        }
        return records
    }

    private func newContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    /// Whether a record already known to have state expired under its stored `gcTime`, checked
    /// without loading the state.
    private static func isExpired(_ record: QueryRecord, now: Date) -> Bool {
        guard let gcTime = record.gcTime, let lastUse = record.lastAccessedAt ?? record.lastSyncedAt else { return false }
        return now >= lastUse.addingTimeInterval(gcTime)
    }
}

/// A stored record's key and its type's name.
struct StoredKey: Hashable, Sendable {
    let key: String
    let type: String

    init(_ record: QueryRecord) {
        key = record.key
        type = record.type
    }

    var keyFilter: QueryFilter { QueryFilter(key: key, type: type) }
}

/// The keys evicted in one batch and their tags, for invalidating the keys that share them.
struct Evicted: Sendable {
    private(set) var keys: Set<String> = []
    private(set) var tags: Set<String> = []

    mutating func add(_ key: String, tags: Set<String>) {
        keys.insert(key)
        self.tags.formUnion(tags)
    }

    mutating func formUnion(_ other: Evicted) {
        keys.formUnion(other.keys)
        tags.formUnion(other.tags)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
