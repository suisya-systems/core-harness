# core-harness

Reusable safety primitives for Claude Code orchestrator harnesses (permission schema, hook framework, audit/journal).

> **Status: pre-1.0, API not frozen.** Expect breaking changes between minor versions until 1.0. See [`docs/semver-policy.md`](docs/semver-policy.md).

## Overview

`core-harness` is **Layer 1** of the [claude-org] 4-layer architecture:

```
Layer 4: Org-specific orchestrators (e.g. claude-org-ja)
Layer 3: Org-specific roles & playbooks
Layer 2: Shared role contracts
Layer 1: core-harness         <-- you are here
         (permission schema, hook framework, audit/journal)
```

`core-harness` is **generic**: it does not know about secretaries, dispatchers,
curators, workers, or any specific org. Org-specific concepts live in the
consuming layer (e.g. claude-org-ja). Dependency is one-way: consumers depend
on `core-harness`, never the reverse. See [`docs/canonical-ownership.md`](docs/canonical-ownership.md).

## Install

```bash
pip install git+https://github.com/suisya-systems/core-harness@v0.0.1
```

PyPI publish is deferred until 1.0; until then GitHub Releases / git tags are
the only distribution channel.

## Usage

**Coming in 0.1+.** This 0.0.1 release is a skeleton: importable, but the
public API surface is placeholders. Calling the main entry points
(`validator.validate_schema`, `generator.generate_settings`, ...) raises
`NotImplementedError`.

The intended public surface (subject to change pre-1.0):

- `core_harness.schema` — framework permission/hook schema (Layer 1 SOT for
  things like `forbidden_allow_*`, `required_hook_scripts` type definitions)
- `core_harness.validator` — `validate_schema(...)`
- `core_harness.generator` — `generate_settings(...)`
- `core_harness.hooks` — `HookRunner` protocol (path-configurable; defaults TBD)
- `core_harness.audit` — `Journal` protocol

See [`docs/api-surface-v0.x.md`](docs/api-surface-v0.x.md) for the evolving
contract and 1.0 graduation conditions.

## Versioning

Pre-1.0 semver: minor bumps may include breaking changes. See
[`docs/semver-policy.md`](docs/semver-policy.md) for the deprecation window
and 1.0 graduation criteria.

## Related

- claude-org-ja Issue #128 (extraction tracking)
- Phase 3 design PR (TBD)

## License

MIT — see [`LICENSE`](LICENSE).

[claude-org]: https://github.com/suisya-systems
