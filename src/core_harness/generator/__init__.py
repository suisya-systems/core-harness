"""Worker ``settings.local.json`` generator (Layer 1 SOT).

Renders a concrete ``settings.local.json`` payload from a worker_roles
template by substituting placeholders such as ``{worker_dir}`` and
``{consumer_root}`` (the org-neutral name; the consumer's previous
``{claude_org_path}`` is supported as an alias).

Public surface (0.1):

* :func:`generate_settings` — top-level entry point.
* :func:`render_role`       — render a worker_roles template against a
  placeholder mapping.

See PR #196 §3.1 / §4 Step B for the placeholder rename rationale.
"""

from __future__ import annotations

from copy import deepcopy
from typing import Any

from core_harness.schema import merge_schemas

# Keys under worker_roles[<role>] that are metadata, not part of the
# emitted settings.local.json content.
_META_KEYS = {"description", "$comment"}


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


def render_role(schema: dict, role: str, **placeholders: str) -> dict:
    """Return the settings dict for ``role`` from ``schema['worker_roles']``.

    ``placeholders`` provides string substitutions; e.g.
    ``render_role(schema, "default", worker_dir="/abs/wd",
    consumer_root="/abs/co")`` replaces every ``{worker_dir}`` /
    ``{consumer_root}`` token.

    Raises :class:`KeyError` for unknown roles or for reserved metadata
    keys (``$comment``).
    """
    roles = schema.get("worker_roles") or {}
    available = sorted(
        k for k, v in roles.items() if not k.startswith("$") and isinstance(v, dict)
    )
    if role not in roles or role.startswith("$") or not isinstance(roles[role], dict):
        raise KeyError(f"unknown worker role: {role!r}. available: {available}")
    template = {k: v for k, v in roles[role].items() if k not in _META_KEYS}
    return _substitute(deepcopy(template), placeholders)


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


__all__ = ["generate_settings", "render_role"]
