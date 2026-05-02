# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to pre-1.0 semantic versioning as defined in
[`docs/semver-policy.md`](docs/semver-policy.md).

## [Unreleased]

Internal — 1.0 transition prep (no public API changes).

### Added

- `.github/workflows/tests.yml` — CI matrix running pytest on
  `{ubuntu-latest, macos-latest, windows-latest}` × `{3.10, 3.11, 3.12}`,
  plus a separate job that runs `tests/test_hooks_bash.sh` and
  `tests/test_audit_bash.sh` on Linux and macOS.
- `.github/workflows/release.yml` — skeleton release pipeline. On
  `v*` tag push: build sdist + wheel, publish to PyPI via
  Trusted Publisher (OIDC, no token needed), and attach the artefacts
  to a GitHub Release. The Trusted Publisher entry on PyPI is a
  one-time manual setup; an API-token alternative is left commented in
  the workflow for fallback.
- `README.md` — new "Releasing" section documenting the tag-driven
  flow and the PyPI Trusted Publisher prerequisite. Tests CI badge
  added at the top.

### Changed (internal — doc-comment neutralisation)

- Removed lingering `claude-org-ja` / role-name references (`secretary`,
  `dispatcher`, `curator`) from Layer-1 source docstrings, the bash
  hook library comment, `docs/api-surface-v0.x.md`,
  `docs/canonical-ownership.md`, and `docs/hook-contract.md`. Examples
  that previously named a specific consumer now use generic
  "consumer harness" / locale-illustration phrasing. No public API,
  config key, or shipped string changed.

## [0.3.1] - 2026-05-02

