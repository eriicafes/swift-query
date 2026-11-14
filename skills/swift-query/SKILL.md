---
name: swift-query
description: Use when syncing SwiftData models with external APIs using SwiftQuery. Covers QueryModel, SyncContext, SyncState, QueryCache, QueryProvider, @QueryClient, ModelQueryClient, stream tasks, invalidation, and optimistic mutations.
---

# SwiftQuery

## When to Use

Use this skill when the user wants to:

- fetch remote data into SwiftData models and keep it fresh
- conform a SwiftData `@Model` to `QueryModel`
- register models with `QueryProvider` and use `@QueryClient` in views
- add pull-to-refresh, invalidation, streams, or optimistic mutations

## Core Guidance

SwiftData is the source of truth. Views read data with SwiftData's `@Query`. They use `@QueryClient` only for sync state and actions. Never mirror model data into `QueryState`. It carries `SyncState` metadata only.

Keep the `@Model` class to application data. Put the `QueryModel` conformance in a separate extension with nested `SyncContext` (Sendable runtime dependencies) and `SyncState` (Codable metadata such as ETags or cursors) structs.

In `fetch`:

- Write into the provided `context`. The context is fresh per fetch. Pending changes are saved when `fetch` returns, and discarded if it throws. Calling `try context.save()` yourself is still fine.
- Update `syncState`. It is saved once, after `fetch` returns successfully. A returned stream task can't update it, unless the model conforms to `SyncedModel` directly.
- On a 304 or other "no changes" response, return without touching records.
- Return `nil` unless the model needs a long-lived stream. A stream task must create its own `ModelContext(context.container)` and must not capture `context`. Deduplicate connections inside `SyncContext`.
- If the app uses MainActor default isolation, mark the conformance extension `nonisolated`.

Conform to `QueryModel` by default. Conform to `SyncedModel` (the base protocol) instead only when a stream should advance cursors itself (high-volume streams, or resuming a reconnect). Implement only the `fetch` that takes `writer: SyncStateWriter<Self>`, pass the writer into the stream, and call `await writer.update { state in ... }` with monotonic changes such as `state.seq = max(state.seq, event.seq)`.

Pick the cache policy:

- `.forever()` for data that only changes when the app says so (call `invalidate()`).
- `.forever(refreshAfter:)` for data that should refresh periodically but never be dropped.
- `.swr(staleTime:cacheTime:)` for data that may be dropped after going unused. Implement `evict(context:)` to delete only server-owned records. The default evicts nothing.

Always include `QueryRecord.self` in the `ModelContainer` schema. If the app uses CloudKit, put `QueryRecord` in its own `ModelConfiguration` with `cloudKitDatabase: .none`. Create one `QueryProvider` at the app entry point with `.model(Type.self, context)` registrations, and inject it with `.environment(queryProvider)` next to `.modelContainer(container)`.

In views, declare `@QueryClient(Model.self)` or `@QueryClient(Model.self, cachePolicy)` without a type annotation. It syncs when the view appears and when the scene becomes active, so don't call `sync()` from `onAppear`, `task`, or scene-phase handlers. Use `.refreshable { await client.refresh() }` for pull-to-refresh. Show a spinner when `fetchState == .loading`. Use `client.error` to show refresh failures over existing data.

For mutations, use `client.mutate { remote call }`. Pass `scope:` (for example `"user-\(id)"`) when mutations to the same record must reach the server in order; leave it out for independent mutations. Add `optimistic:` only when instant UI feedback matters. Capture previous values inside the optimistic closure and return a rollback closure that restores them. Return `nil` when there is nothing to roll back. Don't call `refresh()` after `mutate`, because it already refreshes on success.
