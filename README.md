# SwiftQuery

`swift-query` is a React Query–inspired sync and caching layer for SwiftData. It manages external data fetching, cache freshness, background sync, streaming updates, and optimistic mutations.

SwiftData stays the source of truth for application data. SwiftQuery only manages how that data is synchronized with external sources. It does not replace SwiftData's `@Query`: `@Query` reads your data and `@QueryClient` keeps it in sync.

## Features

- Sync whole SwiftData collections, single rows, extra data attached to rows, or data that never touches SwiftData
- Shared, deduplicated fetches per key, with clients created on first use
- `forever` and stale-while-revalidate cache policies, or in-memory state for the session
- Sync metadata (ETags, cursors) persisted across launches
- Streams that start while a view shows the data and can advance the sync state
- Invalidate, refetch, cancel, remove and reset by key, type or tag
- Optimistic mutations with manual rollback, and scopes that keep related mutations in order

## Requirements

- Swift 6.0+
- iOS 17+
- macOS 14+
- tvOS 17+
- watchOS 10+
- visionOS 1+

## Installation

Add `swift-query` to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/eriicafes/swift-query.git", from: "0.1.0")
]
```

Then include it in your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SwiftQuery", package: "swift-query")
    ]
)
```

## AI Skills

Install the `swift-query` agent skills with:

```sh
npx skills add eriicafes/swift-query
```

## Architecture

| Component | Responsibility |
|---|---|
| `QueryModel` | Syncs a whole SwiftData collection; the model type is the key |
| `QueryFetcher` | Syncs anything else; each fetcher value is its own key |
| `StateWriter` | Lets a stream update its key's sync state |
| `QueryProvider` | Resolves dependencies, creates one client per key, sweeps caches, runs bulk operations |
| `@QueryClient` | Connects a view to a key's client and keeps it in sync |
| `ModelQueryClient` | Observable client exposing state and operations for one key |
| `QueryRecord` | Persists sync state and metadata across launches |
| `@Query` | Reads application data directly from SwiftData |

## Core Concepts

### QueryModel

A `QueryModel` syncs a whole collection. Keep the SwiftData model to application data, and put sync behavior in an extension:

```swift
import SwiftData
import SwiftQuery

@Model
final class User {
    @Attribute(.unique) var id: String
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \UserProfile.user) var profile: UserProfile?

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

extension User: QueryModel {
    struct State: Codable {
        var etag: String?
    }

    static var cache: QueryCache { .forever(refreshAfter: .seconds(5 * 60)) }
    static var tags: Set<String> { ["users"] }

    static func fetch(context: ModelContext, fetchContext: APIClient, state: State?) async throws -> State {
        let response = try await fetchContext.users(etag: state?.etag)
        guard !response.notModified, let users = response.users else {
            return state ?? State() // 304: keep records and the ETag
        }
        try context.replaceAll(User.self, with: users) { User(id: $0.id, name: $0.name) }
        return State(etag: response.etag)
    }
}
```

- `Context` holds runtime dependencies. It's inferred from `fetch`, must be `Sendable`, and is never persisted.
- `State` holds sync metadata, such as an ETag, or for a fetcher the data itself. It's inferred from `fetch`'s return type and must be `Codable`. `fetch` receives the stored state, or `nil` before the first successful fetch, and returns the new state, which is persisted only when the fetch succeeds. It never needs to be optional: "nothing fetched yet" is `.pending`.
- `fetch` gets a **fresh `ModelContext` for each fetch**. Changes still pending when it returns are saved for you. If it throws, they are discarded. How updates are applied (replace, upsert, event log) is up to you.
- The initial load is complete when `fetch` returns. `State` is saved once, right after that.
- `cache`, `tags`, `subscribe` and `evict` are described below. Only `fetch` and `cache` are required.

### QueryFetcher

A `QueryFetcher` syncs anything that isn't a whole collection. The fetcher value is the key: each distinct value has its own client, state and cache entry.

