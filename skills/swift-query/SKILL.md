---
name: swift-query
description: Use when syncing SwiftData or other remote data with external APIs using SwiftQuery. Covers QueryModel, QueryFetcher, Context, QueryData, QueryCache, QueryProvider contexts and fetchers, @QueryClient, ModelQueryClient, subscribe streams and QueryDataWriter, invalidation and other bulk operations, query/getQueryState/getQueryData/setQueryData, and optimistic mutations.
---

# SwiftQuery

## When to Use

Use this skill when the user wants to:

- fetch remote data into SwiftData models and keep it fresh
- fetch a single row, extra data attached to rows, or a standalone value with no model of its own
- set up a `QueryProvider` and use `@QueryClient` in views
- add pull-to-refresh, invalidation, streams, or optimistic mutations

## Core Guidance

SwiftData is the source of truth for rows. Views read rows with SwiftData's `@Query` and use `@QueryClient` for sync state and actions. A value with no model of its own (an exchange rate, a count) is the key's `QueryData`: return it from `fetch` and read it from `client.data`. SwiftQuery stores it in its `QueryRecord` table, or only in memory when `cache` is `nil`.

Pick the conformance:

- `QueryModel` (static members) when a fetch syncs a whole collection. The model type is the key.
- `QueryFetcher` (a `Hashable`, `Codable` struct with instance members) for anything else. Each fetcher value is its own key, for example `UserDetail(id:)`. Keep the synthesized `Hashable` and `Codable` conformances.

Keep the `@Model` class to application data and put the conformance in a separate extension. `Context` and `QueryData` are inferred from `fetch`; name them only when the type needs nesting (`struct QueryData: Codable { var etag: String? }`). `fetch` receives the stored data as `previous` (`nil` before the first success) and returns the new data, so `QueryData` is never optional: a data fetcher returns its data, such as `-> Double`.

In `fetch`:

- Write rows into the provided `context`. The context is fresh per fetch. Pending changes are saved when `fetch` returns, and discarded if it throws.
- Read cursors or ETags from `previous?` and return the new data. It is saved once, after `fetch` returns successfully. On a 304, return `previous`.
- On a 304 or other "no changes" response, don't touch rows.
- If the app uses MainActor default isolation, mark the conformance extension `nonisolated`.

Implement `subscribe` only when the key needs a long-lived stream, such as a socket. It must return a task without awaiting anything itself, create its own `ModelContext(container)`, and call `await writer.update { data in ... }` with monotonic changes such as `data.seq = max(data.seq, event.seq)`. Don't deduplicate connections yourself: the client runs at most one stream and only while a view shows the key.

Pick the cache policy:

- `.forever()` for data that only changes when the app says so (call `invalidate()`).
- `.forever(refreshAfter:)` for data that should refresh periodically but never be dropped.
- `.swr(staleTime:gcTime:)` for data that may be dropped after going unused. Expired data is cleaned up automatically at launch, when the app goes to the background, and when it's next used, so don't call `collectGarbage()` from scene-phase handlers. Implement `evict(context:)` to delete only server-owned rows. The default evicts nothing.
- For a fetcher, `nil` keeps the data in memory for the session only. Don't write rows from such a fetcher unless they hang off a model.

Rows a fetcher writes should hang off a model through a `.cascade` relationship, such as `User.profile`. Give the model and its fetchers a shared tag, such as `"users"`, so evicting the collection invalidates the fetchers. A fetcher that inserts top-level rows must delete them in `evict`.

Always include `QueryRecord.self` in the `ModelContainer` schema. If the app uses CloudKit, give `QueryRecord` its own configuration with a distinct name and `cloudKitDatabase: .none`, for example `ModelConfiguration("SwiftQuery", schema: Schema([QueryRecord.self]), cloudKitDatabase: .none)`. Create one provider at the app entry point:

```swift
QueryProvider(
    modelContainer: container,
    contexts: api, Message.Context(api: api, socket: socket),
    fetchers: User.self, Message.self, UserDetail.self
)
```

Register each context value once; models and fetchers with the same `Context` type share it. Cast values for protocol-typed contexts (`client as any HTTPClient`). List every persisted model and fetcher type in `fetchers:`. Inject the provider with `.environment(queryProvider)` next to `.modelContainer(container)`.

In views, use `@QueryClient(User.self)`, `@QueryClient(ExchangeRate(from: "USD", to: "EUR"))`, or, for a key built from init parameters, `@QueryClient<UserDetail> private var detail: ModelQueryClient<UserDetail>` assigned with `_detail = QueryClient(UserDetail(id: id))`. The wrapper syncs when the view appears and when the scene becomes active, so don't call `sync()` from `onAppear`, `task`, or scene-phase handlers. Use `.refreshable { await client.refresh() }` for pull-to-refresh. Show a spinner when `client.isLoading`. Use `client.error` to show refresh failures over existing data.

Outside views, use the provider: `getQueryState(for:)` and `getQueryData(for:)` to read without fetching, `query(_:staleTime:)` to get fresh data (for deep links or background work), `prefetch(_:)` before navigating, `setQueryData(for:_:)` to store a known result. These follow React Query's names. Use `invalidate`, `refetch`, `cancel`, `remove` and `reset` with a fetcher value, a type, or `tag:`.

For mutations, use `client.mutate { remote call }`. Pass `scope:` (for example `"user-\(id)"`) when mutations to the same record must reach the server in order; use the same scope for a record every time. Add `optimistic:` only when instant UI feedback matters. Capture previous values inside the optimistic closure and return a rollback closure that restores them. Return `nil` when there is nothing to roll back. Don't call `refresh()` after `mutate`, because it already refetches its own key. Invalidate related keys by type or tag when a mutation affects them, for example `provider.invalidate(tag: "users")` after editing a profile.
