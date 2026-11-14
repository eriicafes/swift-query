# SwiftQuery

`swift-query` is a React Query–inspired sync and caching layer for SwiftData. It manages external data fetching, cache freshness, background sync, streaming updates, and optimistic mutations.

SwiftData stays the source of truth for application data. SwiftQuery only manages how that data is synchronized with external sources. It does not replace SwiftData's `@Query`: `@Query` reads your data and `@QueryClient` keeps it in sync.

## Features

- Shared, deduplicated fetches per model type
- `forever` and stale-while-revalidate cache policies
- Sync metadata (ETags, cursors) persisted across launches
- Long-lived stream tasks managed alongside fetches, with opt-in sync state updates
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
| `QueryModel` | Defines how a model fetches and synchronizes external data |
| `SyncedModel` | The base of `QueryModel`; conform to it directly when a stream should update sync state |
| `SyncStateWriter` | Lets a `SyncedModel`'s stream task update its sync state |
| `QueryProvider` | Registers model types and their dependencies; owns one client per type |
| `QueryProvider.Model` | Typed registration holding a model's `SyncContext` |
| `@QueryClient` | Connects a view to the shared client and requests sync |
| `ModelQueryClient` | Observable client exposing state and operations |
| `ModelQueryActor` | Serializes sync, deduplicates fetches, manages persisted metadata (internal) |
| `QueryRecord` | Persists sync metadata across launches |
| `@Query` | Reads application data directly from SwiftData |

## Core Concepts

### QueryModel

Keep the SwiftData model to application data, and put sync behavior in an extension:

```swift
import SwiftData
import SwiftQuery

@Model
final class User {
    @Attribute(.unique) var id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

extension User: QueryModel {
    struct SyncContext: Sendable {
        let session: URLSession
    }

    struct SyncState: Codable {
        var etag: String?
    }

    static var defaultState: SyncState { .init(etag: nil) }
    static var cache: QueryCache { .forever(refreshAfter: .seconds(5 * 60)) }

    static func fetch(
        context: ModelContext,
        syncContext: SyncContext,
        syncState: inout SyncState
    ) async throws -> Task<Void, Never>? {
        let response = try await API.users.list(session: syncContext.session, etag: syncState.etag)
        guard !response.notModified else { return nil } // keep records on 304
        try context.replaceAll(User.self, with: response.users) { User(id: $0.id, name: $0.name) }
        syncState.etag = response.etag
        try context.save()
        return nil
    }
}
```

- `SyncContext` holds runtime dependencies. It must be `Sendable` and is never persisted.
- `SyncState` holds sync metadata. It must be `Codable`. It is loaded before each fetch and persisted only when the fetch succeeds.
- `fetch` gets a **fresh `ModelContext` for each fetch**. Changes still pending when it returns are saved for you. If it throws, they are discarded. How updates are applied (replace, upsert, event log) is up to you.
- The initial load is complete when `fetch` returns. `SyncState` is saved once, right after that, and only if the fetch succeeded.
- `fetch` is cancelled if its model is unregistered, so check for cancellation in long work.

#### Isolation

`fetch` runs off the main actor. If your app target uses MainActor default isolation, mark the conformance `nonisolated`:

```swift
nonisolated extension User: QueryModel { ... }
```

Without it, the compiler reports an error like this one:

```
main actor-isolated conformance of 'User.SyncState' to 'Decodable' cannot satisfy
conformance requirement for a 'SendableMetatype' type parameter 'Self.SyncState'
```

The context passed to `fetch` belongs to that one call. Don't store it or use it from another task.

#### Streams

`fetch` can return a long-lived task, such as a socket subscription. The task is not awaited. Returning `nil` keeps the current task running. Returning a different task cancels the old one and replaces it. The task must not capture `context`. Create its own context from `context.container` instead. Your `SyncContext` should prevent duplicate connections.

By default a stream task can't update `SyncState`. Cursors and ETags only move on the next `fetch`, so the stream's writes should be safe to receive again (for example, upserts by id).

#### SyncedModel: stream sync state

`QueryModel` refines `SyncedModel`, the base protocol the query layer works with. `SyncedModel` declares the same requirements, except its `fetch` also takes a `writer: SyncStateWriter<Self>`. `QueryModel` adds the writer-less `fetch` and implements the writer-taking one for you by ignoring the writer.

Conform to `SyncedModel` directly when re-downloading streamed data is wasteful, or a reconnecting stream needs to resume where it stopped. Implement the `fetch` that takes a `writer`, and pass the writer to your stream:

```swift
extension Message: SyncedModel {
    static func fetch(
        context: ModelContext,
        syncContext: SyncContext,
        syncState: inout SyncState,
        writer: SyncStateWriter<Message>
    ) async throws -> Task<Void, Never>? {
        let page = try await syncContext.api.messages(after: syncState.seq)
        // write page.messages into context...
        syncState.seq = page.lastSeq
        return await syncContext.socket.connect(container: context.container) { event in
            await writer.update { state in
                state.seq = max(state.seq, event.seq)
            }
        }
    }
}
```

- Updates run in order on the model's sync actor and are saved immediately.
- While a fetch is in progress, updates are queued and applied on top of that fetch's state when it finishes. Events received during a fetch may also be in its response, so keep updates monotonic, as with `max` above.
- Updates are dropped when nothing has synced successfully yet, and after the model is unregistered.
- Updates don't change `lastSyncedAt`, so they don't affect freshness.
- If 1,000 updates queue up behind one fetch, they're saved right away instead. That fetch's result then replaces them, so those events may be pulled again.

