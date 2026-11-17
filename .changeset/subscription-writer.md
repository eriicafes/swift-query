---
"swift-query": minor
---

Changed `subscribe` to take `query: QuerySubscription<Context, QueryData>` and run until the stream ends, writing through `query.begin()`'s `QueryWriter`
