# SwiftQuery

`swift-query` is a sync and caching layer for SwiftData, inspired by React Query. It fetches remote data into SwiftData, keeps it fresh, subscribes to live updates, and applies optimistic mutations.

SwiftData stays the source of truth. Your views keep reading data with SwiftData's `@Query`, and SwiftQuery's `@QueryClient` keeps that data in sync with the server.

## Requirements

- Swift 6.0+
- iOS 17+, macOS 14+, tvOS 17+, watchOS 10+, visionOS 1+

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/eriicafes/swift-query.git", from: "0.3.0")
]
```

Then add the product to your target:

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

## Getting Started

Syncing a SwiftData collection takes three steps: set up the container and provider, describe how to fetch the model, and show it in a view.

### 1. Set up the container and provider

SwiftQuery records when each piece of data was last fetched in its own model, `QueryRecord`. Add it to your container alongside your own models:

```swift
let container = try ModelContainer(for: Post.self, QueryRecord.self)
```

If your app syncs its models with CloudKit, keep `QueryRecord` out of it. Sync timestamps describe what one device has fetched, so they shouldn't sync to others. Give `QueryRecord` its own configuration with CloudKit turned off, and a name of its own so SwiftData stores it in a separate file:

```swift
let container = try ModelContainer(
    for: Schema([Post.self, QueryRecord.self]),
    configurations:
        ModelConfiguration(schema: Schema([Post.self]), cloudKitDatabase: .automatic),
        ModelConfiguration("SwiftQuery", schema: Schema([QueryRecord.self]), cloudKitDatabase: .none)
)
```

Keep that name once your app ships: a new name means a new, empty store, and every query fetches again.

Then create one `QueryProvider` for the app. It needs your container, the dependencies your fetches use (here an `API` client), and the list of types it syncs. Inject both into the environment:

```swift
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
```

`contexts:` and `fetchers:` are explained in [Fetch dependencies](#fetch-dependencies) and [Cleaning up](#cleaning-up).

### 2. Describe how to fetch the model

Conform your model to `QueryModel` and implement `fetch`. It downloads the data and writes it into the `ModelContext` it's given:

```swift
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

    static func fetch(query: QueryFetch<API, Date>) async throws -> Date {
        for dto in try await query.context.posts() {
            query.modelContext.insert(Post(id: dto.id, title: dto.title)) // upserts by unique id
        }
        return .now
    }
}
```

- `query.modelContext` is a fresh `ModelContext` for this fetch. Changes are saved when `fetch` returns, and thrown away if it throws.
- `query.context` is the dependency from `contexts:`, found by its type. The first type in `QueryFetch<API, Date>` says which type; here it's the `API` registered earlier. The second is the type `fetch` returns.
- `fetch` returns a small piece of data that SwiftQuery stores for you, called the query data. Its type is inferred from the return type. The next fetch receives it back as `query.previous`. This example has nothing to remember, so it returns the time it fetched. The next sections show query data that matters, such as an ETag.
- `cache` decides how long the data stays fresh. See [Caching](#caching).

### 3. Show it in a view

Read the posts with `@Query` as usual, and add `@QueryClient` to keep them in sync:

```swift
struct PostsView: View {
    @QueryClient(Post.self) private var client
    @Query(sort: \Post.id) private var posts: [Post]

    var body: some View {
        List(posts) { Text($0.title) }
            .overlay {
                if client.isLoading { ProgressView() }
            }
            .refreshable { await client.refresh() }
    }
}
```

`@QueryClient` fetches when the view appears, if the data is missing or stale, and again when the app returns to the foreground. Every view that uses `@QueryClient(Post.self)` shares one client, so the posts are fetched once no matter how many views show them.

## Fetch Dependencies

A fetch usually has dependencies, such as a URL session, a socket, credentials or settings. You pass them to the provider in `contexts:`, and each fetch receives the one whose type matches its `Context` as `query.context`.

```swift
struct API: Sendable {
    func posts() async throws -> [PostDTO] { ... }
}

QueryProvider(modelContainer: container, contexts: API(), fetchers: Post.self)

// Post's fetch takes `QueryFetch<API, Date>`, so it receives this API as `query.context`.
```

A fetch can ask for any `Sendable` type, and several models can ask for the same type and share one value. When a fetch needs several things, group them in a struct:

```swift
extension Message: QueryModel {
    struct Context: Sendable {
        let api: API
        let socket: Socket
    }