#### Eviction

`static func evict(context:)` runs when an SWR cache expires. The default implementation deletes nothing, so locally owned data is never removed implicitly. Implement it to delete only records that came from the server.

### QueryCache

```swift
.forever()                                           // fresh until invalidated, kept forever
.forever(refreshAfter: .seconds(5 * 60))            // stale after 5 minutes, kept forever
.swr()                                               // stale after 5 minutes, GC after 24h unused
.swr(staleTime: .seconds(30), cacheTime: .seconds(2 * 60 * 60))
```

`cacheTime` counts from the last *use*, not the last fetch. A cache is in use while any `@QueryClient` view is alive. It is also touched by every `sync()` and successful fetch. An expired cache is evicted on the next unobserved `sync`, or when you call `queryProvider.collectGarbage()`, for example when the app moves to the background.

### State

```swift
enum QueryState<Value> {
    case pending                          // no successful sync yet
    case success(value: Value, stale: Bool)
    case error(any Error)                 // failed with no previous success
}

enum QueryFetchState { case idle, loading, fetching }
```

`state` carries the model's `SyncState`, not the SwiftData records. `fetchState` tracks fetch activity separately, so data can be stale and fetching at the same time.

When a refresh fails after an earlier success, `state` becomes `.success(value, stale: true)` and the error goes to `client.error`. Cached SwiftData records are never touched by a failed fetch. `client.error` is cleared by the next successful fetch.

### QueryProvider

Register every synchronized model once, and include `QueryRecord.self` in the container. The provider creates exactly one client per model:

```swift
@main
struct MyApp: App {
    let container: ModelContainer
    let queryProvider: QueryProvider

    init() {
        container = try! ModelContainer(for: User.self, Post.self, QueryRecord.self)
        queryProvider = QueryProvider(
            modelContainer: container,
            for:
                .model(User.self, .init(session: .shared)),
                .model(Post.self, .init(session: .shared))
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

`register(_:context:)` and `unregister(_:)` are also available. `unregister` cancels the model's stream task and any fetch in progress, and the removed client ignores later calls. Only unregister models that no visible view uses. A view's `@QueryClient` stops syncing, but reading its client afterwards crashes with a missing-registration error.

#### CloudKit

`QueryRecord` works in a CloudKit container (it has no unique constraints, and every property has a default value). Its contents describe one device's local data, though, so keep it out of CloudKit with a local-only configuration:

```swift
let container = try ModelContainer(
    for: Schema([User.self, Post.self, QueryRecord.self]),
    configurations:
        ModelConfiguration(schema: Schema([User.self, Post.self]), cloudKitDatabase: .automatic),
        ModelConfiguration("SwiftQuery", schema: Schema([QueryRecord.self]), cloudKitDatabase: .none)
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
            if usersClient.fetchState == .loading {
                ProgressView()
            }
        }
        .refreshable {
            await usersClient.refresh()
        }
    }
}
```

The wrapper returns the provider's shared `ModelQueryClient<User>`. It requests a sync when the view appears and again whenever its scene becomes active, never on a plain `body` evaluation. A cache override applies only to that view's sync requests. Every view shares the same state, metadata, and in-flight fetches.

### Client operations

```swift
usersClient.sync()                               // default cache policy
usersClient.sync(.swr(staleTime: .seconds(30)))  // per-request policy
await usersClient.refresh()                      // always fetch, deduplicated
usersClient.invalidate()                         // next sync fetches; no network now
usersClient.cancelStream()
```

Concurrent `sync()` and `refresh()` calls share a single `fetch`. `sync()` and `invalidate()` run in the order they are called. A stored `SyncState` that no longer decodes (for example after you change its type) counts as missing, so the next sync fetches from `defaultState`.

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
- **Success:** optimistic changes are kept, then the client awaits a fetch that starts after the mutation. A fetch already in progress may have been sent before the server applied the mutation, so it isn't trusted. If that fetch fails, the mutation is still treated as committed. Nothing rolls back or throws, and the failure shows up in `state` and `error`.
- **Failure:** the rollback runs and the mutation error is rethrown. Mutation errors never set `state` to `.error`.
- **Concurrent mutations:** if a newer optimistic mutation started after the one that failed, the older rollback is skipped so it can't overwrite the newer change. The client then refreshes once no mutations are pending.
- **Refetch overlap:** a refetch writes the server's current data straight to SwiftData. If it runs while another mutation's remote call is still in flight, that mutation's optimistic edit can briefly show the older server value until its own refetch. Put related mutations in one scope to avoid this.

#### Scopes

Mutations with the same `scope` send their remote calls one at a time, in the order `mutate` was called. Mutations without a scope run in parallel. Scopes are shared by every model registered with the provider, so one scope can order mutations across models. A per-record scope is typical:

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
- The refetch runs once the scope has nothing left queued, for every model a mutation in it touched, so the server state doesn't flicker between queued mutations. Only the caller of the last mutation awaits it.
- A caller cancelled while queued stops waiting right away, rolls back, and throws `CancellationError` without sending its remote call. Later mutations in the scope keep their order.