Data that never touches SwiftData lives in the sync state itself:

```swift
struct ExchangeRate: QueryFetcher {
    let from: String, to: String
    var cache: QueryCache? { .swr(staleTime: .seconds(60)) }

    func fetch(context: ModelContext, fetchContext: APIClient, state: Double?) async throws -> Double {
        try await fetchContext.rate(from, to)
    }
}
```

A fetcher can also write rows, such as one user's profile:

```swift
struct UserDetail: QueryFetcher {
    let id: String
    var cache: QueryCache? { .swr(staleTime: .seconds(30)) }
    var tags: Set<String> { ["users", "user-\(id)"] }

    func fetch(context: ModelContext, fetchContext: APIClient, state: Date?) async throws -> Date {
        let dto = try await fetchContext.profile(userID: id)
        // find the User row and create or update user.profile...
        return .now
    }
}
```

- Members are instance members, so `cache` and `tags` can depend on the key.
- `cache` is required. Return `nil` to keep the state in memory only: it's never persisted, is fetched on the first sync after launch, stays fresh for the session until invalidated, and is dropped with its client.
- Keep the synthesized `Hashable` and `Codable` conformances. Equality picks the client and the JSON encoding names the stored record, so the two must agree. Changing a fetcher's stored properties changes its keys; records stored under the old keys are deleted without `evict`.

Detail queries come in five kinds, all fetchers keyed by the row's id:

| Kind | Writes | `evict` |
|---|---|---|
| A single collection row | Creates, updates or deletes that row | Nothing; the collection owns the row |
| Extra fields on a row | Columns the list endpoint doesn't return | Clears only those fields |
| A related model | A model hanging off the row through `.cascade` | Nothing; it's deleted with the row |
| Rows the fetcher owns | Top-level rows no model owns, such as a user's activity items | Deletes exactly its own rows; the type must be listed in `fetchers:` |
| Metadata that isn't stored | Only the sync state, often with `cache: nil`, read from `status.value` | Nothing |

Have each stored kind create or update the row from the fields its response includes, so it never depends on the collection having loaded first, as with a deep link to one row.

Where a fetcher's rows live matters for cleanup:
- Rows a fetcher writes should hang off a model through a `.cascade` relationship, like `User.profile`. The collection then owns their lifecycle, and evicting it removes them.
- Display-only data belongs in the fetcher's sync state, not in rows.
- A fetcher that inserts top-level rows owns them: it must delete them in `evict`, scoped to its own key (for example by a `userID` column), and be listed in `fetchers:` so expired keys are evicted even without a client. Don't delete rows another key may show.
- A fetcher whose `cache` is `nil` shouldn't write rows unless they hang off a model, since nothing evicts them.

#### Isolation

`fetch` runs off the main actor. If your app target uses MainActor default isolation, mark the conformance `nonisolated`:

```swift
nonisolated extension User: QueryModel { ... }
```

Without it, the compiler reports an error like this one:

```
main actor-isolated conformance of 'User.State' to 'Decodable' cannot satisfy
conformance requirement for a 'SendableMetatype' type parameter 'Self.State'
```

The context passed to `fetch` belongs to that one call. Don't store it or use it from another task.

#### Streams

Implement `subscribe` to keep a long-lived stream, such as a socket, open while a view shows the key:

```swift
extension Message: QueryModel {
    static func subscribe(
        container: ModelContainer,
        fetchContext: Context,
        state: State?,
        writer: StateWriter<State>
    ) -> Task<Void, Never>? {
        Task {
            for await event in await fetchContext.socket.events(after: state?.seq ?? 0) {
                let context = ModelContext(container)
                context.insert(Message(event))
                try? context.save()
                await writer.update { $0.seq = max($0.seq, event.seq) }
            }
        }
    }
}
```

