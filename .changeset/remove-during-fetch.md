---
"swift-query": patch
---

Fixed `remove` and `reset` letting a fetch in progress save its rows back after eviction, and stopped keys removed together from refetching each other through a shared tag
