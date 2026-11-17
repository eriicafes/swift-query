---
"swift-query": minor
---

`invalidate` and `cancel` on the provider are now `async`, and `invalidate` takes `refetch:` (`.active` by default, `.inactive`, `.all`, or `nil` for none). `invalidate` and `refetch` wait for their fetches, and follow a fetch already in progress with a new request instead of joining it, so a key invalidated mid-fetch no longer stays stale; `reset` waits for its refetch to finish. Bulk work on stored keys without a client (marking them invalidated, evicting them, and the garbage-collection sweep) now runs off the main actor, saving once per batch, and a client created for a key while that work runs waits for it