- The client calls `subscribe` when it gains a view and no stream is running. A stream that ends on its own isn't restarted right away: the next sync from a view, when one appears or its scene becomes active, starts a new one. Fetches alone never start a stream, and a client runs at most one at a time. Retry and backoff for a dropped connection belong inside the task.
- `subscribe` must not block: do any awaiting inside the returned task. It gets the stored sync state to resume from, and writes rows through its own context from `container`.
- The stream is cancelled when its client is dropped, its cache is removed, or `cancelStream()` is called.
- `writer.update` advances the sync state, so the next fetch doesn't pull streamed data again:
  - Updates run in order on the key's query actor and are saved immediately.
  - While a fetch is in progress, updates are queued and applied on top of that fetch's state when it finishes. Events received during a fetch may also be in its response, so keep updates monotonic, as with `max` above.
  - Updates are dropped when nothing has synced successfully yet, and once the client is gone.
  - Updates don't change `lastSyncedAt`, so they don't affect freshness.
  - If 1,000 updates queue up behind one fetch, they're saved right away instead. That fetch's result then replaces them, so those events may be pulled again.

#### Eviction

`evict(context:)` runs when a key's SWR cache expires or is removed. The default implementation deletes nothing, so locally owned data is never removed implicitly. Implement it to delete only records that came from the server.

### QueryCache

```swift
.forever()                                           // fresh until invalidated, kept forever
.forever(refreshAfter: .seconds(5 * 60))            // stale after 5 minutes, kept forever
.swr()                                               // stale after 5 minutes, GC after 24h unused
.swr(staleTime: .seconds(30), cacheTime: .seconds(2 * 60 * 60))
```

`cacheTime` counts from the last *use*, not the last fetch. A cache is in use while any `@QueryClient` view is alive. It's also touched by syncs and successful fetches, at most once a minute. An expired cache is evicted on the next unobserved `sync`, or when you call `queryProvider.collectGarbage()`, for example when the app moves to the background.

`collectGarbage()` also sweeps stored keys that have no client, using each record's stored cache time. Records of types no longer listed in `fetchers:` are deleted without `evict`; `.forever` records are kept. Evicting a key invalidates every other key that shares one of its tags, so a profile loaded by `UserDetail` refetches after the `User` collection it hangs off is evicted.

### Status

```swift
enum QueryStatus<Value> {
    case pending                          // no successful sync yet
    case success(value: Value, stale: Bool)
    case error(any Error)                 // failed with no previous success
}

enum QueryFetchStatus { case idle, loading, fetching }
```

`status` carries the key's `State`, not the SwiftData records. `fetchStatus` tracks fetch activity separately, so data can be stale and fetching at the same time.

When a refresh fails after an earlier success, `status` becomes `.success(value, stale: true)` and the error goes to `client.error`. Cached SwiftData records are never touched by a failed fetch. `client.error` is cleared by the next successful fetch.

### QueryProvider

Create one provider for the app, and include `QueryRecord.self` in the container:

```swift
@main
struct MyApp: App {
    let container: ModelContainer
    let queryProvider: QueryProvider

    init() {
        container = try! ModelContainer(for: User.self, UserProfile.self, Message.self, QueryRecord.self)
        let api = APIClient()
        queryProvider = QueryProvider(
            modelContainer: container,
            contexts: api, Message.Context(api: api, socket: Socket()),
            fetchers: User.self, Message.self, UserDetail.self
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container)
                .environment(queryProvider)
        }
    }
}
```

- **`contexts:`** registers each value under its static type. A key's `Context` is looked up by type, so models and fetchers that share a context type share its value. To satisfy a protocol-typed context, cast the value: `client as any HTTPClient`. A context type conforming to `DefaultFetchContext` (an `init()`), and `Void`, need no registration. Every listed type's context is checked at launch. An unlisted fetcher with a missing context fails on first use with a message naming the type.
- **`fetchers:`** lists every persisted model and fetcher type, so the provider can evict their expired caches even when no client exists. Fetchers whose `cache` is `nil` need not be listed. The list doesn't restrict which keys can be used; a debug build asserts when a persisted type is missing from it.
- **Clients** are created on first use, one per key. A fetcher client nobody uses is kept for `gracePeriod` (5 minutes by default), then dropped, cancelling its stream. A client something still holds is always reused. Model clients live for the whole session.

