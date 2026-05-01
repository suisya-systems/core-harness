# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to pre-1.0 semantic versioning as defined in
[`docs/semver-policy.md`](docs/semver-policy.md).

## [Unreleased]

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
