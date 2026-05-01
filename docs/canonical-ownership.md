# Canonical Ownership & One-Way Dependency

`core-harness` is **Layer 1** of the claude-org architecture. It owns the
generic framework primitives that every orchestrator harness needs:

- Permission schema type definitions (e.g. `forbidden_allow_*`,
  `required_hook_scripts`)
- Hook runner protocol (path-configurable, no hard-coded script locations)
- Audit / journal protocol
- Settings generator
- Schema validator

## Dependency direction (one-way)

```
claude-org-ja  ─depends on─►  core-harness
core-harness   ──does NOT──►  claude-org-ja
```

`core-harness` **must not** import from, name, or otherwise know about any
consuming layer. In particular, `core-harness` does not contain:

- Role names (secretary, dispatcher, curator, worker, ...) — these are
  org-specific concepts and stay in the consuming layer.
- Specific worker rosters, naming schemes, or routing rules.
- Any string or constant scoped to a particular org's deployment.

Consumers extend `core-harness` by composition: they instantiate the generic
primitives with their own data (their roles, their hooks, their forbidden
patterns). The generic side stays unaware.

## What "Layer 1 SOT" means

For the things `core-harness` *does* own (the framework schema), it is the
single source of truth. Consumers do not redefine the type of, e.g.,
`forbidden_allow_*`; they import it. Conflicts between a consumer's local
definition and `core-harness` are resolved by updating the consumer.

For the things `core-harness` does *not* own (org-specific entries / values),
the consumer is the source of truth. `core-harness` provides the schema; the
consumer fills in the data.

## Why one-way

A bidirectional dependency would let org-specific decisions leak into the
shared framework, defeating the point of extraction. Keeping the dependency
one-way is what lets multiple orgs (or multiple deployments) reuse
`core-harness` without coordinating with each other.
