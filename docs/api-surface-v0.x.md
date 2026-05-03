# Public API Surface — 0.3.2 (pre-1.0)

> **Status: 0.3.2 published on PyPI.** This document tracks the evolving public
> surface during the pre-1.0 phase. Items below are *experimental*
> unless explicitly marked `stable`; signatures may change between
> minor versions per [`semver-policy.md`](semver-policy.md).

## Modules

| Module | Status (0.3) | Notes |
|---|---|---|
| `core_harness.schema` | experimental | Framework JSON Schema + merge helper. Type-only — concrete role names / consumer regexes live in the org-extension schema (PR #196 §3). |
| `core_harness.validator` | experimental | Audit engine for per-role `settings.local.json`. |
| `core_harness.generator` | experimental | Worker `settings.local.json` template renderer. |
| `core_harness.hooks` | experimental | PreToolUse hook contract (Step C, 0.2). Python helper + bash companion lib + `docs/hook-contract.md`. |
| `core_harness.audit` | experimental | Journal API (Step D, 0.3). Python `Journal` class + bash companion lib + `docs/journal-contract.md`. |

## Public symbols (0.3.2)

### `core_harness.schema`

| Symbol | Status | Purpose |
|---|---|---|
| `load_framework_schema() -> dict` | experimental | Return the framework JSON Schema (deep copy). |
| `framework_schema_path() -> Path` | experimental | On-disk path to the framework JSON file. |
| `merge_schemas(framework: dict \| None, org_extension: dict) -> dict` | experimental | Merge framework defaults with org-extension; result has `global`, `required_hook_scripts`, `roles`, `worker_roles` always present. |
| `SchemaError` | experimental | Raised by `merge_schemas` for malformed schema input. |

### `core_harness.validator`

| Symbol | Status | Purpose |
|---|---|---|
| `validate_settings(settings, framework, org_extension, *, role, ...) -> ValidationResult` | experimental | Top-level entry. |
| `validate_config(source_label, role, config, role_schema, global_schema, *, extra_allowed=None) -> list[Finding]` | experimental | Single-role audit. |
| `validate_schema_integrity(schema) -> list[Finding]` | experimental | `required_hook_scripts` cross-check. |
| `extract_role_blocks(md_text, roles) -> dict` | experimental | Pull JSON blocks from a docs projection. |
| `check_worker_settings(schema, base_dir, *, include_worktrees=True) -> list[Finding]` | experimental | Drift-check `<base_dir>/*/.claude/settings.local.json`. When `include_worktrees=True` (default; introduced 0.3.1), descends one level into `<base_dir>/.worktrees/<branch>/`. |
| `matches_worker_template(config, template, *, expected_worker_dir=None) -> bool` | experimental | Placeholder-consistent template match. |
| `Finding(source, role, severity, message)` | experimental | Result entry. |
| `ValidationResult(findings)` | experimental | Aggregated result with `.ok`. **0.3.1+: `bool(result)` raises `TypeError` to prevent ambiguity — use `result.ok` explicitly.** |

### `core_harness.generator`

| Symbol | Status | Purpose |
|---|---|---|
| `generate_settings(role, worker_dir, framework, org_extension, *, consumer_root=None, extra_placeholders=None) -> dict` | experimental | Top-level entry. |
| `render_role(schema, role, **placeholders) -> dict` | experimental | Render a single `worker_roles` template. |
| `UnresolvedPlaceholderError` | experimental | Raised by `render_role` / `generate_settings` when a `{placeholder}` cannot be substituted. |

### Placeholders recognised by the generator

- `{worker_dir}` — absolute path to the worker's worktree.
- `{consumer_root}` — absolute path to the consuming repo.
- Arbitrary names supplied via `extra_placeholders={...}` for
  consumer-specific alias support (consumers may register additional
  placeholder names that point at the same value as `consumer_root`).

### `core_harness.hooks`

| Symbol | Status | Purpose |
|---|---|---|
| `HookRunner(*, block_prefix=None, stderr=None, stdin=None)` | experimental | Helper for Python-implemented PreToolUse hooks. |
| `HookRunner.parse_pretooluse_stdin() -> Mapping[str, Any]` | experimental | Read + JSON-decode hook payload from stdin. Empty stdin → `{}`; malformed JSON → block. |
| `HookRunner.exit_with_block(message: str)` | experimental | Write `{prefix}{message}` to stderr, exit 2. |
| `HookRunner.exit_ok()` | experimental | Exit 0. |
| `parse_pretooluse_stdin()` | experimental | Module-level convenience for `HookRunner().parse_pretooluse_stdin()`. |
| `exit_with_block(message)` | experimental | Module-level convenience for `HookRunner().exit_with_block(message)`. |
| `exit_ok()` | experimental | Module-level convenience for `HookRunner().exit_ok()`. |
| `lib_path() -> Path` | experimental | On-disk directory of the bash companion library (`core_harness_hooks.sh`). |
| `DEFAULT_BLOCK_PREFIX` | experimental | Default deny-line prefix (`"Blocked: "`, neutral English; consumers override). |
| `BLOCK_EXIT_CODE` | experimental | `2` — deny exit code. |
| `ALLOW_EXIT_CODE` | experimental | `0` — allow exit code. |

#### Bash companion (`core_harness_hooks.sh`)

Sourced via the path returned by `lib_path()`. Public functions:
`block_with_message`, `require_dependency`, `read_pretooluse_command`,
`read_pretooluse_file_path`, `read_pretooluse_tool_name`,
`split_segments`, `flatten_substitutions`, `collect_assignments`,
`expand_known_vars`, `unwrap_eval_and_bashc`. See
[`hook-contract.md`](hook-contract.md) for full spec.

#### Environment variables

- `CORE_HARNESS_BLOCK_PREFIX` — overrides the default `"Blocked: "`
  prefix in both the Python helper and the bash companion. Consumers
  with a locale-specific contract (for example a localized prefix such
  as `"ブロック: "`) export this at their org boundary so Layer 1 stays
  unaware of consumer locale.

### `core_harness.audit`

| Symbol | Status | Purpose |
|---|---|---|
| `Journal(path: Path)` | experimental | Append-only JSON-Lines journal bound to a consumer-supplied path. |
| `Journal.append(event: str, **fields) -> None` | experimental | Append one event line. Adds `ts` (ISO-8601 UTC) automatically; rejects reserved keys (`ts`, `event`) in `fields`. |
| `Journal.iter_events(filter_event=None, since=None) -> Iterator[dict]` | experimental | Stream events; skips blank / malformed / non-object lines with `UserWarning`. |
| `Journal.tail(n: int) -> list[dict]` | experimental | Last `n` valid events, oldest-first. |
| `append_event(path, event, **fields) -> None` | experimental | Module-level convenience for `Journal(path).append(...)`. |
| `iter_events(path, filter_event=None, since=None)` | experimental | Module-level convenience for `Journal(path).iter_events(...)`. |
| `JournalError` | experimental | Base exception. |
| `JournalLockError` | experimental | Raised when exclusive append lock cannot be acquired. |
| `JournalReadError` | experimental | Raised when the journal file cannot be opened for reading. |

#### Bash companion (`audit/lib/journal_append.sh`)

Shipped as package data; consumers locate it via Python introspection:
`Path(core_harness.audit.__file__).parent / "lib" / "journal_append.sh"`.
Public functions: `journal_append <path> <event> [k=v ...]`,
`journal_append_raw <path>` (stdin-driven). See
[`journal-contract.md`](journal-contract.md) for the full spec.

#### Concurrency

`Journal.append` holds an exclusive file lock (`fcntl.flock` on POSIX,
`msvcrt.locking` on Windows) plus an in-process mutex keyed by the
resolved absolute path; concurrent appends from threads / processes
are serialized. The bash helper uses `flock(1)` when available.

## 1.0 graduation conditions

See [`semver-policy.md`](semver-policy.md). In short:

- ≥ 2 external consumers (real schemas, not forks/stars).
- ≥ 2 consecutive minor releases with no breaking changes.
- All entries above marked `stable`; no remaining `placeholder` /
  `experimental` for items intended for 1.0.

### 1.0 transition gates — current state

- **CI matrix**: landed (`.github/workflows/tests.yml`) — pytest on
  Linux / macOS / Windows × Python 3.10–3.12, plus bash hook + audit
  tests on Linux / macOS.
- **PyPI publishing pipeline**: live (`.github/workflows/release.yml`,
  OIDC / Trusted Publisher). v0.3.2 is the first release shipped via
  this pipeline; subsequent `v*` tag pushes publish automatically.
- **Doc-comment neutralisation**: complete — Layer-1 source docstrings,
  the bash hook library comment, and the canonical / hook / surface
  contract docs no longer name a specific consuming repo or specific
  role names. Architecture / "Related" links in `README.md` are kept
  as deliberate project-history context.
- **External-consumer count / consecutive-minor count**: still
  pre-1.0 as of v0.3.2; tracked in `semver-policy.md`.

## Conventions used in this document

- **placeholder** — symbol exists for import-time stability; calling it
  raises `NotImplementedError`.
- **experimental** — implemented but signature/semantics may change.
- **stable** — signature is committed; breaking change requires a
  major bump post-1.0, or a deprecation window pre-1.0.
