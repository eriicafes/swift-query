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

    static func fetch(context: ModelContext, fetchContext: API, previous: Date?) async throws -> Date {
        for dto in try await fetchContext.posts() {
            context.insert(Post(id: dto.id, title: dto.title)) // upserts by unique id
        }
        return .now
    }
}
```

- `context` is a fresh `ModelContext` for this fetch. Changes are saved when `fetch` returns, and thrown away if it throws.
- `fetchContext` is the dependency from `contexts:`, found by its type. Here it's the `API` registered earlier.
- `fetch` returns a small piece of data that SwiftQuery stores for you, called the query data. The next fetch receives it back as `previous`. This example has nothing to remember, so it returns the time it fetched. The next sections show query data that matters, such as an ETag.
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

A fetch usually has dependencies, such as a URL session, a socket, credentials or settings. You pass them to the provider in `contexts:`, and each fetch receives the one whose type matches its `fetchContext` parameter.

```swift
struct API: Sendable {
    func posts() async throws -> [PostDTO] { ... }
}

QueryProvider(modelContainer: container, contexts: API(), fetchers: Post.self)

// Post.fetch(context:fetchContext:previous:) declares `fetchContext: API`, so it receives this API.
```

A fetch can ask for any `Sendable` type, and several models can ask for the same type and share one value. When a fetch needs several things, group them in a struct:

```swift
extension Message: QueryModel {
    struct Context: Sendable {
        let api: API
        let socket: Socket
    }

    static func fetch(context: ModelContext, fetchContext: Context, previous: Cursor?) async throws -> Cursor { ... }
}

QueryProvider(
    modelContainer: container,
    contexts: api, Message.Context(api: api, socket: socket),
    fetchers: Post.self, Message.self
)
```

To depend on a protocol rather than a concrete type, for example so tests can pass a fake, declare the parameter with the protocol and cast the value when you register it:

```swift
protocol PostsService: Sendable {
    func posts() async throws -> [PostDTO]
}

struct LivePostsService: PostsService { ... }

extension Post: QueryModel {
    static func fetch(context: ModelContext, fetchContext: any PostsService, previous: Date?) async throws -> Date { ... }
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
- A fetch that needs nothing can declare `fetchContext: Void`.

The provider checks at launch that every type in `fetchers:` can find its dependency, and stops with a message naming the missing type if one can't.

## Caching

A query's `cache` decides when its data is fresh and how long it's kept:

```swift
.forever()                                       // fresh until you invalidate it
.forever(refreshAfter: .seconds(5 * 60))         // refetched after 5 minutes, never removed
.swr()                                           // refetched after 5 minutes, removed after 24 hours unused
.swr(staleTime: .seconds(30), gcTime: .seconds(60 * 60))
```

- **Fresh** data is shown without fetching. **Stale** data is still shown, and a fetch runs in the background to replace it. This is called stale-while-revalidate.
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

