---
"swift-query": minor
---

Changed optimistic updates to receive `OptimisticContext` and return nothing: register row rollbacks with `tx.onRollback`, and update query data with `setQueryData`, which rolls back automatically
