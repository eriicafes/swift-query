# SwiftQuery

`swift-query` is a sync and caching layer for SwiftData, inspired by React Query. It fetches external data, keeps it fresh, streams updates, and applies optimistic mutations.

SwiftData stays the source of truth. SwiftQuery works alongside `@Query`: `@Query` reads your data and `@QueryClient` keeps it in sync.

## Features

- Sync whole collections, single rows, related models, or standalone values
- Deduplicated fetches, one shared client per key
- `forever` and stale-while-revalidate caching, persisted across launches
- Streams that run while a view shows the data
- Invalidate, refetch, cancel, remove and reset by key, type or tag
- Optimistic mutations with rollback and ordered scopes

## Requirements

- Swift 6.0+
- iOS 17+, macOS 14+, tvOS 17+, watchOS 10+, visionOS 1+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/eriicafes/swift-query.git", from: "0.1.0")
]
```

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SwiftQuery", package: "swift-query")
    ]
)
```

## AI Skills

```sh
npx skills add eriicafes/swift-query
```

## Models

A `QueryModel` syncs a whole SwiftData collection. The model type is the key.

```swift
extension User: QueryModel {
    struct State: Codable {
        var etag: String?
    }

    static var cache: QueryCache { .swr(staleTime: .seconds(30)) }

    static func fetch(context: ModelContext, fetchContext: APIClient, state: State?) async throws -> State {
        let response = try await fetchContext.users(etag: state?.etag)
        guard let users = response.users else { return state ?? State() } // 304
        try upsert(users, into: context) // your own insert/update logic
        return State(etag: response.etag)
    }
}
```

- `fetch` writes rows into `context`, a fresh context per fetch. Pending changes are saved when it returns and discarded if it throws.
- `state` is what the last successful fetch returned, or `nil` before the first one. Return the new state; it's saved after a successful fetch.
- `Context` (your dependencies) and `State` (any `Codable` value) are inferred from `fetch`.
- Only `fetch` and `cache` are required. `tags`, `subscribe` and `evict` are optional.

## Fetchers

A `QueryFetcher` syncs anything else. The fetcher value is the key, so each value has its own client, state and cache.

A fetcher can write rows, such as one user's profile:

```swift
struct UserDetail: QueryFetcher {
    let id: String
    var cache: QueryCache? { .swr(staleTime: .seconds(30)) }
    var tags: Set<String> { ["users", "user-\(id)"] }

    func fetch(context: ModelContext, fetchContext: APIClient, state: Date?) async throws -> Date {
        let dto = try await fetchContext.profile(userID: id)
        // create or update the User row and its profile
        return .now
    }
}
```

Or return a value that has no model of its own. SwiftQuery stores it as the fetcher's `State`, in its own `QueryRecord` table, or only in memory when `cache` is `nil`:

```swift
struct ExchangeRate: QueryFetcher {
    let from: String, to: String
    var cache: QueryCache? { .swr(staleTime: .seconds(60)) }

    func fetch(context: ModelContext, fetchContext: APIClient, state: Double?) async throws -> Double {
        try await fetchContext.rate(from, to)
    }
}
```

- `cache` and `tags` are instance members, so they can depend on the key. A `nil` cache keeps the state in memory for the session.
- Keep the synthesized `Hashable` and `Codable` conformances. Equality picks the client and the encoding names the stored record. Changing a fetcher's properties changes its keys.

Common detail queries, all keyed by a row's id:

| Kind | Writes | `evict` |
|---|---|---|
| A collection row | That row | Nothing; the collection owns it |
| Extra fields on a row | Columns the list doesn't return | Clears those fields |
| A related model | A model attached with `.cascade` | Nothing; deleted with the row |
| Rows the fetcher owns | Top-level rows only this key uses | Deletes its own rows |
| A standalone value | Only its `State` | Nothing |

Have each one create or update the row from its own response, so it works before the collection has loaded, for example from a deep link.

## Caching

```swift
.forever()                                    // fresh until invalidated
.forever(refreshAfter: .seconds(300))         // stale after 5 minutes, kept forever
.swr()                                        // stale after 5 minutes, removed after 24 hours unused
.swr(staleTime: .seconds(30), cacheTime: .seconds(3600))
```

- A key is in use while a view shows it. `cacheTime` counts from the last use.
- An expired key is evicted on its next sync, or by `provider.collectGarbage()`, for example when the app goes to the background. Eviction runs `evict(context:)`, which deletes nothing by default.
- Evicting a key invalidates other keys that share one of its tags, so `UserDetail` refetches after the `User` collection is evicted.

## Status

```swift
enum QueryStatus<Value> {
    case pending                            // nothing fetched yet
    case success(value: Value, stale: Bool)
    case error(any Error)                   // failed with nothing fetched yet
}

enum QueryFetchStatus { case idle, loading, fetching }
```

A client's `status` carries its `State`, and `fetchStatus` tracks fetch activity. If a refresh fails after an earlier success, `status` stays `.success(value, stale: true)` and the failure goes to `client.error`.

## Provider

Create one `QueryProvider` and include `QueryRecord.self` in the container.

```swift
QueryProvider(
    modelContainer: container,
    contexts: api, Message.Context(api: api, socket: socket),
    fetchers: User.self, Message.self, UserDetail.self
)
```