    func fetch(context: ModelContext, fetchContext: API, previous: Date?) async throws -> Date {
        let dto = try await fetchContext.user(id: id)
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

    func fetch(context: ModelContext, fetchContext: API, previous: Double?) async throws -> Double {
        try await fetchContext.rate(from: from, to: to)
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

`previous` lets a fetch build on the last one. A common use is an ETag, so the server can answer "not modified":

```swift
extension Post: QueryModel {
    struct QueryData: Codable {
        var etag: String?
    }

    static var cache: QueryCache { .swr(staleTime: .seconds(60)) }

    static func fetch(context: ModelContext, fetchContext: API, previous: QueryData?) async throws -> QueryData {
        let response = try await fetchContext.posts(etag: previous?.etag)
        guard let posts = response.posts else {
            return previous ?? QueryData() // 304 Not Modified: keep everything
        }
        for dto in posts {
            context.insert(Post(id: dto.id, title: dto.title))
        }
        return QueryData(etag: response.etag)
    }
}
```

`previous` is `nil` before the first successful fetch. The same pattern works for cursors and page tokens.

## Cleaning Up

With `.swr`, data that goes unused for `gcTime` is removed. Your rows are your own data, so by default SwiftQuery only forgets its bookkeeping and the next view fetches again. To delete rows too, implement `evict(context:)`:

```swift
extension Post: QueryModel {
    static func evict(context: ModelContext) throws {
        try context.delete(model: Post.self)
    }
}
```

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

Invalidating marks data as stale. Views showing it fetch again right away, and other data is fetched the next time it's used. Data an optimistic mutation is still changing waits until that mutation finishes, so the change isn't overwritten.

You pick which data with filters:

```swift
client.invalidate()                                   // the data behind this client
provider.invalidate(.key(UserDetail(id: "42")))       // one fetcher value
provider.invalidate(.key(postsClient))                // the data behind a client
provider.invalidate(.type(UserDetail.self))           // every UserDetail
provider.invalidate(.type(Post.self))                 // the Post collection
provider.invalidate(.tag("users"))                    // everything tagged "users"
provider.invalidate(.all)                             // everything
provider.invalidate(.tag("users"), .type(Post.self))  // several at once
```

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
| `refetch` | Fetches now |
| `cancel` | Stops fetches in progress and keeps the previous data |
| `remove` | Deletes the data, running `evict` |
| `reset` | Removes the data, then fetches it again for views showing it |

`refetch` fetches data shown in a view. Pass `type: .inactive` to fetch the rest instead, including data saved earlier that nothing has used yet, or `type: .all` for both:

```swift
await provider.refetch(.tag("users"))               // what's on screen
await provider.refetch(.all, type: .all)            // everything, for example after signing in
```

A single client offers the same for its own data: `client.sync()` fetches if stale, `client.refresh()` always fetches, and `client.cancel()` stops a fetch in progress.

When data is removed, everything that shares a tag with it is invalidated, so details refetch after the list they belong to is removed.

## Mutations

A mutation changes data on the server. Run it from the client whose data it changes, and that data is fetched again afterwards so it matches the server:

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

To update the screen before the server responds, pass an `optimistic` closure. Change rows in `tx.modelContext` and return a closure that undoes the change if the request fails:

```swift
try await postsClient.mutate {
    try await api.rename(postID: id, to: title)
} optimistic: { tx in
    guard let post = try tx.modelContext.fetch(FetchDescriptor<Post>(predicate: #Predicate { $0.id == id })).first else {
        return nil
    }
    let previous = post.title
    post.title = title
    return { _ in post.title = previous }   // undo
}
```

Query data, such as a count from a fetcher, is updated with `tx.setQueryData`. You don't write an undo for it; SwiftQuery puts the previous value back if the request fails:

```swift
try await profileClient.mutate {
    try await api.follow(userID: id)
} optimistic: { tx in
    tx.setQueryData(for: FollowerCount(userID: id)) { $0 += 1 }
    return nil
}
```

- If the request succeeds, the changes stay until the data is fetched again.
- If it fails, the undo closure runs, query data is put back, and the error is thrown to you. Query data is only put back if nothing, such as a fetch, has changed it since. If a newer optimistic mutation in the same scope, or from the same client, has started since, the undo closure is skipped so it can't undo the newer change, and the data is fetched again instead.
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
    return nil
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

Some data arrives continuously, such as chat messages over a socket. Implement `subscribe` to keep receiving updates while a view shows the data. It returns a task that runs until it's cancelled:

```swift
extension Message: QueryModel {
    struct QueryData: Codable {
        var lastSeq = 0
    }

    static func subscribe(
        container: ModelContainer,
        fetchContext: Context,
        previous: QueryData?,
        writer: QueryDataWriter<QueryData>
    ) -> Task<Void, Never>? {
        Task {
            let context = ModelContext(container)
            for await event in await fetchContext.socket.messages(after: previous?.lastSeq ?? 0) {
                context.insert(Message(event))
                try? context.save()
                await writer.update { $0.lastSeq = max($0.lastSeq, event.seq) }
            }
        }
    }
}
```

- `subscribe` is called when a view shows the data. Its task is cancelled a few minutes after the last such view goes away. The delay is 5 minutes by default; change it with the provider's `keepAliveTime:` argument.
- `subscribe` should only create and return the task. Do any waiting inside it.
- `writer.update` changes the saved query data, so the next `fetch` continues after the last update the task received instead of downloading it again.

## Concurrency

`fetch` and the task returned by `subscribe` run in the background, off the main actor. Waiting for the network doesn't block the UI either way, but the work around it would: decoding a large response, creating and updating many models, and saving them to the store. Running in the background keeps that work from causing dropped frames.

Each fetch gets its own `ModelContext`, and the task returned by `subscribe` creates its own from `container`. SwiftData requires a context to be used from one place at a time, and these never leave their `fetch` or task. Saving them updates the main context, so `@Query` sees the changes.

### Main-actor default isolation

In a Swift 6.2 app target that uses main-actor default isolation, as new Xcode projects do, everything you declare runs on the main actor unless you say otherwise. Two things need `nonisolated`.

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

Without the second one, everything still compiles and works, but each call from `fetch` hops to the main actor to run, so work such as decoding happens on the main thread. You won't notice it with small responses, but large ones will stall scrolling and taps.

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

    static func fetch(context: ModelContext, fetchContext: API, previous: Date?) async throws -> Date {
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
                    if client.isLoading { ProgressView() }
                }
                .refreshable { await client.refresh() }
                .navigationTitle("Posts")
        }
    }
}
```
