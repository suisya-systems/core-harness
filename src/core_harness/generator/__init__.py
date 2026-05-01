"""Worker ``settings.local.json`` generator (Layer 1 SOT).

Renders a concrete ``settings.local.json`` payload from a worker_roles
template by substituting placeholders such as ``{worker_dir}`` and
``{consumer_root}`` (the org-neutral name; the consumer's previous
``{claude_org_path}`` is supported as an alias).

Public surface (0.1):

* :func:`generate_settings`         — top-level entry point.
* :func:`render_role`               — render a worker_roles template
  against a placeholder mapping.
* :exc:`UnresolvedPlaceholderError` — raised when output still
  contains ``{name}`` placeholders.

See PR #196 §3.1 / §4 Step B for the placeholder rename rationale.
"""

from __future__ import annotations

import re
from copy import deepcopy
from typing import Any

from core_harness.schema import merge_schemas

# Keys under worker_roles[<role>] that are metadata, not part of the
# emitted settings.local.json content.
_META_KEYS = {"description", "$comment"}

# Anything that looks like a placeholder token: ``{name}`` with an
# identifier-shaped name. Used as a fail-closed gate so an unsubstituted
# ``{consumer_root}`` cannot silently slip into a generated settings file
# (which would render hook command paths inert and bypass Layer 1
# enforcement).
_PLACEHOLDER_TOKEN = re.compile(r"\{[a-zA-Z_][a-zA-Z0-9_]*\}")


class UnresolvedPlaceholderError(ValueError):
    """Raised when generator output still contains ``{name}`` placeholders.

    Layer 1 must fail closed on unsubstituted placeholders: an unresolved
    ``{consumer_root}`` in a hook command silently disables the hook
    rather than producing a useful error at runtime.
    """


def _substitute(value: Any, mapping: dict) -> Any:
    if isinstance(value, str):
        out = value
        for placeholder, replacement in mapping.items():
            out = out.replace("{" + placeholder + "}", replacement)
        return out
    if isinstance(value, list):
        return [_substitute(v, mapping) for v in value]
    if isinstance(value, dict):
        return {k: _substitute(v, mapping) for k, v in value.items()}
    return value


def _collect_unresolved(value: Any, path: str = "$") -> list:
    """Walk ``value`` and return ``(path, token)`` for every leftover
    ``{name}`` placeholder."""
    out: list = []
    if isinstance(value, str):
        for m in _PLACEHOLDER_TOKEN.finditer(value):
            out.append((path, m.group(0)))
    elif isinstance(value, list):
        for i, v in enumerate(value):
            out.extend(_collect_unresolved(v, f"{path}[{i}]"))
    elif isinstance(value, dict):
        for k, v in value.items():
            out.extend(_collect_unresolved(v, f"{path}.{k}"))
    return out


def render_role(schema: dict, role: str, **placeholders: str) -> dict:
    """Return the settings dict for ``role`` from ``schema['worker_roles']``.

    ``placeholders`` provides string substitutions; e.g.
    ``render_role(schema, "default", worker_dir="/abs/wd",
    consumer_root="/abs/co")`` replaces every ``{worker_dir}`` /
    ``{consumer_root}`` token.

    Raises :class:`KeyError` for unknown / reserved roles, and
    :class:`UnresolvedPlaceholderError` when the rendered output still
    contains ``{name}`` placeholders (fail closed — Layer 1 does not
    emit half-substituted hook commands).
    """
    roles = schema.get("worker_roles") or {}
    available = sorted(
        k for k, v in roles.items() if not k.startswith("$") and isinstance(v, dict)
    )
    if role not in roles or role.startswith("$") or not isinstance(roles[role], dict):
        raise KeyError(f"unknown worker role: {role!r}. available: {available}")
    template = {k: v for k, v in roles[role].items() if k not in _META_KEYS}
    rendered = _substitute(deepcopy(template), placeholders)
    leftovers = _collect_unresolved(rendered)
    if leftovers:
        joined = ", ".join(f"{path}={tok}" for path, tok in leftovers[:5])
        raise UnresolvedPlaceholderError(
            f"unresolved placeholders in worker_roles[{role!r}]: {joined}"
            + (" ..." if len(leftovers) > 5 else "")
            + ". Pass them via the placeholders/extra_placeholders argument."
        )
    return rendered


def generate_settings(
    role: str,
    worker_dir: str,
    framework_schema: dict | None,
    org_extension_schema: dict,
    *,
    consumer_root: str | None = None,
    extra_placeholders: dict | None = None,
) -> dict:
    """Top-level generator entry point.

    Merges ``framework_schema`` with ``org_extension_schema``, locates
    ``worker_roles[role]`` in the merged dict, and renders it with
    ``{worker_dir}`` / ``{consumer_root}`` substituted. ``extra_placeholders``
    lets the caller supply additional org-specific aliases (e.g.
    ``{claude_org_path}``) that point at the same value as
    ``consumer_root``.
    """
    merged = merge_schemas(framework_schema, org_extension_schema)
    placeholders: dict = {"worker_dir": worker_dir}
    if consumer_root is not None:
        placeholders["consumer_root"] = consumer_root
    if extra_placeholders:
        placeholders.update(extra_placeholders)
    return render_role(merged, role, **placeholders)


__all__ = ["generate_settings", "render_role", "UnresolvedPlaceholderError"]
