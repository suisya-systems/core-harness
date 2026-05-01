"""Framework schema (Layer 1 SOT).

Hosts the generic type definitions (as a JSON Schema) for the per-role
permission/hook configuration. Concrete entries — role names, named
required_allow lists, ban regexes, ``workers_dir`` conventions, named
worker_role templates — are NOT defined here. They live in the
consumer's *org_extension_schema*.

Public surface (0.1):

* :func:`load_framework_schema` — return the framework JSON Schema dict.
* :func:`framework_schema_path` — locate the on-disk JSON file.
* :func:`merge_schemas`         — combine framework + org-extension into a
  single dict the validator/generator can consume.

See PR #196 §3 for the framework / org-extension split, and
``framework_schema.json`` for the structural contract.
"""

from __future__ import annotations

import json
import re
from copy import deepcopy
from pathlib import Path
from typing import Any

_FRAMEWORK_SCHEMA_PATH = Path(__file__).resolve().parent / "framework_schema.json"


class SchemaError(ValueError):
    """Raised when an org-extension schema violates the framework's
    structural contract.

    Layer 1 fails closed: a typo in ``forbidden_allow_regex`` or a
    misshapen ``roles`` entry must surface as an error rather than
    silently degrading to an empty audit constraint set.
    """


def load_framework_schema() -> dict:
    """Return the framework JSON Schema as a dict.

    The returned dict is a fresh deep copy; mutating it does not affect
    the package-level resource.
    """
    with _FRAMEWORK_SCHEMA_PATH.open(encoding="utf-8") as fh:
        return json.load(fh)


def framework_schema_path() -> Path:
    """Return the on-disk path to the framework schema JSON file."""
    return _FRAMEWORK_SCHEMA_PATH


def _require_list_of_str(value: Any, dotted_path: str) -> None:
    if not isinstance(value, list):
        raise SchemaError(f"{dotted_path} must be a list, got {type(value).__name__}")
    for i, entry in enumerate(value):
        if not isinstance(entry, str):
            raise SchemaError(
                f"{dotted_path}[{i}] must be a string, got {type(entry).__name__}"
            )


def _validate_extension_structure(ext: dict) -> None:
    """Fail-closed structural check of an org-extension schema.

    This is *not* a full JSON Schema validator (we deliberately avoid
    a runtime ``jsonschema`` dependency in pre-1.0). It does enforce
    the contract points whose silent failure would weaken Layer 1
    audit guarantees: list-of-string types under ``global``,
    ``required_hook_scripts``, and the per-role string-list fields.
    """
    if not isinstance(ext, dict):
        raise SchemaError(f"org_extension_schema must be a dict, got {type(ext).__name__}")

    g = ext.get("global")
    if g is not None:
        if not isinstance(g, dict):
            raise SchemaError(f"global must be a dict, got {type(g).__name__}")
        for key in ("forbidden_allow_exact", "forbidden_allow_regex"):
            if key in g:
                _require_list_of_str(g[key], f"global.{key}")
        for pat in g.get("forbidden_allow_regex", []):
            try:
                re.compile(pat)
            except re.error as exc:
                raise SchemaError(
                    f"global.forbidden_allow_regex contains invalid regex {pat!r}: {exc}"
                ) from exc

    if "required_hook_scripts" in ext:
        _require_list_of_str(ext["required_hook_scripts"], "required_hook_scripts")

    roles = ext.get("roles")
    if roles is not None:
        if not isinstance(roles, dict):
            raise SchemaError(f"roles must be a dict, got {type(roles).__name__}")
        for role_name, role in roles.items():
            if not isinstance(role, dict):
                raise SchemaError(
                    f"roles[{role_name!r}] must be a dict, got {type(role).__name__}"
                )
            for key in (
                "required_allow",
                "allowed_allow_regex",
                "required_deny",
                "disallow_allow_regex",
                "settings_paths",
            ):
                if key in role:
                    _require_list_of_str(role[key], f"roles[{role_name!r}].{key}")
            for key in ("allowed_allow_regex", "disallow_allow_regex"):
                for pat in role.get(key, []):
                    try:
                        re.compile(pat)
                    except re.error as exc:
                        raise SchemaError(
                            f"roles[{role_name!r}].{key} invalid regex {pat!r}: {exc}"
                        ) from exc
            req_hooks = role.get("required_hooks", [])
            if not isinstance(req_hooks, list):
                raise SchemaError(
                    f"roles[{role_name!r}].required_hooks must be a list"
                )
            for i, hook in enumerate(req_hooks):
                if not isinstance(hook, dict):
                    raise SchemaError(
                        f"roles[{role_name!r}].required_hooks[{i}] must be a dict"
                    )
                if "event" not in hook or not isinstance(hook["event"], str):
                    raise SchemaError(
                        f"roles[{role_name!r}].required_hooks[{i}].event must be a string"
                    )
            cw = role.get("closed_world")
            if cw is not None and not isinstance(cw, bool):
                raise SchemaError(
                    f"roles[{role_name!r}].closed_world must be a bool"
                )

    wr = ext.get("worker_roles")
    if wr is not None and not isinstance(wr, dict):
        raise SchemaError(f"worker_roles must be a dict, got {type(wr).__name__}")


def merge_schemas(
    framework_schema: dict | None,
    org_extension_schema: dict,
    *,
    validate: bool = True,
) -> dict:
    """Merge a framework schema with an org-extension schema.

    The framework schema is currently a JSON Schema (meta-schema) that
    constrains *shape only*; it does not contribute concrete data
    entries. The merge result is therefore the org-extension dict,
    deep-copied and lightly normalised so downstream code can rely on
    the standard keys being present.

    Before normalisation, the org-extension is validated against the
    framework's structural contract (see :func:`_validate_extension_structure`).
    Pass ``validate=False`` to skip this check; defaults to True so a
    typo in ``forbidden_allow_regex`` cannot silently disappear from
    the merged schema. Raises :class:`SchemaError` on violation.
    """
    if validate:
        _validate_extension_structure(org_extension_schema)
    merged: dict[str, Any] = deepcopy(org_extension_schema)
    g = merged.setdefault("global", {})
    g.setdefault("forbidden_allow_exact", [])
    g.setdefault("forbidden_allow_regex", [])
    merged.setdefault("required_hook_scripts", [])
    merged.setdefault("roles", {})
    merged.setdefault("worker_roles", {})
    return merged


__all__ = [
    "load_framework_schema",
    "framework_schema_path",
    "merge_schemas",
    "SchemaError",
]
