# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to pre-1.0 semantic versioning as defined in
[`docs/semver-policy.md`](docs/semver-policy.md).

## [Unreleased]

## [0.2.0] - 2026-05-02

### Added

- `core_harness.hooks` (Step C — hook framework, refs ja#128 / design
  PR #196 §4 Step C):
  - `HookRunner` class (`parse_pretooluse_stdin`, `exit_with_block`,
    `exit_ok`) — Python helper for the PreToolUse hook contract.
  - Module-level convenience wrappers `parse_pretooluse_stdin()`,
    `exit_with_block(message)`, `exit_ok()`.
  - Constants `DEFAULT_BLOCK_PREFIX` (`"ブロック: "`, retained for
    legacy consumer-test compatibility), `BLOCK_EXIT_CODE` (= 2),
    `ALLOW_EXIT_CODE` (= 0).
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

- The default block-message prefix `"ブロック: "` exists solely for
  back-compat with the original consumer's hook test suite during the
  0.x transition. New consumers SHOULD set
  `CORE_HARNESS_BLOCK_PREFIX`. The default may be retired no earlier
  than 1.0 with a deprecation window; see `docs/hook-contract.md` §5.
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
