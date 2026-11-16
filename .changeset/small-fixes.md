---
"swift-query": patch
---

Fixed duplicate query records keeping one that never synced, `refetch` fetching keys that were never fetched, and a client showing an optimistic update that couldn't be stored; stored state that hasn't changed is no longer decoded on every sync
