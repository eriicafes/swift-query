---
name: swift-query
description: Use when syncing SwiftData or other remote data with external APIs using SwiftQuery. Covers QueryModel, QueryFetcher, Context, QueryData, QueryCache, QueryProvider contexts and fetchers, @QueryClient, QueryObserver, subscribe and QueryWriter, QueryFilter and bulk operations, query/getQueryState/getQueryData/setQueryData, mutations with @MutationClient, client.mutate and provider.mutate, and optimistic updates.
---

# SwiftQuery

## When to Use

Use this skill when the user wants to:

- fetch remote data into SwiftData models and keep it fresh
- fetch a single row, extra data attached to rows, or a standalone value with no model of its own
- set up a `QueryProvider` and use `@QueryClient` in views
- add pull-to-refresh, invalidation, live updates with `subscribe`, or optimistic mutations

## Core Guidance

SwiftData is the source of truth for rows. Views read rows with SwiftData's `@Query` and use `@QueryClient` for sync state and actions. A value with no model of its own (an exchange rate, a count) is the key's `QueryData`: return it from `fetch` and read it from `client.data`. SwiftQuery stores it in its `QueryRecord` table, or only in memory when `cache` is `nil`.

Pick the conformance:

- `QueryModel` (static members) when a fetch syncs a whole collection. The model type is the key.
- `QueryFetcher` (a `Hashable`, `Codable` struct with instance members) for anything else. Each fetcher value is its own key, for example `UserDetail(id:)`. Keep the synthesized `Hashable` and `Codable` conformances. `Set` properties are fine in a key. Changing a fetcher's stored properties changes its keys: data saved under the old ones is deleted at the next launch, without `evict`.

Keep the `@Model` class to application data and put the conformance in a separate extension. Signatures are `fetch(query: QueryFetch<Context, QueryData>) async throws -> QueryData`, `subscribe(query: QuerySubscription<Context, QueryData>) async throws` and `evict(query: QueryEvict<Context>) throws`, with `static` on models, for example `fetch(query: QueryFetch<API, Date>) async throws -> Date`. Both types are inferred from `fetch`: `Context` is the dependency's type (nest `struct Context` when it needs several values), and `QueryData` is the return type, nested when it needs fields (`struct QueryData: Codable { var etag: String? }`). `query.modelContext` is SwiftData, `query.context` the dependency, and `query.previous` the stored data (`nil` before the first success). `fetch` returns the new data, so `QueryData` is never optional: a data fetcher returns its data, such as `-> Double`. `QueryData` must be `Sendable`, which internal structs of `Sendable` values are automatically.

In `fetch`:

- Write rows into `query.modelContext`. The context is fresh per fetch. Pending changes are saved when `fetch` returns, and discarded if it throws or was cancelled. If `fetch` saves the context itself, call `try Task.checkCancellation()` first.
- Read cursors or ETags from `query.previous?` and return the new data. It is saved once, after `fetch` returns successfully. On a 304, return `query.previous`.
- On a 304 or other "no changes" response, don't touch rows.
- If the app uses MainActor default isolation, mark the conformance extension `nonisolated`, and make the types `fetch` calls into (such as those in its fetch context) `nonisolated` too. Otherwise each call hops back to the main actor and does its work there.

Implement `subscribe` only when the key needs live updates, such as from a socket. Connect, then `let writer = await query.begin()`, then for each event `try await writer.write { tx in ... }`: skip events the fetch already has (`guard event.seq > (tx.data?.seq ?? 0) else { return }`), write rows into `tx.modelContext` and data into `tx.data`. `begin()` starts the fetch that writes wait for; call it after connecting for a stream that can't resume, or before connecting for one that resumes from `query.previous`. Give the connect a timeout: until `begin()` is called the key doesn't fetch. Write rows and data only through `writer.write`, batch busy streams into fewer writes, and keep closures short. Return or throw when the stream drops; don't reconnect in a loop, since the library calls `subscribe` again with a backoff and refetches. Returning without `begin()` means no live updates. Use `write(.now)` with `tx.isSynced` only to buffer events yourself during a fetch. Don't deduplicate connections yourself: the client runs at most one stream, and only while a view shows the key.

Pick the cache policy:

- `.forever()` for data that only changes when the app says so (call `invalidate()`).
- `.forever(refreshAfter:)` for data that should refresh periodically but never be dropped.
- `.swr(staleTime:gcTime:)` for data that may be dropped after going unused. Expired data is cleaned up automatically at launch, when the app goes to the background, and when it's next used, so don't call `collectGarbage()` from scene-phase handlers. Implement `evict(query:)` to delete only server-owned rows from `query.modelContext`. The default evicts nothing.
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