Patch release — Q4 purity finalization, security hardening, and API
clarification, driven by the phase3 cross-review (refs ja#128).

### Changed (potentially breaking — pre-1.0 minor)

- `validator.ValidationResult.__bool__` now raises `TypeError`. The
  prior implicit truthiness check (`if result: ...`) was ambiguous —
  callers split between "no errors" and "has any findings". Use
  `result.ok` (no `ERROR`-severity findings) explicitly. The bound
  `bool(result.findings)` keeps working for "has any findings" callers.
- `validator.check_worker_settings(schema, base_dir)` gained a
  keyword-only `include_worktrees: bool = True` parameter. Default
  `True` causes one extra level of descent into
  `<base_dir>/.worktrees/<branch>/.claude/settings.local.json`, so
  worker checkouts living under a `.worktrees/` parent are now audited.
  Pass `include_worktrees=False` to restore the 0.3.0 behaviour.

### Security

- `audit/lib/journal_append.sh`: when `flock(1)` is missing, the
  fallback branch now emits a one-line stderr warning so callers learn
  their concurrent appends are unprotected. Recommended fix is to use
  the Python API (`Journal.append`) which uses `fcntl.flock` /
  `msvcrt.locking` directly.

### Fixed (Q4 purity)

- `hooks.HookRunner.parse_pretooluse_stdin` block messages were
  hardcoded Japanese; now neutral English ("Failed to parse PreToolUse
  JSON: …" / "PreToolUse payload is not a JSON object"). Consumers with
  a localized contract still inject prefix/locale via
  `CORE_HARNESS_BLOCK_PREFIX` or `HookRunner(block_prefix=...)`.
- `hooks/lib/core_harness_hooks.sh` `require_dependency` and the
  internal `_jq` check messages were hardcoded Japanese; now neutral
  English.
- `core_harness/__init__.py` top docstring no longer references the
  original consumer ("claude-org") by name.

### Added

- `core_harness.SchemaError` and `core_harness.UnresolvedPlaceholderError`
  re-exported at package root and listed in
  `docs/api-surface-v0.x.md` (they were already public via their
  submodules; this just makes the surface document match reality).

### Docs

- `docs/api-surface-v0.x.md`: heading bumped to 0.3.1; `pip show`
  reference removed in favour of the Python introspection recipe;
  `validate_config` argument renamed to `source_label` to match the
  implementation.

## [0.3.0] - 2026-05-02

### Added

- `core_harness.audit` (Step D — journal API, refs ja#128 / design
  PR #196 §4 Step D):
  - `Journal` class — append-only JSON-Lines journal with
    consumer-supplied path. Public methods `append(event, **fields)`,
    `iter_events(filter_event=None, since=None)`, `tail(n)`.
  - Module-level convenience wrappers `append_event(path, event,
    **fields)` and `iter_events(path, filter_event, since)`.
  - Exception hierarchy: `JournalError` (parent), `JournalLockError`,
    `JournalReadError`.
  - Concurrent-write safety: `fcntl.flock(LOCK_EX)` on POSIX,
    `msvcrt.locking()` on Windows, plus an in-process mutex keyed by
    absolute path so multi-threaded appenders inside one interpreter
    are also serialized.
  - Reader tolerance: blank lines, broken JSON, and non-object lines
    are skipped with a `UserWarning` (matches the de-facto contract
    documented in inventory §4).
- `core_harness/audit/lib/journal_append.sh` — bash companion library
  with `journal_append <path> <event> [k=v ...]` and
  `journal_append_raw <path>` (stdin-driven). Uses `jq` for safe JSON
  encoding, takes `flock(1)` when available.
- `docs/journal-contract.md` — wire-format / concurrency / reader
  tolerance specification.
- `tests/test_audit.py`, `tests/test_audit_bash.sh` — generic-only
  framework tests (no consumer-org event names).

### Changed

- `core_harness.audit` graduated from placeholder to experimental.
- `pyproject.toml`: bumped to 0.3.0; `core_harness.audit` now ships
  `lib/*.sh` as package data alongside `core_harness.hooks`.

### Notes

- The journal file path is **consumer-injected** (Q4 one-way
  dependency rule). Layer 1 never reads consumer-shaped env vars to
  discover it; the consumer instantiates `Journal(Path(...))` or
  passes the path explicitly to `append_event`.
- The event-type catalog (e.g. `worker_spawned`, `pr_merged`, …) and
  per-event field conventions remain in the consumer repo. Layer 1
  owns the *how* (envelope, locking, reader tolerance), not the
  *what*.

## [0.2.0] - 2026-05-02

### Added

- `core_harness.hooks` (Step C — hook framework, refs ja#128 / design
  PR #196 §4 Step C):
  - `HookRunner` class (`parse_pretooluse_stdin`, `exit_with_block`,
    `exit_ok`) — Python helper for the PreToolUse hook contract.
  - Module-level convenience wrappers `parse_pretooluse_stdin()`,
    `exit_with_block(message)`, `exit_ok()`.
  - Constants `DEFAULT_BLOCK_PREFIX` (`"Blocked: "`, neutral English —
    Layer 1 ships no consumer-specific locale; consumers override),
    `BLOCK_EXIT_CODE` (= 2), `ALLOW_EXIT_CODE` (= 0).
  - `lib_path()` returning the on-disk directory of the bash companion
    library (path-configurable; consumers source it from there).
  - `CORE_HARNESS_BLOCK_PREFIX` env var + `block_prefix=` constructor
    argument so non-Japanese consumers can override the deny-line
    prefix without forking.
- `core_harness/hooks/lib/core_harness_hooks.sh` — bash companion
  library with `block_with_message`, `require_dependency`,
  `read_pretooluse_{command,file_path,tool_name}`, and the generic
  command-string parsers (`split_segments`, `flatten_substitutions`,
  `collect_assignments`, `expand_known_vars`, `unwrap_eval_and_bashc`)
  formerly duplicated in the original consumer's
  `.hooks/lib/segment-split.sh`.
- `docs/hook-contract.md` — contract specification (stdin JSON shape,
  exit code semantics, stderr block-prefix format, helper APIs).
- `tests/test_hooks.py`, `tests/test_hooks_bash.sh` — generic-only
  framework tests (no consumer-org strings).

### Changed

- `core_harness.hooks` graduated from placeholder to experimental.
- `pyproject.toml`: `core_harness.hooks` now ships `lib/*.sh` as
  package data so `lib_path()` resolves through `pip install` and
  `git+https://...@vX` installs alike.

### Notes

- The default block-message prefix is the neutral English
  `"Blocked: "`. Layer 1 deliberately does not bake any consumer
  locale into the framework default (Q4 one-way dependency). The
  original consumer (claude-org-ja) injects its legacy
  `"ブロック: "` contract at the org boundary via
  `CORE_HARNESS_BLOCK_PREFIX` / `HookRunner(block_prefix=...)`. See
  `docs/hook-contract.md` §5.
- Hook *script bodies* (block-no-verify, block-dangerous-git, etc.)
  remain in the consumer repo for this release; only the wiring
  framework / contract / generic parser library moves up. Movement of
  generic hook scripts may follow in a later 0.x once the contract has
  bedded in.
- `core_harness.audit` remains a placeholder; Step D in a subsequent
  0.x release.

## [0.1.0] - 2026-05-02

### Added

- `core_harness.schema`:
  - `framework_schema.json` — Layer 1 SOT JSON Schema for the per-role
    permission/hook configuration. Type-only: no role names, no
    consumer-specific patterns.
  - `load_framework_schema()`, `framework_schema_path()`,
    `merge_schemas(framework, org_extension)`.
- `core_harness.validator`:
  - `validate_settings(settings, framework, org_extension, *, role)` —
    top-level entry returning a `ValidationResult`.
  - Lower-level engine: `validate_config`, `validate_schema_integrity`,
    `extract_role_blocks`, `check_worker_settings`,
    `matches_worker_template`.
  - Result types: `Finding`, `ValidationResult`.
- `core_harness.generator`:
  - `generate_settings(role, worker_dir, framework, org_extension, *,
    consumer_root=None, extra_placeholders=None)` — top-level entry.
  - `render_role(schema, role, **placeholders)` — direct template
    renderer with org-neutral placeholder support.
- Test suites: `tests/test_validator.py`, `tests/test_generator.py`
  (synthetic fixtures only — no consumer-org strings).

### Changed

- Promoted Development Status classifier from `2 - Pre-Alpha` to
  `3 - Alpha`.
- `core_harness.validator.validate_schema` placeholder removed in
  favour of `validate_settings` (real implementation).
- `core_harness.generator.generate_settings` placeholder replaced with
  the real implementation; signature is the new public surface.

### Notes

- Placeholders are now neutral: `{worker_dir}`, `{consumer_root}`, and
  any caller-supplied alias via `extra_placeholders`. Consumers that
  used `{claude_org_path}` keep working by passing it as an
  `extra_placeholders` alias of `consumer_root`.
- `core_harness.hooks` and `core_harness.audit` remain placeholders;
  Step C / Step D land in subsequent 0.x releases.

## [0.0.1] - 2026-05-02

### Added

- Initial repository skeleton.
- `pyproject.toml` (PEP 621), MIT license, Python >= 3.8.
- `src/core_harness/` package layout with placeholder modules: `schema`,
  `validator`, `generator`, `hooks`, `audit`. Public entry points raise
  `NotImplementedError`; the package is importable.
- Documentation placeholders:
  - `docs/api-surface-v0.x.md` — evolving public surface contract.
  - `docs/semver-policy.md` — pre-1.0 rules, deprecation window, 1.0 criteria.
  - `docs/canonical-ownership.md` — one-way dependency policy (Layer 1 does
    not know about consuming layers).
