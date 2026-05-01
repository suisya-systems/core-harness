"""Schema validator (Layer 1 SOT).

Generic engine for auditing a per-role ``settings.local.json`` payload
against a merged framework + org-extension schema. The validator owns
the *algorithm* (closed-world check, forbidden-allow match, hook-script
integrity, placeholder-aware worker_role template match). The
*concrete entries* — role names, named required_allow lists, ban
regexes — are supplied by the caller via the org-extension schema.
See PR #196 §3 / §6.2.

Public surface (0.1):

* :func:`validate_settings`        — top-level entry point.
* :func:`validate_config`          — single role/config validation.
* :func:`validate_schema_integrity`— required_hook_scripts cross-check.
* :func:`extract_role_blocks`      — pull JSON code blocks from a docs
  projection markdown.
* :func:`check_worker_settings`    — drift-check
  ``<base>/*/.claude/settings.local.json`` against worker_roles.
* :class:`Finding`                 — structured result entry.
* :class:`ValidationResult`        — list[Finding] + ``ok`` summary.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Iterator

from core_harness.schema import merge_schemas


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------


@dataclass
class Finding:
    """A single validator finding (error or warning)."""

    source: str
    role: str
    severity: str
    message: str

    def format(self) -> str:
        return f"[{self.severity}] {self.source} :: {self.role} :: {self.message}"


@dataclass
class ValidationResult:
    """Aggregated validator output."""

    findings: list = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not any(f.severity == "ERROR" for f in self.findings)

    def __bool__(self) -> bool:
        return self.ok

    def __iter__(self) -> Iterator:
        return iter(self.findings)

    def __len__(self) -> int:
        return len(self.findings)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_allow(config: dict) -> list:
    return ((config.get("permissions") or {}).get("allow")) or []


def _get_deny(config: dict) -> list:
    return ((config.get("permissions") or {}).get("deny")) or []


def _iter_hooks(config: dict) -> Iterable:
    hooks = config.get("hooks") or {}
    for event, entries in hooks.items():
        for entry in entries or []:
            matcher = entry.get("matcher", "") or ""
            for sub in entry.get("hooks") or []:
                cmd = sub.get("command", "") or ""
                yield event, matcher, cmd


# ---------------------------------------------------------------------------
# Per-role validation
# ---------------------------------------------------------------------------


def validate_config(
    source_label: str,
    role_name: str,
    config: dict | None,
    role_schema: dict,
    global_schema: dict,
    *,
    extra_allowed: set | None = None,
) -> list:
    """Validate a single role's ``config`` dict against ``role_schema``.

    ``global_schema`` is the merged schema's ``global`` block (carrying
    ``forbidden_allow_exact`` / ``forbidden_allow_regex``).
    ``extra_allowed`` is the optional override-allow set drawn from a
    sibling ``settings.local.override.json`` (closed-world escape
    hatch).
    """
    findings: list = []
    if config is None:
        findings.append(Finding(source_label, role_name, "ERROR", "config block missing"))
        return findings
    if "__parse_error__" in config:
        findings.append(
            Finding(
                source_label,
                role_name,
                "ERROR",
                f"JSON parse error: {config['__parse_error__']}",
            )
        )
        return findings

    allow = _get_allow(config)
    deny = _get_deny(config)

    for entry in allow:
        if entry in global_schema.get("forbidden_allow_exact", []):
            findings.append(
                Finding(source_label, role_name, "ERROR", f"forbidden wide allow entry: {entry!r}")
            )
    for pattern in global_schema.get("forbidden_allow_regex", []):
        rgx = re.compile(pattern)
        for entry in allow:
            if rgx.search(entry):
                findings.append(
                    Finding(
                        source_label,
                        role_name,
                        "ERROR",
                        f"forbidden allow entry {entry!r} matches /{pattern}/",
                    )
                )

    for pattern in role_schema.get("disallow_allow_regex", []):
        rgx = re.compile(pattern)
        for entry in allow:
            if rgx.search(entry):
                findings.append(
                    Finding(
                        source_label,
                        role_name,
                        "ERROR",
                        f"role contract violation: {entry!r} matches /{pattern}/",
                    )
                )

    allow_set = set(allow)
    required_allow = role_schema.get("required_allow", [])
    for req in required_allow:
        if req not in allow_set:
            findings.append(
                Finding(source_label, role_name, "ERROR", f"missing required allow: {req!r}")
            )

    if role_schema.get("closed_world"):
        required_set = set(required_allow)
        extra_patterns = [re.compile(p) for p in role_schema.get("allowed_allow_regex", [])]
        override_set = extra_allowed or set()
        for entry in allow:
            if entry in required_set:
                continue
            if entry in override_set:
                continue
            if any(p.search(entry) for p in extra_patterns):
                continue
            findings.append(
                Finding(
                    source_label,
                    role_name,
                    "ERROR",
                    (
                        f"unknown allow entry {entry!r} -- not in schema's "
                        "required_allow nor allowed_allow_regex; add to schema "
                        "(with justification) or remove."
                    ),
                )
            )

    deny_set = set(deny)
    for req in role_schema.get("required_deny", []):
        if req not in deny_set:
            findings.append(
                Finding(source_label, role_name, "ERROR", f"missing required deny: {req!r}")
            )

    hook_tuples = list(_iter_hooks(config))
    for req in role_schema.get("required_hooks", []):
        ev = req["event"]
        match_sub = req.get("matcher_contains", "")
        cmd_sub = req.get("command_contains", "")
        hit = any(
            event == ev and match_sub in matcher and cmd_sub in cmd
            for event, matcher, cmd in hook_tuples
        )
        if not hit:
            findings.append(
                Finding(
                    source_label,
                    role_name,
                    "ERROR",
                    (
                        "missing required hook: "
                        f"event={ev} matcher~={match_sub!r} command~={cmd_sub!r}"
                    ),
                )
            )

    return findings


# ---------------------------------------------------------------------------
# Schema integrity
# ---------------------------------------------------------------------------


def validate_schema_integrity(schema: dict) -> list:
    """Cross-check ``required_hook_scripts`` against ``roles[*].required_hooks``.

    Every entry in ``required_hook_scripts`` must be referenced by at
    least one role's ``required_hooks[].command_contains`` (literal
    substring); otherwise the schema declares a script as mandatory yet
    no role enforces it.
    """
    findings: list = []
    required_scripts = set(schema.get("required_hook_scripts", []))
    seen: set = set()
    for role_name, role in schema.get("roles", {}).items():
        for hook in role.get("required_hooks", []):
            cmd = hook.get("command_contains", "")
            if cmd.endswith(".sh"):
                seen.add(cmd)
    missing = required_scripts - seen
    for script in sorted(missing):
        findings.append(
            Finding(
                "schema",
                "<global>",
                "ERROR",
                f"required hook script {script!r} not referenced by any role",
            )
        )
    return findings


# ---------------------------------------------------------------------------
# Docs projection
# ---------------------------------------------------------------------------


def extract_role_blocks(md_text: str, roles: dict) -> dict:
    """Extract the first ```json code block under each role's docs heading.

    The role schema's ``docs_section`` field must appear inside a
    ``## ``-prefixed heading line for the role to match.
    """
    results: dict = {}
    sections = re.split(r"(?m)^## ", md_text)
    for role_name, role_def in roles.items():
        marker = role_def.get("docs_section")
        if not marker:
            continue
        block = None
        for section in sections[1:]:
            if marker in section.splitlines()[0]:
                m = re.search(r"```json\n(.*?)\n```", section, re.DOTALL)
                if m:
                    try:
                        block = json.loads(m.group(1))
                    except json.JSONDecodeError as exc:
                        block = {"__parse_error__": str(exc)}
                break
        results[role_name] = block
    return results


# ---------------------------------------------------------------------------
# Worker template match (drift detection)
# ---------------------------------------------------------------------------


_PLACEHOLDER_PATTERN = re.compile(r"\{[a-zA-Z_][a-zA-Z0-9_]*\}")


def _strip_meta(template: dict) -> dict:
    return {k: v for k, v in template.items() if k not in {"description", "$comment"}}


def _norm_path(s: str) -> str:
    return s.replace("\\", "/").rstrip("/")


def _match(value: Any, template: Any, bindings: dict) -> bool:
    if isinstance(template, str):
        if not isinstance(value, str):
            return False
        if not _PLACEHOLDER_PATTERN.search(template):
            return value == template
        parts = re.split(r"(\{[a-zA-Z_][a-zA-Z0-9_]*\})", template)
        pattern = "".join(
            f"(?P<__ph{idx}>.*)" if _PLACEHOLDER_PATTERN.fullmatch(p) else re.escape(p)
            for idx, p in enumerate(parts)
        )
        m = re.fullmatch(pattern, value)
        if m is None:
            return False
        ph_indices = [i for i, p in enumerate(parts) if _PLACEHOLDER_PATTERN.fullmatch(p)]
        for idx in ph_indices:
            ph = parts[idx]
            captured = m.group(f"__ph{idx}")
            existing = bindings.get(ph)
            if existing is None:
                bindings[ph] = captured
            elif existing != captured:
                return False
        return True
    if isinstance(template, list):
        if not isinstance(value, list) or len(value) != len(template):
            return False
        return all(_match(v, t, bindings) for v, t in zip(value, template))
    if isinstance(template, dict):
        if not isinstance(value, dict) or set(value) != set(template):
            return False
        return all(_match(value[k], template[k], bindings) for k in template)
    return value == template


def matches_worker_template(
    config: dict,
    template: dict,
    *,
    expected_worker_dir: str | None = None,
) -> bool:
    """Return True when ``config`` is a placeholder-consistent match of
    ``template``.

    Each placeholder ({worker_dir}, {consumer_root}, …) is captured;
    its captured value must agree across all occurrences in one match
    attempt. When ``expected_worker_dir`` is supplied, the
    ``{worker_dir}`` capture must equal it (path-separator
    normalised).
    """
    bindings: dict = {}
    if not _match(config, template, bindings):
        return False
    if expected_worker_dir is not None and "{worker_dir}" in bindings:
        if _norm_path(bindings["{worker_dir}"]) != _norm_path(expected_worker_dir):
            return False
    return True


def check_worker_settings(schema: dict, base_dir) -> list:
    """Walk ``<base_dir>/*/.claude/settings.local.json`` and report
    drift against the ``worker_roles`` templates from ``schema``."""
    findings: list = []
    base_dir = Path(base_dir)
    if not base_dir.is_dir():
        findings.append(
            Finding(
                str(base_dir),
                "<worker-settings>",
                "ERROR",
                "base directory does not exist",
            )
        )
        return findings

    worker_roles_raw = schema.get("worker_roles") or {}
    templates = {
        name: _strip_meta(body)
        for name, body in worker_roles_raw.items()
        if not name.startswith("$") and isinstance(body, dict)
    }
    if not templates:
        findings.append(
            Finding("schema", "<worker-settings>", "ERROR", "schema has no worker_roles templates")
        )
        return findings

    for worker_dir in sorted(p for p in base_dir.iterdir() if p.is_dir()):
        settings_path = worker_dir / ".claude" / "settings.local.json"
        if not settings_path.is_file():
            continue
        try:
            config = json.loads(settings_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            findings.append(
                Finding(
                    str(settings_path),
                    "<worker-settings>",
                    "ERROR",
                    f"JSON parse error: {exc}",
                )
            )
            continue
        expected_wd = str(worker_dir.resolve())
        matched = [
            name
            for name, tmpl in templates.items()
            if matches_worker_template(config, tmpl, expected_worker_dir=expected_wd)
        ]
        if not matched:
            findings.append(
                Finding(
                    str(settings_path),
                    "<worker-settings>",
                    "ERROR",
                    (
                        "does not match any worker_roles template; "
                        "regenerate via the generator or extend the schema"
                    ),
                )
            )
    return findings


# ---------------------------------------------------------------------------
# Top-level entry point
# ---------------------------------------------------------------------------


def validate_settings(
    settings_local_json: dict | None,
    framework_schema: dict | None,
    org_extension_schema: dict,
    *,
    role: str,
    source_label: str = "<settings>",
    extra_allowed: set | None = None,
    check_integrity: bool = True,
) -> ValidationResult:
    """Validate one ``settings.local.json`` payload for ``role``.

    ``framework_schema`` is the dict returned by
    :func:`core_harness.schema.load_framework_schema`. It contributes
    structure today and may contribute defaults in future 0.x
    revisions; pass ``None`` to skip merge-time injection.

    ``org_extension_schema`` carries the concrete role definitions and
    audit constraints (the consumer's renamed
    ``role_configs_schema.json``).

    ``role`` selects which entry under ``roles{}`` to validate against.
    """
    merged = merge_schemas(framework_schema, org_extension_schema)
    findings: list = []
    if check_integrity:
        findings.extend(validate_schema_integrity(merged))
    role_schema = merged["roles"].get(role)
    if role_schema is None:
        findings.append(Finding(source_label, role, "ERROR", f"unknown role: {role!r}"))
        return ValidationResult(findings=findings)
    findings.extend(
        validate_config(
            source_label,
            role,
            settings_local_json,
            role_schema,
            merged.get("global", {}),
            extra_allowed=extra_allowed,
        )
    )
    return ValidationResult(findings=findings)


__all__ = [
    "Finding",
    "ValidationResult",
    "validate_settings",
    "validate_config",
    "validate_schema_integrity",
    "extract_role_blocks",
    "check_worker_settings",
    "matches_worker_template",
]
