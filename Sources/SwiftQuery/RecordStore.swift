import Foundation
import SwiftData

/// Bulk work on stored records of keys without a live client, off the main actor.
///
/// Each call uses a fresh context and saves once, so a batch over many records is one write.
/// The provider orders calls and makes clients created meanwhile wait for the ones covering
/// their key; see ``QueryProvider``.
actor RecordStore {
    /// Decodes a key and runs its type's `evict`.
    typealias Evictor = @Sendable (_ key: String, _ context: ModelContext) throws -> Void

    private let container: ModelContainer
    /// The listed types' evictors, by type name.
    private let evictors: [String: Evictor]

    init(container: ModelContainer, evictors: [String: Evictor]) {
        self.container = container
        self.evictors = evictors
    }

    // MARK: Reading

    /// Keys matching any of `filters`, except `excluded` ones, that have state.
    func keysWithState(matching filters: [QueryFilter], except excluded: Set<String>) -> [String] {
        let context = newContext()
        return records(matching: filters, except: excluded, in: context, properties: [\.key], withState: true)
            .map(\.key)
            .uniqued()
    }

    /// Keys whose SWR cache expired at `now`, except `excluded` ones.
    func expiredKeys(except excluded: Set<String>, now: Date) -> [String] {
        let context = newContext()
        var descriptor = FetchDescriptor<QueryRecord>(predicate: #Predicate { $0.gcTime != nil && $0.stateData != nil })
        descriptor.propertiesToFetch = [\.key, \.gcTime, \.lastAccessedAt, \.lastSyncedAt]
        let records = (try? context.fetch(descriptor)) ?? []
        return records
            .filter { !excluded.contains($0.key) && !QueryRecord.Key.isMarker($0.key) && Self.isExpired($0, now: now) }
            .map(\.key)
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
        return evict(records(matching: filters, except: excluded, in: context, properties: [\.key, \.tags]), in: context)
    }

    /// Evicts `keys` whose SWR cache is still expired at `now`. A key used since it was found
    /// expired is kept.
    func evictExpired(_ keys: [String], now: Date) -> Evicted {
        guard !keys.isEmpty else { return Evicted() }
        let context = newContext()
        var descriptor = FetchDescriptor<QueryRecord>(predicate: #Predicate {
            keys.contains($0.key) && $0.gcTime != nil && $0.stateData != nil
        })
        descriptor.propertiesToFetch = [\.key, \.tags, \.gcTime, \.lastAccessedAt, \.lastSyncedAt]
        let records = ((try? context.fetch(descriptor)) ?? []).filter { Self.isExpired($0, now: now) }
        return evict(records, in: context)
    }

    // MARK: Helpers

    /// Clears model records and deletes fetcher records, saving once, then runs the listed types'
    /// `evict` for each key whose record was cleared. If the batch can't be saved, each key is
    /// evicted on its own so one bad record doesn't keep the rest.
    private func evict(_ records: [QueryRecord], in context: ModelContext) -> Evicted {
        guard !records.isEmpty else { return Evicted() }
        var batch = Evicted()
        for record in records {
            batch.add(record.key, tags: QueryRecord.Tags.decode(record.tags))
            Self.clear(record, in: context)
        }
        if (try? context.save()) != nil {
            runEvictors(for: batch.keys)
            return batch
        }
        context.rollback()
        var evicted = Evicted()
        for key in batch.keys {
            let single = newContext()
            let records = (try? single.fetch(QueryRecord.descriptor(key: key))) ?? []
            guard let tags = records.first.map({ QueryRecord.Tags.decode($0.tags) }) else { continue }
            for record in records {
                Self.clear(record, in: single)
            }
            if (try? single.save()) != nil {
                evicted.add(key, tags: tags)
            }
        }
        runEvictors(for: evicted.keys)
        return evicted
    }

    /// Runs each listed key's `evict` in one context saved once. If one throws or the save fails,
    /// everything is undone and each key runs in its own context, so a failing `evict` only
    /// loses its own changes.
    private func runEvictors(for keys: Set<String>) {
        let listed = keys.sorted().compactMap { key in evictors[QueryRecord.Key.typeName(of: key)].map { (key, $0) } }
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

    /// A model's record is kept without state; a fetcher's record is deleted.
    private static func clear(_ record: QueryRecord, in context: ModelContext) {
        if QueryRecord.Key.isModel(record.key) {
            record.stateData = nil
            record.lastSyncedAt = nil
            record.invalidated = false
        } else {
            context.delete(record)
        }
    }

    /// ``QueryRecord/isExpired(now:)`` for a record already known to have state, without
    /// loading the state.
    private static func isExpired(_ record: QueryRecord, now: Date) -> Bool {
        guard let gcTime = record.gcTime, let lastUse = record.lastAccessedAt ?? record.lastSyncedAt else { return false }
        return now >= lastUse.addingTimeInterval(gcTime)
    }
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
