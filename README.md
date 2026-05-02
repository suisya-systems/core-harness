# core-harness

[![tests](https://github.com/suisya-systems/core-harness/actions/workflows/tests.yml/badge.svg)](https://github.com/suisya-systems/core-harness/actions/workflows/tests.yml)
[![PyPI](https://img.shields.io/pypi/v/core-harness.svg)](https://pypi.org/project/core-harness/)

Reusable safety primitives for Claude Code orchestrator harnesses (permission schema, hook framework, audit/journal).

> **Status: pre-1.0, API not frozen.** Latest release: **v0.3.2** (published on PyPI). Expect breaking changes between minor versions until 1.0. See [`docs/semver-policy.md`](docs/semver-policy.md).

> **Not an AI agent framework.** `core-harness` provides Claude Code-specific
> governance primitives (permission schema, hook framework, audit/journal). It
> does not implement agent runtime abstractions such as `agent` / `tool` /
> `run` / `state` / `handoff` / `memory` / `trace` — those concerns belong in
> higher layers (e.g. consumer harnesses like `claude-org-ja`) or in dedicated
> agent frameworks (LangChain, AutoGen, CrewAI, OpenAI Agents SDK).

## Overview

`core-harness` is **Layer 1** of the [claude-org] 4-layer architecture:

```
Layer 4: Org-specific orchestrators (e.g. claude-org-ja)
Layer 3: Org-specific roles & playbooks
Layer 2: Shared role contracts
Layer 1: core-harness         <-- you are here
         (permission schema, hook framework, audit/journal)
```

`core-harness` is **generic and consumer-agnostic**: it does not know about
secretaries, dispatchers, curators, workers, or any specific org. It does not
import, reference, or special-case `claude-org` or `claude-org-ja`. Dependency
is strictly one-way — consumers depend on `core-harness`, never the reverse.
This Q4 (Layer 1 purity) invariant is enforced by the test suite. See
[`docs/canonical-ownership.md`](docs/canonical-ownership.md).

`claude-org-ja` is the **first consumer** and drove much of the initial design,
but the public surface is intended for any team building a Claude Code
orchestrator harness who wants to reuse the permission schema, hook framework,
or audit journal rather than rebuild them.

## Install

```bash
pip install core-harness
```

`core-harness` is published on PyPI:
[pypi.org/project/core-harness/](https://pypi.org/project/core-harness/).
v0.3.2 is the first release shipped via the PyPI Trusted Publisher (OIDC)
workflow. To pin a specific version:

```bash
pip install core-harness==0.3.2
```

Installation directly from a git tag is also supported as a fallback:

```bash
pip install git+https://github.com/suisya-systems/core-harness@v0.3.2
```

## Usage

The shipped public surface in v0.3.2:

### `core_harness.schema`

Loads the framework JSON Schema (permission rules, required hook scripts,
forbidden-allow patterns) and merges it with consumer-supplied org extensions.

```python
from core_harness.schema import load_framework_schema, merge_schemas

framework = load_framework_schema()
merged = merge_schemas(framework, org_extension)
```

Exports: `load_framework_schema`, `framework_schema_path`, `merge_schemas`,
`SchemaError`.

### `core_harness.validator`

Fail-closed validation for `settings.local.json` (and `settings.json`) against
the framework schema plus an optional org extension. Returns structured
`Finding`s and a `ValidationResult`.

```python
from core_harness.validator import validate_settings, check_worker_settings

result = validate_settings(settings_path, schema=merged)
if not result.ok:
    for f in result.findings:
        print(f.code, f.path, f.message)

check_worker_settings(worker_dir, schema=merged, include_worktrees=False)
```

Exports: `validate_settings`, `validate_config`, `validate_schema_integrity`,
`extract_role_blocks`, `check_worker_settings` (kw-only `include_worktrees`),
`matches_worker_template`, `Finding`, `ValidationResult`.

### `core_harness.generator`

Renders a role template into a worker directory, substituting consumer-
supplied placeholders. Detects unresolved placeholders rather than letting
them leak into generated config.

```python
from core_harness.generator import generate_settings, UnresolvedPlaceholderError

generate_settings(role="worker", target_dir=worker_dir, context={...})
```

Exports: `generate_settings`, `render_role`, `UnresolvedPlaceholderError`.

### `core_harness.hooks`

Standard contract for Claude Code `PreToolUse` hooks: a Python `HookRunner`
plus a parallel bash library accessible via `lib_path()` for shell-based
hooks. Block messages are locale-neutral by default (English `"Blocked: "`)
and overridable via the `CORE_HARNESS_BLOCK_PREFIX` environment variable.

```python
from core_harness.hooks import HookRunner, parse_pretooluse_stdin, exit_with_block, lib_path

event = parse_pretooluse_stdin()
runner = HookRunner(rules=[...])
decision = runner.evaluate(event)
if decision.block:
    exit_with_block(decision.reason)
```

```bash
# bash hooks source the shipped library
. "$(python -c 'from core_harness.hooks import lib_path; print(lib_path())')"
```

Exports: `HookRunner`, `parse_pretooluse_stdin`, `exit_with_block`, `exit_ok`,
`lib_path`.

### `core_harness.audit`

Per-pane append-only `Journal` for orchestrator audit events. The journal
path is **consumer-injected** (core-harness does not pick a default location)
and writes are concurrency-safe via file locking. A parallel bash helper is
exposed via `lib_path()`.

```python
from core_harness.audit import Journal, append_event, iter_events

journal = Journal(path=consumer_chosen_path)
append_event(journal, event_type="dispatch", payload={...})
for ev in iter_events(journal):
    ...
```

Exports: `Journal`, `append_event`, `iter_events`, `lib_path`, `JournalError`,
`JournalLockError`, `JournalReadError`.

See [`docs/api-surface-v0.x.md`](docs/api-surface-v0.x.md) for the full
evolving contract.

## Versioning

Pre-1.0 semver (see [`docs/semver-policy.md`](docs/semver-policy.md)):

- Minor bumps (`0.X.0`) may include breaking changes.
- Patch bumps (`0.X.Y`) are additive and bug-fix only.
- Removing or breaking a previously-shipped public symbol requires one minor
  version of overlap with a `DeprecationWarning` before removal.

**1.0 graduation** requires all of:

1. At least two independent consumers running on the same minor for one
   month without needing a breaking change.
2. Two consecutive minor releases shipped with no breaking changes.
3. The public surface in `docs/api-surface-v0.x.md` marked stable (no
   remaining `experimental:` entries for items intended for 1.0).

## Releasing

Releases are tag-driven. Pushing a tag matching `v*` triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml),
which:

1. Builds an sdist and a wheel via `python -m build`.
2. Publishes the artefacts to PyPI through a
   [Trusted Publisher](https://docs.pypi.org/trusted-publishers/)
   (OIDC — no API token is stored in the repo).
3. Creates / updates a GitHub Release with the same tag and attaches
   the built artefacts.

Cutting a release:

```bash
# 1. Bump version in pyproject.toml and update CHANGELOG.md.
# 2. Land both via PR.
git tag -s vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

**Trusted Publisher setup (one-time).** The Trusted Publisher entry on
[pypi.org/manage/project/core-harness/settings/publishing/](https://pypi.org/manage/project/core-harness/settings/publishing/)
is registered as:

- Owner: `suisya-systems`
- Repository: `core-harness`
- Workflow: `release.yml`
- Environment: `pypi`

v0.3.2 was the first release shipped through this pipeline. New tag
pushes publish to PyPI automatically.

If Trusted Publisher is ever undesired, the workflow has an API-token
fallback commented out — uncomment it, drop the `id-token: write`
permission, and add `PYPI_API_TOKEN` to repo secrets.

## Related

- [v0.3.2 release notes](https://github.com/suisya-systems/core-harness/releases/tag/v0.3.2) — first PyPI publish via Trusted Publisher
- [v0.3.1 release notes](https://github.com/suisya-systems/core-harness/releases/tag/v0.3.1)
- claude-org-ja Issue [#128](https://github.com/suisya-systems/claude-org-ja/issues/128) (closed) — extraction tracking
- claude-org-ja PR [#196](https://github.com/suisya-systems/claude-org-ja/pull/196) — extraction design
- claude-org-ja shim PRs:
  [#197](https://github.com/suisya-systems/claude-org-ja/pull/197) (Step B),
  [#198](https://github.com/suisya-systems/claude-org-ja/pull/198) (Step C),
  [#199](https://github.com/suisya-systems/claude-org-ja/pull/199) (Step D),
  [#201](https://github.com/suisya-systems/claude-org-ja/pull/201) (0.3.1 follow-up)

## License

MIT — see [`LICENSE`](LICENSE).

[claude-org]: https://github.com/suisya-systems