#### Reading and writing state

```swift
provider.status(for: UserDetail(id: "42"))                        // no fetch, no client
try await provider.query(ExchangeRate(from: "USD", to: "EUR"))    // cached if fresh, else fetch
try await provider.query(UserDetail(id: "42"), staleTime: .infinite)
provider.prefetch(UserDetail(id: "42"))                           // query without waiting
try await provider.setState(for: ExchangeRate(from: "USD", to: "EUR"), 0.92)
```

- `status(for:)` uses the live client if there is one, which views observe. Otherwise it decodes the stored state as a snapshot.
- `query(_:staleTime:)` returns the state if it's fresh, otherwise fetches and returns the result, throwing if that fetch fails or is cancelled. `staleTime` overrides how old the state may be: `nil` uses the key's own cache policy, `.after(duration)` sets a maximum age (`.after(.zero)` always fetches), and `.infinite` accepts any cached state that wasn't invalidated.
- `setState(for:_:)` stores state as if a fetch had just returned it, for example a mutation's response.
- Each method also takes a model type, such as `provider.status(for: User.self)`.

#### Bulk operations

Each takes a fetcher value (one key), a model or fetcher type (every key of it), or `tag:`:

```swift
provider.invalidate(tag: "users")      // mark stale; observed keys re-sync now
await provider.refetch(UserDetail.self) // fetch live keys (includeStored: also stored ones)
provider.cancel(UserDetail(id: "42"))  // stop in-flight fetches
await provider.remove(tag: "user-42")  // evict rows and state
await provider.reset(User.self)        // remove, then re-sync observed keys
```

- Keys without a live client are covered through their stored records.
- `refetch` only refetches keys that already exist: a live client, or with `includeStored: true`, a stored record of a listed type. A key that was never fetched, or an in-memory key whose client was dropped, is skipped. To fetch any key unconditionally, use `query(key, staleTime: .after(.zero))`.
- `remove` and `reset` invalidate other keys that share a tag with a removed key.
- `cancel` is cooperative: a fetch that already saved rows has written them, but its sync state isn't saved and the previous state stays. Call it before an optimistic update so a slow fetch sent earlier can't overwrite the edit.

#### CloudKit

`QueryRecord` works in a CloudKit container (it has no unique constraints, and every property has a default value). Its contents describe one device's local data, though, so keep it out of CloudKit with `.queryRecords`, a local-only configuration in its own store:

```swift
let container = try ModelContainer(
    for: Schema([User.self, Post.self, QueryRecord.self]),
    configurations:
        ModelConfiguration(schema: Schema([User.self, Post.self]), cloudKitDatabase: .automatic),
        .queryRecords
)
```

### @QueryClient

```swift
struct UsersView: View {
    @QueryClient(User.self, .swr(staleTime: .seconds(30)))
    private var usersClient

    @Query(sort: \User.name)
    private var users: [User]

    var body: some View {
        List(users) { user in
            Text(user.name)
        }
        .overlay {
            if usersClient.fetchStatus == .loading {
                ProgressView()
            }
        }
        .refreshable {
            await usersClient.refresh()
        }
    }
}

struct ProfileView: View {
    @QueryClient<UserDetail> private var detail: ModelQueryClient<UserDetail>
    @Query private var users: [User]

    init(id: String) {
        _detail = QueryClient(UserDetail(id: id))
        _users = Query(filter: #Predicate { $0.id == id })
    }
    // users.first?.profile
}

struct RateView: View {
    @QueryClient(ExchangeRate(from: "USD", to: "EUR")) private var rate
    // rate.status.value
}
```

The wrapper returns the provider's shared client for its key. It requests a sync when the view appears and again whenever its scene becomes active, never on a plain `body` evaluation, and starts the key's stream if it has one. A cache override applies only to that view's sync requests. Every view of a key shares the same state, metadata, and in-flight fetches.

