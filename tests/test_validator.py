"""Generic validator tests.

Synthetic schema fixtures only — no consumer-org strings (no role names
like 'secretary', no banned regexes specific to a particular org). The
validator engine must be exercisable without claude-org-ja being on
disk. Cross-fixture / consumer-doctrine tests live in the consumer
repository.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from core_harness.schema import (
    SchemaError,
    framework_schema_path,
    load_framework_schema,
    merge_schemas,
)
from core_harness.validator import (
    Finding,
    ValidationResult,
    check_worker_settings,
    extract_role_blocks,
    matches_worker_template,
    validate_config,
    validate_schema_integrity,
    validate_settings,
)


def _minimal_extension_schema() -> dict:
    """A tiny, fully-synthetic org-extension schema."""
    return {
        "version": 1,
        "global": {
            "forbidden_allow_exact": ["Bash(* unsafe)"],
            "forbidden_allow_regex": ["^mcp__legacy__"],
        },
        "required_hook_scripts": ["block-example.sh"],
        "roles": {
            "alpha": {
                "docs_section": "Alpha",
                "settings_paths": [],
                "closed_world": True,
                "required_allow": ["Bash(echo:*)"],
                "allowed_allow_regex": [r"^Bash\(printf [a-z]+:\*\)$"],
                "required_deny": [],
                "required_hooks": [],
                "disallow_allow_regex": [r"^Bash\(\*\)$"],
            },
            "beta": {
                "docs_section": "Beta",
                "settings_paths": [],
                "closed_world": False,
                "required_allow": ["Bash(echo:*)"],
                "allowed_allow_regex": [],
                "required_deny": ["Bash(rm -rf *)"],
                "required_hooks": [
                    {
                        "event": "PreToolUse",
                        "matcher_contains": "Bash",
                        "command_contains": "block-example.sh",
                    }
                ],
                "disallow_allow_regex": [],
            },
        },
    }


def _good_alpha() -> dict:
    return {"permissions": {"allow": ["Bash(echo:*)"]}}


def _good_beta() -> dict:
    return {
        "permissions": {
            "allow": ["Bash(echo:*)"],
            "deny": ["Bash(rm -rf *)"],
        },
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {"type": "command", "command": "bash hooks/block-example.sh"}
                    ],
                }
            ]
        },
    }


class FrameworkSchemaTests(unittest.TestCase):
    def test_load_framework_schema_returns_dict(self):
        fw = load_framework_schema()
        self.assertIsInstance(fw, dict)
        self.assertIn("$schema", fw)
        self.assertIn("definitions", fw)

    def test_framework_schema_path_exists(self):
        self.assertTrue(framework_schema_path().is_file())

    def test_framework_schema_does_not_carry_org_specifics(self):
        """Layer 1 purity: no role names / consumer regexes baked in."""
        text = framework_schema_path().read_text(encoding="utf-8")
        for forbidden in ("secretary", "dispatcher", "claude-peers", "workers_dir"):
            self.assertNotIn(
                forbidden,
                text,
                f"framework_schema.json must not mention {forbidden!r}",
            )


class MergeSchemasTests(unittest.TestCase):
    def test_merge_normalises_missing_keys(self):
        merged = merge_schemas(None, {})
        self.assertEqual(merged["global"]["forbidden_allow_exact"], [])
        self.assertEqual(merged["global"]["forbidden_allow_regex"], [])
        self.assertEqual(merged["required_hook_scripts"], [])
        self.assertEqual(merged["roles"], {})
        self.assertEqual(merged["worker_roles"], {})

    def test_merge_does_not_mutate_input(self):
        ext = {"roles": {"x": {}}}
        merge_schemas(None, ext)
        self.assertNotIn("global", ext)


class ValidateConfigTests(unittest.TestCase):
    def setUp(self):
        self.schema = _minimal_extension_schema()

    def _validate(self, role: str, config) -> list:
        merged = merge_schemas(load_framework_schema(), self.schema)
        return validate_config(
            "test", role, config, merged["roles"][role], merged.get("global", {})
        )

    def test_good_alpha_passes(self):
        self.assertEqual(self._validate("alpha", _good_alpha()), [])

    def test_good_beta_passes(self):
        self.assertEqual(self._validate("beta", _good_beta()), [])

    def test_missing_config_errors(self):
        findings = self._validate("alpha", None)
        self.assertEqual(len(findings), 1)
        self.assertIn("missing", findings[0].message)

    def test_forbidden_regex_match(self):
        config = _good_alpha()
        config["permissions"]["allow"].append("mcp__legacy__send")
        findings = self._validate("alpha", config)
        self.assertTrue(any("legacy" in f.message for f in findings))

    def test_forbidden_exact_match(self):
        config = _good_alpha()
        config["permissions"]["allow"].append("Bash(* unsafe)")
        findings = self._validate("alpha", config)
        self.assertTrue(any("forbidden wide allow" in f.message for f in findings))

    def test_role_contract_disallow_regex(self):
        config = _good_alpha()
        config["permissions"]["allow"].append("Bash(*)")
        findings = self._validate("alpha", config)
        self.assertTrue(any("role contract" in f.message for f in findings))

    def test_missing_required_allow(self):
        findings = self._validate("alpha", {"permissions": {"allow": []}})
        self.assertTrue(any("missing required allow" in f.message for f in findings))

    def test_beta_missing_required_deny(self):
        config = _good_beta()
        config["permissions"]["deny"] = []
        findings = self._validate("beta", config)
        self.assertTrue(any("missing required deny" in f.message for f in findings))

    def test_beta_missing_required_hook(self):
        config = _good_beta()
        config["hooks"] = {}
        findings = self._validate("beta", config)
        self.assertTrue(any("missing required hook" in f.message for f in findings))

    def test_closed_world_flags_unknown(self):
        config = {"permissions": {"allow": ["Bash(echo:*)", "Bash(rogue:*)"]}}
        findings = self._validate("alpha", config)
        self.assertTrue(
            any("unknown allow entry" in f.message and "rogue" in f.message for f in findings)
        )

    def test_closed_world_pattern_passes(self):
        config = {"permissions": {"allow": ["Bash(echo:*)", "Bash(printf hi:*)"]}}
        self.assertEqual(self._validate("alpha", config), [])

    def test_open_world_ignores_extras(self):
        config = _good_beta()
        config["permissions"]["allow"].append("Bash(brand-new:*)")
        self.assertEqual(self._validate("beta", config), [])

    def test_extra_allowed_overrides_closed_world(self):
        merged = merge_schemas(load_framework_schema(), self.schema)
        config = {"permissions": {"allow": ["Bash(echo:*)", "Bash(escape:*)"]}}
        findings = validate_config(
            "test",
            "alpha",
            config,
            merged["roles"]["alpha"],
            merged["global"],
            extra_allowed={"Bash(escape:*)"},
        )
        self.assertEqual(findings, [])


class SchemaIntegrityTests(unittest.TestCase):
    def test_unreferenced_required_script_errors(self):
        schema = _minimal_extension_schema()
        schema["required_hook_scripts"].append("nonexistent.sh")
        findings = validate_schema_integrity(schema)
        self.assertTrue(any("nonexistent.sh" in f.message for f in findings))

    def test_referenced_required_script_passes(self):
        schema = _minimal_extension_schema()
        # beta references block-example.sh; integrity should pass
        findings = validate_schema_integrity(schema)
        self.assertEqual(findings, [])


class ExtractRoleBlocksTests(unittest.TestCase):
    def test_extracts_first_json_per_section(self):
        md = (
            "# Heading\n\n"
            "## Alpha note\n\n"
            "intro\n\n"
            "```json\n{\"permissions\": {\"allow\": [\"a\"]}}\n```\n\n"
            "## Beta\n\n"
            "```json\n{\"permissions\": {\"allow\": [\"b\"]}}\n```\n"
        )
        blocks = extract_role_blocks(md, _minimal_extension_schema()["roles"])
        self.assertEqual(blocks["alpha"]["permissions"]["allow"], ["a"])
        self.assertEqual(blocks["beta"]["permissions"]["allow"], ["b"])

    def test_invalid_json_surfaces_parse_error(self):
        md = "## Alpha\n\n```json\n{not json}\n```\n"
        blocks = extract_role_blocks(md, _minimal_extension_schema()["roles"])
        self.assertIn("__parse_error__", blocks["alpha"])


class WorkerTemplateMatchTests(unittest.TestCase):
    TEMPLATE = {
        "permissions": {"allow": ["Bash(sleep:*)"], "deny": []},
        "hooks": {
            "PreToolUse": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {
                            "type": "command",
                            "command": "bash \"{consumer_root}/hooks/x.sh\"",
                        }
                    ],
                }
            ]
        },
        "env": {"WORKER_DIR": "{worker_dir}", "CONSUMER_ROOT": "{consumer_root}"},
    }

    def test_consistent_match(self):
        config = {
            "permissions": {"allow": ["Bash(sleep:*)"], "deny": []},
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Bash",
                        "hooks": [
                            {"type": "command", "command": 'bash "/abs/co/hooks/x.sh"'}
                        ],
                    }
                ]
            },
            "env": {"WORKER_DIR": "/abs/wd", "CONSUMER_ROOT": "/abs/co"},
        }
        self.assertTrue(matches_worker_template(config, self.TEMPLATE))
        self.assertTrue(
            matches_worker_template(config, self.TEMPLATE, expected_worker_dir="/abs/wd")
        )

    def test_inconsistent_placeholder_rejected(self):
        config = {
            "permissions": {"allow": ["Bash(sleep:*)"], "deny": []},
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "Bash",
                        "hooks": [
                            {"type": "command", "command": 'bash "/abs/co/hooks/x.sh"'}
                        ],
                    }
                ]
            },
            "env": {"WORKER_DIR": "/abs/wd", "CONSUMER_ROOT": "/different/co"},
        }
        self.assertFalse(matches_worker_template(config, self.TEMPLATE))

    def test_check_worker_settings_missing_base_dir(self):
        findings = check_worker_settings({"worker_roles": {"x": self.TEMPLATE}}, Path("/no/such/__nope__"))
        self.assertTrue(any("does not exist" in f.message for f in findings))


class ValidateSettingsTopLevelTests(unittest.TestCase):
    def test_validate_settings_returns_validation_result(self):
        result = validate_settings(
            _good_beta(),
            load_framework_schema(),
            _minimal_extension_schema(),
            role="beta",
        )
        self.assertIsInstance(result, ValidationResult)
        self.assertTrue(result.ok)

    def test_validate_settings_unknown_role(self):
        result = validate_settings(
            _good_beta(),
            load_framework_schema(),
            _minimal_extension_schema(),
            role="ghost",
        )
        self.assertFalse(result.ok)
        self.assertTrue(any("unknown role" in f.message for f in result))

    def test_validate_settings_surfaces_violations(self):
        bad = _good_beta()
        bad["permissions"]["deny"] = []
        result = validate_settings(
            bad,
            load_framework_schema(),
            _minimal_extension_schema(),
            role="beta",
        )
        self.assertFalse(result.ok)


class FindingTests(unittest.TestCase):
    def test_format(self):
        f = Finding("src", "role", "ERROR", "boom")
        self.assertEqual(f.format(), "[ERROR] src :: role :: boom")


class FailClosedTests(unittest.TestCase):
    """Layer 1 must turn malformed input into errors, not exceptions."""

    def test_merge_rejects_non_list_forbidden_regex(self):
        ext = {"global": {"forbidden_allow_regex": "not a list"}}
        with self.assertRaises(SchemaError):
            merge_schemas(None, ext)

    def test_merge_rejects_invalid_regex(self):
        ext = {"global": {"forbidden_allow_regex": ["["]}}
        with self.assertRaises(SchemaError):
            merge_schemas(None, ext)

    def test_merge_rejects_non_dict_role(self):
        ext = {"roles": {"alpha": "not a dict"}}
        with self.assertRaises(SchemaError):
            merge_schemas(None, ext)

    def test_merge_rejects_non_string_required_hook_script(self):
        ext = {"required_hook_scripts": [123]}
        with self.assertRaises(SchemaError):
            merge_schemas(None, ext)

    def test_validate_settings_surfaces_schema_error(self):
        bad_ext = {"global": {"forbidden_allow_regex": ["["]}}
        result = validate_settings(
            {"permissions": {"allow": []}},
            None,
            bad_ext,
            role="alpha",
        )
        self.assertFalse(result.ok)
        self.assertTrue(any("invalid regex" in f.message for f in result))

    def test_validate_config_handles_non_dict_config(self):
        merged = merge_schemas(None, _minimal_extension_schema())
        findings = validate_config(
            "test", "alpha", "i am not a dict", merged["roles"]["alpha"], merged["global"]
        )
        self.assertTrue(any("must be a dict" in f.message for f in findings))

    def test_validate_config_handles_malformed_hooks(self):
        merged = merge_schemas(None, _minimal_extension_schema())
        # hooks entry is a string instead of a list of dicts
        config = {
            "permissions": {"allow": ["Bash(echo:*)"], "deny": ["Bash(rm -rf *)"]},
            "hooks": "garbage",
        }
        findings = validate_config(
            "test", "beta", config, merged["roles"]["beta"], merged["global"]
        )
        # missing required hook is detected; engine does not crash
        self.assertTrue(any("missing required hook" in f.message for f in findings))

    def test_matches_worker_template_rejects_unsubstituted_capture(self):
        template = {"env": {"X": "{consumer_root}"}}
        leaky_config = {"env": {"X": "{consumer_root}"}}  # placeholder leaked
        self.assertFalse(matches_worker_template(leaky_config, template))


class ValidationResultBoolTests(unittest.TestCase):
    """0.3.1: bool(ValidationResult) is rejected to prevent ``if result``
    being misread as ``if result.ok``. See cross-review M5."""

    def test_bool_raises_typeerror(self):
        result = ValidationResult(findings=[])
        with self.assertRaises(TypeError):
            bool(result)

    def test_bool_raises_even_with_errors(self):
        result = ValidationResult(findings=[Finding("s", "r", "ERROR", "x")])
        with self.assertRaises(TypeError):
            bool(result)

    def test_ok_property_still_works(self):
        self.assertTrue(ValidationResult(findings=[]).ok)
        self.assertFalse(
            ValidationResult(findings=[Finding("s", "r", "ERROR", "x")]).ok
        )


class CheckWorkerSettingsWorktreesTests(unittest.TestCase):
    """0.3.1: include_worktrees descends into ``.worktrees/<branch>/``."""

    TEMPLATE = {
        "permissions": {"allow": ["Bash(sleep:*)"], "deny": []},
        "env": {"WORKER_DIR": "{worker_dir}"},
    }

    def _make_settings(self, dir_path: Path, worker_dir_value: str) -> None:
        claude_dir = dir_path / ".claude"
        claude_dir.mkdir(parents=True, exist_ok=True)
        (claude_dir / "settings.local.json").write_text(
            json.dumps(
                {
                    "permissions": {"allow": ["Bash(sleep:*)"], "deny": []},
                    "env": {"WORKER_DIR": worker_dir_value},
                }
            ),
            encoding="utf-8",
        )

    def test_include_worktrees_descends(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            wt = base / ".worktrees" / "branch-a"
            self._make_settings(wt, str(wt.resolve()))
            findings = check_worker_settings(
                {"worker_roles": {"x": self.TEMPLATE}}, base
            )
            self.assertEqual(findings, [])

    def test_include_worktrees_false_skips(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            wt = base / ".worktrees" / "branch-a"
            # populate with config that would NOT match — to assert we skip
            self._make_settings(wt, "/wrong/path")
            findings = check_worker_settings(
                {"worker_roles": {"x": self.TEMPLATE}},
                base,
                include_worktrees=False,
            )
            # No finding because we never even looked at .worktrees
            self.assertEqual(findings, [])


if __name__ == "__main__":
    unittest.main()
