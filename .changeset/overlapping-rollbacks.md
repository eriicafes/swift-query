---
"swift-query": minor
---

Changed a failed mutation to skip its rollback whenever a newer optimistic mutation in the same scope or with overlapping filters has started, including from the provider and mutation observers, instead of only within a scope or one query observer
