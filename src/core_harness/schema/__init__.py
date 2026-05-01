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
from copy import deepcopy
from pathlib import Path
from typing import Any

_FRAMEWORK_SCHEMA_PATH = Path(__file__).resolve().parent / "framework_schema.json"


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


def merge_schemas(
    framework_schema: dict | None,
    org_extension_schema: dict,
) -> dict:
    """Merge a framework schema with an org-extension schema.

    The framework schema is currently a JSON Schema (meta-schema) that
    constrains *shape only*; it does not contribute concrete data
    entries. The merge result is therefore the org-extension dict,
    deep-copied and lightly normalised so downstream code can rely on
    the standard keys being present.

    The signature accepts the framework schema today so that consumers
    pin the API now; in a later 0.x revision the framework may carry
    recommended defaults (e.g. a default ``required_hook_scripts``
    list) that this function would inject, without changing the caller.
    """
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
]
