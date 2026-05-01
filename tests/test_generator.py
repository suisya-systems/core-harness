"""Generic generator tests.

Synthetic worker_roles fixtures only — no consumer-org template names
or paths. The generator must emit valid output for any caller-supplied
placeholder mapping. Org-specific template behaviour (e.g. ja's
``doc-audit`` denies Edit/Write) lives in the consumer repository.
"""

from __future__ import annotations

import unittest

from core_harness.generator import (
    UnresolvedPlaceholderError,
    generate_settings,
    render_role,
)
from core_harness.schema import load_framework_schema


def _fixture_schema() -> dict:
    return {
        "version": 1,
        "worker_roles": {
            "$comment": "test fixture",
            "default": {
                "description": "test default",
                "permissions": {"allow": ["Bash(sleep:*)"], "deny": []},
                "hooks": {
                    "PreToolUse": [
                        {
                            "matcher": "Bash",
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "bash \"{consumer_root}/hooks/example.sh\"",
                                }
                            ],
                        }
                    ]
                },
                "env": {
                    "WORKER_DIR": "{worker_dir}",
                    "CONSUMER_ROOT": "{consumer_root}",
                },
            },
            "with-extra": {
                "description": "uses an extra placeholder",
                "permissions": {"allow": [], "deny": []},
                "env": {"EXTRA": "{my_alias}"},
            },
        },
    }


class RenderRoleTests(unittest.TestCase):
    def test_substitutes_placeholders(self):
        out = render_role(
            _fixture_schema(),
            "default",
            worker_dir="/abs/wd",
            consumer_root="/abs/co",
        )
        self.assertEqual(out["env"]["WORKER_DIR"], "/abs/wd")
        self.assertEqual(out["env"]["CONSUMER_ROOT"], "/abs/co")
        cmd = out["hooks"]["PreToolUse"][0]["hooks"][0]["command"]
        self.assertIn("/abs/co/hooks/example.sh", cmd)
        self.assertNotIn("{consumer_root}", cmd)

    def test_strips_meta_keys(self):
        out = render_role(
            _fixture_schema(),
            "default",
            worker_dir="/wd",
            consumer_root="/co",
        )
        self.assertNotIn("description", out)
        self.assertNotIn("$comment", out)

    def test_unknown_role_raises(self):
        with self.assertRaises(KeyError) as ctx:
            render_role(_fixture_schema(), "no-such-role", worker_dir="/x")
        self.assertIn("unknown worker role", str(ctx.exception))

    def test_dollar_prefixed_role_rejected(self):
        with self.assertRaises(KeyError):
            render_role(_fixture_schema(), "$comment", worker_dir="/x")

    def test_extra_placeholder_substituted(self):
        out = render_role(
            _fixture_schema(),
            "with-extra",
            worker_dir="/wd",
            my_alias="banana",
        )
        self.assertEqual(out["env"]["EXTRA"], "banana")

    def test_input_schema_not_mutated(self):
        schema = _fixture_schema()
        before = schema["worker_roles"]["default"]["env"]["WORKER_DIR"]
        render_role(schema, "default", worker_dir="/wd", consumer_root="/co")
        self.assertEqual(
            schema["worker_roles"]["default"]["env"]["WORKER_DIR"], before
        )


class GenerateSettingsTests(unittest.TestCase):
    def test_top_level_entry_point(self):
        out = generate_settings(
            "default",
            "/abs/wd",
            load_framework_schema(),
            _fixture_schema(),
            consumer_root="/abs/co",
        )
        self.assertEqual(out["env"]["WORKER_DIR"], "/abs/wd")
        self.assertEqual(out["env"]["CONSUMER_ROOT"], "/abs/co")

    def test_extra_placeholders_supported(self):
        out = generate_settings(
            "with-extra",
            "/abs/wd",
            None,
            _fixture_schema(),
            extra_placeholders={"my_alias": "x"},
        )
        self.assertEqual(out["env"]["EXTRA"], "x")

    def test_consumer_root_alias_pattern(self):
        """A consumer org may keep a legacy placeholder alias by passing it
        through ``extra_placeholders`` pointing at the same value as
        ``consumer_root``."""
        schema = _fixture_schema()
        schema["worker_roles"]["aliased"] = {
            "permissions": {"allow": [], "deny": []},
            "env": {"OLD": "{old_root}", "NEW": "{consumer_root}"},
        }
        out = generate_settings(
            "aliased",
            "/wd",
            None,
            schema,
            consumer_root="/co",
            extra_placeholders={"old_root": "/co"},
        )
        self.assertEqual(out["env"]["OLD"], "/co")
        self.assertEqual(out["env"]["NEW"], "/co")


class FailClosedTests(unittest.TestCase):
    def test_render_role_raises_on_unresolved_placeholder(self):
        with self.assertRaises(UnresolvedPlaceholderError) as ctx:
            render_role(
                _fixture_schema(),
                "default",
                worker_dir="/abs/wd",
                # consumer_root deliberately omitted
            )
        self.assertIn("consumer_root", str(ctx.exception))

    def test_generate_settings_raises_on_missing_consumer_root(self):
        with self.assertRaises(UnresolvedPlaceholderError):
            generate_settings(
                "default",
                "/abs/wd",
                None,
                _fixture_schema(),
                # consumer_root missing — fail closed
            )


if __name__ == "__main__":
    unittest.main()