    static func fetch(query: QueryFetch<Context, Cursor>) async throws -> Cursor { ... }
}

QueryProvider(
    modelContainer: container,
    contexts: api, Message.Context(api: api, socket: socket),
    fetchers: Post.self, Message.self
)
```

To depend on a protocol rather than a concrete type, for example so tests can pass a fake, use the protocol as the context type and cast the value when you register it:

```swift
protocol PostsService: Sendable {
    func posts() async throws -> [PostDTO]
}

struct LivePostsService: PostsService { ... }

extension Post: QueryModel {
    static func fetch(query: QueryFetch<any PostsService, Date>) async throws -> Date { ... }
}

QueryProvider(
    modelContainer: container,
    contexts: LivePostsService() as any PostsService,  // registered as `any PostsService`
    fetchers: Post.self
)
```

Without the cast, the value would be registered as `LivePostsService` and the fetch wouldn't find it.

Some dependencies need no registration:

- A type that conforms to `DefaultFetchContext` (which requires an empty `init()`) is created by the provider when nothing is registered for it.
- A fetch that needs nothing can take `Void` as its context: `QueryFetch<Void, Date>`.

The provider checks at launch that every type in `fetchers:` can find its dependency, and stops with a message naming the missing type if one can't.

## Caching

A query's `cache` decides when its data is fresh and how long it's kept:

```swift
.forever()                                       // fresh until you invalidate it
.forever(refreshAfter: .seconds(5 * 60))         // refetched after 5 minutes, never removed
.swr()                                           // refetched after 5 minutes, removed after 24 hours unused
.swr(staleTime: .seconds(30), gcTime: .seconds(60 * 60))
```

- **Fresh** data is shown without fetching. **Stale** data is still shown, and a fetch runs in the background to replace it.
- `staleTime` is how long data stays fresh after a fetch.
- `gcTime` is how long unused data is kept with `.swr`. Data is in use while a view shows it, and the clock starts when the last such view goes away. When it runs out, the data is removed (see [Cleaning up](#cleaning-up)).
- Fetched data and its freshness are saved, so they survive app launches.

A view can ask for different timing for its own requests:

```swift
@QueryClient(Post.self, .swr(staleTime: .seconds(10))) private var client
```

## Query State

Each client tracks its query's state and whether a fetch is running:

```swift
enum QueryState<QueryData> {
    case pending                                // nothing fetched yet
    case success(data: QueryData, stale: Bool)
    case error(any Error)                       // the first fetch failed
}

enum QueryFetchStatus { case idle, fetching }
```

The client also offers shortcuts:

- `client.data` is the query data from the last successful fetch.
- `client.isLoading` is true during the first fetch, when there's nothing to show yet. `client.isFetching` is true during any fetch.
- `client.error` holds the last fetch error. If a refresh fails after an earlier success, the state stays `.success(data, stale: true)`, so your view keeps showing the old data, and the failure is reported here.

For most models you won't read the query data directly: your rows are in SwiftData, and the query data is bookkeeping such as an ETag. It matters for [standalone values](#standalone-values).

## Fetchers

`QueryModel` syncs a whole collection, and the model type identifies it. Most apps also need to fetch smaller pieces: one user's profile, the comments on one post, an exchange rate. For these, write a `QueryFetcher`.

A fetcher is a struct, and its value identifies the data. `UserDetail(id: "42")` and `UserDetail(id: "7")` are fetched, cached and refreshed separately:

```swift
struct UserDetail: QueryFetcher {
    let id: String

    var cache: QueryCache? { .swr(staleTime: .seconds(30)) }

    func fetch(query: QueryFetch<API, Date>) async throws -> Date {
        let dto = try await query.context.user(id: id)
        // create or update the User row for dto
        return .now
    }
}
```

Use it in a view the same way. When the fetcher depends on the view's input, set it up in `init`:

```swift
struct UserView: View {
    @QueryClient<UserDetail> private var detail: QueryObserver<UserDetail>
    @Query private var users: [User]

    init(id: String) {
        _detail = QueryClient(UserDetail(id: id))
        _users = Query(filter: #Predicate<User> { $0.id == id })
    }

    var body: some View {
        if let user = users.first {
            Text(user.name)
        } else if detail.isLoading {
            ProgressView()
        }
    }
}
```

Fetchers work like models, with two differences:

- `cache` is a property of the value, so it can depend on it. Return `nil` to keep the query data in memory only, for the current session.
- A fetcher must be `Hashable` and `Codable`. Keep the conformances Swift generates: they identify the fetcher in memory and in storage.

Have a fetcher create or update the row from its own response rather than assume the row already exists. Then it also works when the screen is opened directly, for example from a deep link, before the full list has loaded.

### Standalone values

Not everything belongs in a model. A fetcher can return the value itself as its query data, and SwiftQuery stores it for you:

```swift
struct ExchangeRate: QueryFetcher {
    let from: String
    let to: String

