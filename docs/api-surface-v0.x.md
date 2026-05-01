# Public API Surface — 0.x

> **Status: 0.1.0 published.** This document tracks the evolving public
> surface during the pre-1.0 phase. Items below are *experimental*
> unless explicitly marked `stable`; signatures may change between
> minor versions per [`semver-policy.md`](semver-policy.md).

## Modules

| Module | Status (0.1) | Notes |
|---|---|---|
| `core_harness.schema` | experimental | Framework JSON Schema + merge helper. Type-only — concrete role names / consumer regexes live in the org-extension schema (PR #196 §3). |
| `core_harness.validator` | experimental | Audit engine for per-role `settings.local.json`. |
| `core_harness.generator` | experimental | Worker `settings.local.json` template renderer. |
| `core_harness.hooks` | placeholder | Hook framework lib (Step C). |
| `core_harness.audit` | placeholder | Journal API (Step D). |

## Public symbols (0.1)

### `core_harness.schema`

| Symbol | Status | Purpose |
|---|---|---|
| `load_framework_schema() -> dict` | experimental | Return the framework JSON Schema (deep copy). |
| `framework_schema_path() -> Path` | experimental | On-disk path to the framework JSON file. |
| `merge_schemas(framework: dict \| None, org_extension: dict) -> dict` | experimental | Merge framework defaults with org-extension; result has `global`, `required_hook_scripts`, `roles`, `worker_roles` always present. |

### `core_harness.validator`

| Symbol | Status | Purpose |
|---|---|---|
| `validate_settings(settings, framework, org_extension, *, role, ...) -> ValidationResult` | experimental | Top-level entry. |
| `validate_config(source, role, config, role_schema, global_schema, *, extra_allowed=None) -> list[Finding]` | experimental | Single-role audit. |
| `validate_schema_integrity(schema) -> list[Finding]` | experimental | `required_hook_scripts` cross-check. |
| `extract_role_blocks(md_text, roles) -> dict` | experimental | Pull JSON blocks from a docs projection. |
| `check_worker_settings(schema, base_dir) -> list[Finding]` | experimental | Drift-check `<base_dir>/*/.claude/settings.local.json`. |
| `matches_worker_template(config, template, *, expected_worker_dir=None) -> bool` | experimental | Placeholder-consistent template match. |
| `Finding(source, role, severity, message)` | experimental | Result entry. |
| `ValidationResult(findings)` | experimental | Aggregated result with `.ok`. |

### `core_harness.generator`

| Symbol | Status | Purpose |
|---|---|---|
| `generate_settings(role, worker_dir, framework, org_extension, *, consumer_root=None, extra_placeholders=None) -> dict` | experimental | Top-level entry. |
| `render_role(schema, role, **placeholders) -> dict` | experimental | Render a single `worker_roles` template. |

### Placeholders recognised by the generator

- `{worker_dir}` — absolute path to the worker's worktree.
- `{consumer_root}` — absolute path to the consuming repo (org-neutral
  rename of the legacy `{claude_org_path}`).
- Arbitrary names supplied via `extra_placeholders={...}` for legacy
  alias support (e.g. consumers may pass `{claude_org_path}` pointing
  at the same value as `consumer_root`).

## 1.0 graduation conditions

See [`semver-policy.md`](semver-policy.md). In short:

- ≥ 2 external consumers (real schemas, not forks/stars).
- ≥ 2 consecutive minor releases with no breaking changes.
- All entries above marked `stable`; no remaining `placeholder` /
  `experimental` for items intended for 1.0.

## Conventions used in this document

- **placeholder** — symbol exists for import-time stability; calling it
  raises `NotImplementedError`.
- **experimental** — implemented but signature/semantics may change.
- **stable** — signature is committed; breaking change requires a
  major bump post-1.0, or a deprecation window pre-1.0.
