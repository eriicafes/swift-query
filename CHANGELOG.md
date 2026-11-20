# swift-query

## 0.4.0

### Minor Changes

- f820a38: Changed `invalidate` and `cancel` to be `async`, with `invalidate` taking `refetch:` and waiting for its refetches
- 2a09ee8: Added `isMutating` to observers and the provider, and `provider.isMutating(scope:)`
- 2a09ee8: Added `invalidates` to mutations; their keys are invalidated on success and failure, and only shown keys refetch
- 2a09ee8: Added `@MutationClient` and `MutationObserver`
- 2a09ee8: Changed optimistic updates to receive `OptimisticContext`, with `tx.onRollback` and `setQueryData`
- 2a09ee8: Changed syncs and other mutations to wait for an in-flight optimistic mutation before refetching its keys
- 4c7feff: Changed a failed mutation to defer its rollback to a newer optimistic mutation with overlapping filters while that one is in flight
- 2a09ee8: Added refetching of keys whose optimistic mutations were interrupted by app termination, with `recoversInterruptedMutations` to opt out
- 2a09ee8: Added `provider.mutate`
- 2a09ee8: Changed `invalidate`, `refetch`, `cancel`, `remove` and `reset` to take `QueryFilter`s (`.key`, `.type`, `.tag`, `.all`)
- 2a09ee8: Renamed `ModelQueryClient` to `QueryObserver`
- 7179f7a: Changed `fetch` and `evict` to take `query:` (`QueryFetch<Context, QueryData>`, `QueryEvict<Context>`), with `QueryData` required to be `Sendable`
- 7fc8f66: Added `QueryRecord.type`, the key's model or fetcher type name
- 2a09ee8: Replaced `includeStored` in `refetch` with `type: .active`, `.inactive` or `.all`
- 7179f7a: Added `refetchWhileSubscribed` to refetch stale data while a stream is synced
- 7179f7a: Changed `subscribe` to take `query: QuerySubscription<Context, QueryData>` and run until the stream ends, writing through `query.begin()`'s `QueryWriter`

## 0.1.0

### Minor Changes

- 89adb15: Added agent skills
- 89adb15: Added `forever` and stale-while-revalidate caching
- 89adb15: Added `QueryModel` and `QueryFetcher`
- 89adb15: Added optimistic mutations with ordered scopes
- 89adb15: Added `query`, `getQueryData` and `setQueryData`, and invalidate, refetch, cancel, remove and reset by key, type or tag
- 89adb15: Added `QueryProvider`
- 89adb15: Added `@QueryClient` and `ModelQueryClient` with `QueryState`
- 89adb15: Added persisted sync metadata with `QueryRecord`
- 89adb15: Added live updates with `subscribe` and `QueryDataWriter`