    var cache: QueryCache? { .swr(staleTime: .seconds(60)) }

    func fetch(query: QueryFetch<API, Double>) async throws -> Double {
        try await query.context.rate(from: from, to: to)
    }
}

struct RateView: View {
    @QueryClient(ExchangeRate(from: "USD", to: "EUR")) private var rate

    var body: some View {
        if let value = rate.data {
            Text(value, format: .number)
        }
    }
}
```

The value is saved in SwiftQuery's own `QueryRecord` model, so it's available on the next launch. With `cache: nil`, it's kept in memory only.

### Query data across fetches

`query.previous` lets a fetch build on the last one, for example to send an ETag:

```swift
extension Post: QueryModel {
    struct QueryData: Codable {
        var etag: String?
    }

    static var cache: QueryCache { .swr(staleTime: .seconds(60)) }

    static func fetch(query: QueryFetch<API, QueryData>) async throws -> QueryData {
        let response = try await query.context.posts(etag: query.previous?.etag)
        guard let posts = response.posts else {
            return query.previous ?? QueryData() // 304 Not Modified: keep everything
        }
        for dto in posts {
            query.modelContext.insert(Post(id: dto.id, title: dto.title))
        }
        return QueryData(etag: response.etag)
    }
}
```

`query.previous` is `nil` before the first successful fetch. The same pattern works for cursors and page tokens.

## Cleaning Up

With `.swr`, data that goes unused for `gcTime` is removed. Your rows are your own data, so by default SwiftQuery only forgets its bookkeeping and the next view fetches again. To delete rows too, implement `evict(query:)`:

```swift
extension Post: QueryModel {
    static func evict(query: QueryEvict<API>) throws {
        try query.modelContext.delete(model: Post.self)
    }
}
```

`query.context` is the same dependency `fetch` gets, for cleanup that needs it, such as a file cache directory.

Only delete rows that came from the server and that nothing else shows.

SwiftQuery cleans up expired data automatically: when it's next used, once when the app launches, and whenever the app goes to the background. To clean up at another time, call `provider.collectGarbage()`.

This is what `fetchers:` is for: the provider can only clean up types it knows about, so list every model and fetcher you persist. A debug build stops with an assertion if you use a persisted type that isn't listed. Fetchers with `cache: nil` don't need to be listed.

What a fetcher should clean up depends on what it writes:

| A fetcher that writes | Should `evict` | Why |
|---|---|---|
| A row from a collection | Nothing | The collection owns the row |
| Extra fields on a row | Clear those fields | The row stays; only these fields are the fetcher's |
| A model related to a row, with `.cascade` | Nothing | It's deleted along with the row |
| Rows only it uses | Delete exactly those rows | Nothing else will |
| A standalone value | Nothing | SwiftQuery removes the value itself |

## Using the Provider Directly

Views get their data through `@QueryClient`. Code outside views, such as a deep link handler, a background task or a view model, can use the provider.

Read what's already cached, without fetching:

```swift
let rate = provider.getQueryData(for: ExchangeRate(from: "USD", to: "EUR"))   // Double?
let state = provider.getQueryState(for: UserDetail(id: "42"))                // QueryState<Date>
```

Get fresh data, fetching only if what's cached is stale:

```swift
let rate = try await provider.query(ExchangeRate(from: "USD", to: "EUR"))
```

`query` waits for the fetch and throws if it fails. Pass `staleTime` to decide what counts as fresh for this call:

```swift
try await provider.query(UserDetail(id: "42"), staleTime: .after(.seconds(10)))  // at most 10 seconds old
try await provider.query(UserDetail(id: "42"), staleTime: .after(.zero))         // always fetch
try await provider.query(UserDetail(id: "42"), staleTime: .infinite)             // anything cached
```

Start fetching before it's needed, for example just before navigating to a screen:

```swift
provider.prefetch(UserDetail(id: "42"))
```

Store a value you already have, for example one returned by a mutation, so it doesn't need fetching:

```swift
try await provider.setQueryData(for: ExchangeRate(from: "USD", to: "EUR"), 0.92)
```

Each of these also accepts a model type, such as `provider.getQueryState(for: Post.self)`.

## Invalidating and Refreshing

Invalidating marks data as stale. Views showing it fetch again right away, and `invalidate` waits for those fetches; other data is fetched the next time it's used. A fetch already in progress may have started before the change, so it's followed by a new one. Data an optimistic mutation is still changing waits until that mutation finishes, so the change isn't overwritten.

You pick which data with filters:

```swift
client.invalidate()                                         // the data behind this client
await provider.invalidate(.key(UserDetail(id: "42")))       // one fetcher value
await provider.invalidate(.key(postsClient))                // the data behind a client
await provider.invalidate(.type(UserDetail.self))           // every UserDetail
await provider.invalidate(.type(Post.self))                 // the Post collection
await provider.invalidate(.tag("users"))                    // everything tagged "users"
await provider.invalidate(.all)                             // everything
await provider.invalidate(.tag("users"), .type(Post.self))  // several at once
```

Pass `refetch:` to choose what fetches right away: `.active` (the default) for data shown in a view, `.inactive` for everything else including data saved earlier, `.all` for both, or `nil` to only mark it stale.

Tags group data that changes together. Give models and fetchers tags with `tags`:

```swift
extension User: QueryModel {
    static var tags: Set<String> { ["users"] }
}

struct UserDetail: QueryFetcher {
    var tags: Set<String> { ["users", "user-\(id)"] }
}
```

The provider's other operations take the same filters:

| Operation | What it does |
|---|---|
| `invalidate` | Marks data as stale; shown data is fetched again |
| `refetch` | Fetches now, without marking anything stale |
| `cancel` | Stops fetches in progress and keeps the previous data |
| `remove` | Stops fetches in progress, then deletes the data, running `evict` |
| `reset` | Removes the data, then fetches it again for views showing it |

All of them are `async`. `invalidate`, `refetch` and `reset` return once their fetches finish, and like `invalidate`, `refetch` follows a fetch already in progress with a new one. A failed fetch is reported by its client; none of these throw. Work on saved data that nothing is using, such as marking it stale or deleting it, runs in the background, so a large `remove(.all)` doesn't block the UI.

`refetch` fetches data shown in a view. Pass `type: .inactive` to fetch the rest instead, including data saved earlier that nothing has used yet, or `type: .all` for both:

```swift
await provider.refetch(.tag("users"))               // what's on screen
await provider.refetch(.all, type: .all)            // everything, for example after signing in
```

A single client offers the same for its own data: `client.sync()` fetches if stale, `client.refresh()` always fetches, and `client.cancel()` stops a fetch in progress.

When data is removed, everything that shares a tag with it is invalidated, so details refetch after the list they belong to is removed. Keys removed together don't count: `remove(.tag("users"))` doesn't refetch any of the keys it removes.

A cancelled fetch never saves the rows it left in `query.modelContext`. Rows a fetcher saved itself before it was cancelled stay, except when it was cancelled by `remove` or `reset`: those wait for the fetch to stop, then evict. So a fetcher that saves on its own should check for cancellation first, with `try Task.checkCancellation()`.

## Mutations

Run a mutation from the client whose data it changes, and that data is fetched again afterwards so it matches the server:

```swift
try await postsClient.mutate {
    try await api.deletePost(id: id)
}
```

If the change affects other data too, list it in `invalidates`. It takes the same filters as `invalidate`:

```swift
try await postClient.mutate(invalidates: [.tag("users")]) {
    try await api.like(postID: id)
}
```

When the mutation finishes, whether it succeeded or failed, that data is invalidated. Data shown in a view is fetched again and `mutate` waits for it, so your view is up to date when `mutate` returns. Other data is fetched the next time it's used.

### Optimistic updates

To update the screen before the server responds, pass an `optimistic` closure. Change rows in `tx.modelContext` and register a closure with `tx.onRollback` that undoes the change if the request fails:

```swift
try await postsClient.mutate {
    try await api.rename(postID: id, to: title)
} optimistic: { tx in
    guard let post = try tx.modelContext.fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.id == id })).first else {
        return
    }
    let previous = post.title
    post.title = title
    tx.onRollback { _ in post.title = previous }   // undo
}
```

Query data, such as a count from a fetcher, is updated with `tx.setQueryData`. You don't write an undo for it; SwiftQuery puts the previous value back if the request fails:

```swift
try await profileClient.mutate {
    try await api.follow(userID: id)
} optimistic: { tx in
    tx.setQueryData(for: FollowerCount(userID: id)) { $0 += 1 }
}
```

- If the request succeeds, the changes stay until the data is fetched again.
- If it fails, the undo closures run (newest first), query data is put back, and the error is thrown to you. Query data is only put back if nothing, such as a fetch, has changed it since. If a newer optimistic mutation may have changed the same data since, the undo closures don't run now, so they can't undo the newer change. While the newer one's request is in flight, they wait for it: if it fails too, they run after its own; if it succeeds, they're dropped. Either way the data is fetched again. A newer mutation counts when it invalidates overlapping data: the same key or type, or any tag or `.all`. Sharing a scope doesn't count, so scoped mutations that change the same rows should list them in `invalidates`. A mutation that invalidates nothing never counts, and its undo closures always run.
- `setQueryData` stops a fetch of that data in progress, so an older response can't overwrite the change, and the data is invalidated when the mutation finishes. A `provider.query` waiting on that fetch gets the updated value.
- While the request is in flight, the data it invalidates isn't fetched by views or by other mutations finishing, so the server's older data can't overwrite the change. Pull-to-refresh and `provider.query` still fetch.
- Once a request is sent, cancelling the task that called `mutate` doesn't cancel it.
- If the app is quit before a mutation finishes, the data it would have invalidated is fetched again at the next launch, so an optimistic change the server never confirmed doesn't stay. If an app extension creates its own provider on the same store, pass `recoversInterruptedMutations: false` to it, so it doesn't mistake the app's mutations in progress for interrupted ones.

### Scopes

When several edits to the same thing can happen quickly, give them a `scope`. Mutations in the same scope reach the server one at a time, in the order they were made:

```swift
try await postsClient.mutate(scope: "post-\(id)") {
    try await api.rename(postID: id, to: title)
}
```

Their data is invalidated once, after the last one finishes.

### Mutations in views

`@MutationClient` runs mutations from a view and tracks the latest one, for a spinner or an error message:

```swift
struct FollowButton: View {
    let userID: String
    @MutationClient private var follow