- **`contexts:`** registers dependencies by type. Keys whose `Context` type matches share the value. For a protocol type, cast it: `client as any HTTPClient`. `Void` and types conforming to `DefaultFetchContext` need no registration.
- **`fetchers:`** lists every persisted model and fetcher type, so expired caches can be evicted even when no client exists.
- **Clients** are created on first use. An unused fetcher client is dropped after `gracePeriod` (5 minutes), and model clients last the whole session.

Reading and writing state:

```swift
provider.status(for: UserDetail(id: "42"))                      // no fetch
try await provider.query(ExchangeRate(from: "USD", to: "EUR"))  // cached if fresh, else fetch
provider.prefetch(UserDetail(id: "42"))
try await provider.setState(for: ExchangeRate(from: "USD", to: "EUR"), 0.92)
```

`query` takes a `staleTime`: `.after(duration)` for a maximum age, or `.infinite` to accept any cached value.

Bulk operations take a fetcher value, a type, or `tag:`:

```swift
provider.invalidate(tag: "users")        // mark stale; visible keys re-sync
await provider.refetch(UserDetail.self)  // fetch keys with a live client
provider.cancel(UserDetail(id: "42"))    // stop in-flight fetches
await provider.remove(tag: "user-42")    // evict rows and state
await provider.reset(User.self)          // remove, then re-sync visible keys
```

### CloudKit

Keep `QueryRecord` out of CloudKit with `.queryRecords`, a local-only configuration:

```swift
let container = try ModelContainer(
    for: Schema([User.self, QueryRecord.self]),
    configurations:
        ModelConfiguration(schema: Schema([User.self]), cloudKitDatabase: .automatic),
        .queryRecords
)
```

## Views

```swift
struct UsersView: View {
    @QueryClient(User.self) private var usersClient
    @Query(sort: \User.name) private var users: [User]

    var body: some View {
        List(users) { Text($0.name) }
            .overlay {
                if usersClient.fetchStatus == .loading { ProgressView() }
            }
            .refreshable { await usersClient.refresh() }
    }
}
```

For a key built from view input, assign the wrapper in `init`:

```swift
@QueryClient<UserDetail> private var detail: ModelQueryClient<UserDetail>

init(id: String) {
    _detail = QueryClient(UserDetail(id: id))
}
```

`@QueryClient` syncs when the view appears and when its scene becomes active, and starts the key's stream. Views of the same key share one client.

Client operations:

```swift
client.sync()                     // fetch if stale
await client.refresh()            // always fetch
client.invalidate()               // mark stale
client.cancel()                   // stop the in-flight fetch
```

## Mutations

```swift
try await usersClient.mutate {
    try await api.rename(id: id, to: name)
} optimistic: { context in
    guard let user = try context.fetch(FetchDescriptor<User>(predicate: #Predicate { $0.id == id })).first else {
        return nil
    }
    let previous = user.name
    user.name = name
    return { _ in user.name = previous }   // rollback
}
```

- The optimistic update applies right away and is saved to the main context.
- On success, the client refetches its key. On failure, the rollback runs and the error is rethrown.
- A mutation refetches only its own key. Invalidate related keys yourself, for example `provider.invalidate(tag: "users")`.
- Cancelling the caller doesn't cancel a request that was already sent.

Mutations with the same `scope` reach the server one at a time, in order. Use one scope per record:

```swift
try await usersClient.mutate(scope: "user-\(id)") { ... }
```

## Streams

Implement `subscribe` to keep a stream open while a view shows the key:

```swift
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
```

- `subscribe` returns the task without awaiting anything itself.
- The stream starts when a view appears and stops when its client is dropped.
- `writer.update` advances the saved state, so the next fetch resumes after the streamed data. Keep updates monotonic, as with `max`.

## Isolation

`fetch` runs off the main actor. If your target uses MainActor default isolation, mark the conformance `nonisolated`:

```swift
nonisolated extension User: QueryModel { ... }
```

## Example

A small app that syncs a list of posts from a JSON API.

```swift
import SwiftData
import SwiftQuery
import SwiftUI

struct PostDTO: Codable {
    let id: Int
    let title: String
}

struct API: Sendable {
    func posts() async throws -> [PostDTO] {
        let url = URL(string: "https://jsonplaceholder.typicode.com/posts")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([PostDTO].self, from: data)
    }
}

@Model
final class Post {
    @Attribute(.unique) var id: Int
    var title: String

    init(id: Int, title: String) {
        self.id = id
        self.title = title
    }
}

extension Post: QueryModel {
    static var cache: QueryCache { .swr(staleTime: .seconds(60)) }

    static func fetch(context: ModelContext, fetchContext: API, state: Date?) async throws -> Date {
        for dto in try await fetchContext.posts() {
            context.insert(Post(id: dto.id, title: dto.title)) // upserts by unique id
        }
        return .now
    }
}

@main
struct PostsApp: App {
    let container = try! ModelContainer(for: Post.self, QueryRecord.self)
    let provider: QueryProvider

    init() {
        provider = QueryProvider(modelContainer: container, contexts: API(), fetchers: Post.self)
    }

    var body: some Scene {
        WindowGroup {
            PostsView()
                .modelContainer(container)
                .environment(provider)
        }
    }
}

struct PostsView: View {
    @QueryClient(Post.self) private var client
    @Query(sort: \Post.id) private var posts: [Post]

    var body: some View {
        NavigationStack {
            List(posts) { Text($0.title) }
                .overlay {
                    if client.fetchStatus == .loading { ProgressView() }
                }
                .refreshable { await client.refresh() }
                .navigationTitle("Posts")
        }
    }
}
```
