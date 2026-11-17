---
"swift-query": minor
---

Changed `fetch` and `evict` to take `query:` (`QueryFetch<Context, QueryData>`, `QueryEvict<Context>`), with `QueryData` required to be `Sendable`