    var body: some View {
        Button("Follow") {
            follow.mutate(invalidates: [.key(FollowerCount(userID: userID))]) {
                try await api.follow(userID: userID)
            }
        }
        .disabled(follow.isPending)
        if let error = follow.error {
            Text(error.localizedDescription)
        }
    }
}
```

Called from a button's action, `mutate` returns right away and reports failures through `error`. Called with `await`, it returns the result and throws instead. In async code, such as `.task`, Swift always picks the awaited form; to start one there without waiting, wrap it in a closure: `_ = { follow.mutate { ... } }()`.

To keep the request's input and result, give the client their types. `variables` holds the latest input and `data` the latest result:

```swift
@MutationClient<String, Message> private var send

send.mutate(text) { text in
    try await api.send(text)
} optimistic: { tx, text in
    tx.modelContext.insert(Message(text: text, pending: true))
}
```

Use `@MutationClient<Void, Message>` to keep only the result. `follow.reset()` clears the status, error, input and result.

`status`, `isPending`, `error`, `variables` and `data` follow the latest call. `isMutating` stays `true` while any call made through the wrapper is still running.

A `scope` and `invalidates` given to the wrapper apply to each of its mutations. A call's own `scope` replaces the wrapper's, and its `invalidates` are added to the wrapper's:

```swift
@MutationClient(scope: "settings", invalidates: [.tag("settings")]) private var save
```

### Mutations outside views

Code outside views, or a mutation that doesn't belong to one client, can use the provider:

```swift
try await provider.mutate(scope: "user-\(id)", invalidates: [.tag("users")]) {
    try await api.follow(userID: id)
}
```

To track a mutation's status outside a view, for example in a view model, create a `MutationObserver`. It's what `@MutationClient` gives a view:

```swift
@Observable @MainActor
final class ProfileModel {
    let follow: MutationObserver<Void, Void>

