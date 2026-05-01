# Public API Surface — 0.x

> **Status: TBD.** This document tracks the evolving public surface during
> the pre-1.0 phase. Items here are not stable and may change between minor
> versions per [`semver-policy.md`](semver-policy.md).

## Modules

| Module | Status | Notes |
|---|---|---|
| `core_harness.schema` | placeholder | Framework schema (Layer 1 SOT). Will host type definitions for `forbidden_allow_*`, `required_hook_scripts`, etc. |
| `core_harness.validator` | placeholder | `validate_schema(...)` — raises `NotImplementedError` in 0.0.1. |
| `core_harness.generator` | placeholder | `generate_settings(...)` — raises `NotImplementedError` in 0.0.1. |
| `core_harness.hooks` | placeholder | `HookRunner` protocol. Hook script paths are configurable; default paths TBD. |
| `core_harness.audit` | placeholder | `Journal` protocol. |

## 1.0 graduation conditions

See [`semver-policy.md`](semver-policy.md) for the full criteria. In short:

- Two consumers, one month, no breaks.
- Two consecutive minors with no breaking changes.
- All entries above marked `stable` (no remaining `placeholder` /
  `experimental` for items intended for 1.0).

## Conventions used in this document

- **placeholder** — symbol exists for import-time stability; calling it
  raises `NotImplementedError`.
- **experimental** — implemented but signature/semantics likely to change.
- **stable** — signature is committed; breaking change requires a major bump
  post-1.0, or a deprecation window pre-1.0.