Register each context value once; models and fetchers with the same `Context` type share it. Cast values for protocol-typed contexts (`client as any HTTPClient`). List every persisted model and fetcher type in `fetchers:`: at launch, saved data of types that aren't listed is deleted, so an unlisted type loses its cache on every relaunch. Inject the provider with `.environment(queryProvider)` next to `.modelContainer(container)`.

In views, use `@QueryClient(User.self)`, `@QueryClient(ExchangeRate(from: "USD", to: "EUR"))`, or, for a key built from init parameters, `@QueryClient<UserDetail> private var detail: QueryObserver<UserDetail>` assigned with `_detail = QueryClient(UserDetail(id: id))`. The wrapper syncs when the view appears and when the scene becomes active, so don't call `sync()` from `onAppear`, `task`, or scene-phase handlers. Use `.refreshable { await client.refresh() }` for pull-to-refresh. Show a spinner when `client.isLoading`. Use `client.error` to show refresh failures over existing data.

Outside views, use the provider: `getQueryState(for:)` and `getQueryData(for:)` to read without fetching, `query(_:staleTime:)` to get fresh data (for deep links or background work), `prefetch(_:)` before navigating, `setQueryData(for:_:)` to store a known result. These follow React Query's names. `invalidate`, `refetch`, `cancel`, `remove` and `reset` take one or more filters: `.key(UserDetail(id: id))`, `.key(client)`, `.type(User.self)` (a model's collection, or every key of a fetcher type), `.tag("users")` or `.all`. All five are `async`; from a button action, wrap them in a `Task`. `invalidate` marks keys stale and waits for the ones shown in a view to refetch; pass `refetch: nil` to only mark them, or `.inactive`/`.all` to fetch the rest too. `refetch` fetches keys shown in a view without marking anything stale; pass `type: .inactive` or `.all` to fetch the rest. Both follow a fetch already in progress with a new request, and `reset` waits for its refetch too.

For mutations:

- `client.mutate { remote call }` changes the client's own data; its key is invalidated afterwards.
- `@MutationClient private var follow` in a view, for `isPending`, `error` and `reset()`. Call `follow.mutate { ... }` from a button's action (returns right away, failures go to `error`) or `try await follow.mutate { ... }` (returns the result, throws). Use `@MutationClient<Input, Result>` with `send.mutate(input) { input in ... }` to keep `variables` and `data`, or `<Void, Result>` to keep only `data`.
- `provider.mutate { ... }` outside views, or when no single client owns the change. To track status outside a view, such as in a view model, create `MutationObserver(provider:)`.

Pass `invalidates: [...]` with the filters of every key the mutation affects, for example `[.tag("users")]` after editing a profile. Keys are invalidated whether the mutation succeeds or fails; keys shown in a view refetch and `mutate` waits for them. Don't call `refresh()` or `invalidate` after `mutate`.

Pass `scope:` (for example `"user-\(id)"`) when mutations to the same record must reach the server in order; use the same scope for a record every time. A call's `scope` replaces a `@MutationClient`'s default, and its `invalidates` add to the defaults.

Add `optimistic:` only when instant UI feedback matters. The closure gets `tx`: edit rows in `tx.modelContext`, capture their previous values, and register a rollback with `tx.onRollback { context in ... }` that restores them. The closure returns nothing. Update query data with `tx.setQueryData(for: key) { $0 += 1 }`, which needs no rollback: it's restored on failure and its key is invalidated. With `@MutationClient<Input, Result>`, the closure also gets the input: `optimistic: { tx, input in ... }`. If the app is terminated mid-mutation, the keys it would invalidate are refetched at the next launch, so no extra handling is needed. A provider in an app extension that shares the app's store should pass `recoversInterruptedMutations: false`. While an optimistic mutation is in flight, its keys aren't refetched by syncs or other mutations, so list every key it edits in `invalidates`. `refresh()` on those keys returns right away and `provider.query` returns the edited data; both fetch once the mutation settles, so the mutation's own remote call can `query` the keys it covers.

A `@MutationClient`'s `isPending` follows its latest call; its `isMutating` covers every call it started. Use `client.isMutating`, `provider.isMutating` or `provider.isMutating(scope:)` for activity that isn't tied to one `@MutationClient`.