    init(provider: QueryProvider) {
        follow = MutationObserver(provider: provider, invalidates: [.tag("users")])
    }
}
```

`provider.isMutating` tells you whether any mutation is running, for example before signing out, and `provider.isMutating(scope:)` whether one in a scope is. `client.isMutating` covers mutations started from that client.

## Subscribe

Some data arrives continuously, such as chat messages over a socket. Implement `subscribe` to keep receiving updates while a view shows the data. It runs until the stream ends:

```swift
extension Message: QueryModel {
    struct QueryData: Codable {
        var lastSeq = 0
    }

    static func subscribe(query: QuerySubscription<Context, QueryData>) async throws {
        let socket = try await query.context.socket.connect()
        let writer = await query.begin()
        for try await event in socket.messages {
            try await writer.write { tx in
                guard event.seq > (tx.data?.lastSeq ?? 0) else { return } // the fetch already has it
                tx.modelContext.insert(Message(event))
                tx.data?.lastSeq = event.seq
            }
        }
    }
}
```

- `subscribe` is called when a view shows the data. It's cancelled a few minutes after the last such view goes away. The delay is 5 minutes by default; change it with the provider's `keepAliveTime:` argument.
- `query.begin()` starts a fetch and returns the writer. Writes wait until that fetch has succeeded, then see its rows and data, so they can skip events it already brought in. A view's first sync doesn't fetch on its own; `begin()` does, so the stream costs one fetch.
- Call `begin()` after connecting if the stream can't resume from a cursor, so the fetch covers everything sent before the connection. A stream that resumes from `query.previous`, or sends its own snapshot, can call it before connecting.
- Set a connect timeout. Until `begin()` is called the data isn't fetched, so a connect that hangs would leave it unfetched; one that times out throws, which fetches at once.
- Write rows and query data only through `writer.write`. It runs on the key's actor, and saves both together, so a fetch never lands in the middle of a write or overwrites it while it runs. Keep the closure short, and apply several events in one write when the stream is busy, since each write saves.
- While a write waits, your loop doesn't read the next event, so events wait in your socket or stream instead of piling up in SwiftQuery.
- Return or throw when the stream drops, without reconnecting yourself. While a view shows the data, `subscribe` is called again after a short backoff, and its `begin()` fetches what was missed.
- Returning without calling `begin()` means there are no live updates; the data is fetched as usual.
- While the stream is synced, the data isn't refetched when it goes stale, because the stream keeps it current. Set `refetchWhileSubscribed` to `true` to refetch anyway. Invalidating always refetches.
- If the fetch from `begin()` fails, it's retried with a backoff, and writes keep waiting. Once synced, a failed refetch doesn't hold writes back.
- `remove` and `reset` cancel the stream and wait for it to stop, so respect cancellation.

To handle events yourself while a fetch runs, write with `.now`. It runs right away, and `tx.isSynced` says whether a fetch is still pending, for example to keep events in your own buffer and apply them once `writer.synced()` returns:

```swift
let applied = try await writer.write(.now) { tx in
    guard tx.isSynced else { return false }
    tx.modelContext.insert(Message(event))
    return true
}
if !applied { buffer.append(event) }
```

A fetch that finishes after a `.now` write wins: rows it saves and the data it returns replace what the write stored. Rows only the write touched stay. Query data a `.now` write sets before the stream first syncs is kept in memory only, so a cursor moved past events no fetch has covered isn't saved; it's replaced when that fetch succeeds, and dropped if the stream ends first.

If an optimistic mutation's request fails after a stream wrote the same row, its rollback overwrites the stream's change. The mutation's `invalidates:` refetch then brings the row up to date.

## Concurrency

`fetch` and `subscribe` run off the main actor, so decoding, creating models and saving don't block the UI.

Each fetch gets its own `ModelContext`, and so does each of a stream's writes; they never leave their `fetch` or write. Saving them updates the main context, so `@Query` sees the changes.

### Main-actor default isolation

In a Swift 6.2 app target that uses main-actor default isolation, as new Xcode projects do, two things need `nonisolated`.

The conformance, or the code won't compile:

```swift
nonisolated extension Post: QueryModel { ... }
```

The types your `fetch` calls into, such as the ones in your fetch context, or their work moves back to the main thread:

```swift
nonisolated struct API: Sendable {
    func posts() async throws -> [PostDTO] { ... }
}
```

Without the second one, everything still compiles and works, but each call from `fetch` hops to the main actor, so work such as decoding happens on the main thread.

## Example

A complete app that syncs posts from a JSON API:

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

    static func fetch(query: QueryFetch<API, Date>) async throws -> Date {
        for dto in try await query.context.posts() {
            query.modelContext.insert(Post(id: dto.id, title: dto.title)) // upserts by unique id
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
                    if client.isLoading { ProgressView() }
                }
                .refreshable { await client.refresh() }
                .navigationTitle("Posts")
        }
    }
}
```