### Client operations

```swift
usersClient.sync()                               // default cache policy
usersClient.sync(.swr(staleTime: .seconds(30)))  // per-request policy
await usersClient.refresh()                      // always fetch, deduplicated
usersClient.invalidate()                         // next sync fetches; no network now
usersClient.cancel()                             // stop the in-flight fetch
usersClient.cancelStream()
```

Concurrent `sync()` and `refresh()` calls share a single `fetch`. `sync()` and `invalidate()` run in the order they are called. A stored `State` that no longer decodes (for example after you change its type) counts as missing, so the next sync fetches as if nothing were stored, passing `nil`.

### Mutations

```swift
try await usersClient.mutate {
    try await API.users.delete(id: id)
}

try await usersClient.mutate {
    try await API.users.update(id: id, name: "New name")
} optimistic: { context in
    let descriptor = FetchDescriptor<User>(predicate: #Predicate { $0.id == id })
    guard let user = try context.fetch(descriptor).first else { return nil }
    let previousName = user.name
    user.name = "New name"
    try context.save()
    return { context in
        guard let user = try context.fetch(descriptor).first else { return }
        user.name = previousName
        try context.save()
    }
}
```

- The optimistic closure runs on the main context, so `@Query` updates right away. The context is saved afterwards, and again after a rollback, so an unsaved edit can't later overwrite what a refetch brought in. If that save fails, the rollback runs and the error is thrown before anything is sent.
- The save commits every pending change in the shared main context. If your app turns `autosaveEnabled` off on the main context (to hold drafts, for example), nothing is saved for you, and your optimistic and rollback closures must save themselves.
- **Cancellation:** the remote call runs in its own task. Cancelling the caller, for example when a `.task` view goes away, doesn't cancel a call that was already sent, and the caller still gets its result. A caller cancelled before its call is sent rolls back and throws `CancellationError`.
- **Success:** optimistic changes are kept, then the client awaits a fetch that starts after the mutation. A fetch already in progress may have been sent before the server applied the mutation, so it isn't trusted. If that fetch fails, the mutation is still treated as committed. Nothing rolls back or throws, and the failure shows up in `status` and `error`.
- **Failure:** the rollback runs and the mutation error is rethrown. Mutation errors never set `status` to `.error`.
- **Related keys:** a mutation refetches only its own client's key. To update a list after editing a detail, or the reverse, invalidate by type or tag afterwards, for example `provider.invalidate(tag: "users")`.
- **Concurrent mutations:** if a newer optimistic mutation started after the one that failed, the older rollback is skipped so it can't overwrite the newer change. The client then refreshes once no mutations are pending.
- **Refetch overlap:** a refetch writes the server's current data straight to SwiftData. If it runs while another mutation's remote call is still in flight, that mutation's optimistic edit can briefly show the older server value until its own refetch. Put related mutations in one scope to avoid this.

#### Scopes

Mutations with the same `scope` send their remote calls one at a time, in the order `mutate` was called. Mutations without a scope run in parallel. Scopes are shared by every client of the provider, so one scope can order mutations across models and fetchers. A per-record scope is typical:

```swift
try await usersClient.mutate(scope: "user-\(id)") {
    try await API.users.update(id: id, name: name)
} optimistic: { context in
    ...
}
```

- Optimistic updates still apply as soon as `mutate` is called. Only the remote call waits.
- A failure doesn't cancel later mutations in the scope. Each error goes only to its own caller.
- A failed mutation rolls back unless a newer optimistic mutation started in the same scope. Always use the same scope, or always none, for a given record. Otherwise a failed mutation can roll back a newer edit made under a different scope.
- The refetch runs once the scope has nothing left queued, for every key a mutation in it touched, so the server state doesn't flicker between queued mutations. Only the caller of the last mutation awaits it.
- A caller cancelled while queued stops waiting right away, rolls back, and throws `CancellationError` without sending its remote call. Later mutations in the scope keep their order.
