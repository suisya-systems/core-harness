# Versioning Policy

`core-harness` follows [Semantic Versioning](https://semver.org/), with the
clarifications below for the pre-1.0 phase.

## Pre-1.0 phase (current)

While the major version is `0`:

- **Minor bumps (`0.X.0`) may contain breaking changes.** Consumers should
  pin to at least the minor (`core-harness ~= 0.1`) and read the changelog
  before upgrading.
- **Patch bumps (`0.X.Y`) are additive and bug-fix only.** No breaking changes.
- New API is added freely; experimental surfaces are marked in the docstring
  and in `docs/api-surface-v0.x.md`.

### Deprecation window

Even in pre-1.0 we try to give consumers warning:

- Removing or breaking a previously-shipped public symbol requires one minor
  version of overlap where the old form still works and emits a
  `DeprecationWarning`.
- The old form is removed in the *following* minor (or in 1.0).

### Additive change rule

In a single minor bump, new fields/parameters must be optional with a default
that preserves prior behavior. A change that requires consumers to set a new
value is a breaking change and triggers the deprecation window above.

## 1.0 graduation conditions

We promote to `1.0.0` when **all** of the following hold:

1. At least two independent consumers have run on the same minor for one
   month without a breaking change being needed.
2. Two consecutive minor releases have shipped with no breaking changes.
3. The public surface listed in `docs/api-surface-v0.x.md` is marked stable
   (no `experimental:` entries remaining for the items intended for 1.0).

These are guidelines, not a contract. The maintainers may delay 1.0 if real
usage uncovers a needed breaking change.

## Post-1.0 phase

Standard semver: breaking changes require a major bump; new API is a minor
bump; bug fixes are a patch. Deprecation window extends to one full minor
release with `DeprecationWarning` before removal in the next major.
