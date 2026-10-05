"""Hook framework tests (Step C / 0.2).

Generic only — no consumer-org strings. Exercises the contract documented
in ``docs/hook-contract.md``: stdin JSON parse, exit code semantics,
stderr block-prefix resolution, and that ``lib_path()`` resolves to a
directory containing the bash companion library.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

from core_harness import hooks
from core_harness.hooks import (
    ALLOW_EXIT_CODE,
    BLOCK_EXIT_CODE,
    DEFAULT_BLOCK_PREFIX,
    HookRunner,
    lib_path,
)


class LibPathTests(unittest.TestCase):
    def test_lib_path_is_directory(self) -> None:
        p = lib_path()
        self.assertTrue(p.is_dir(), f"{p} should be a directory")

    def test_lib_path_contains_companion_script(self) -> None:
        script = lib_path() / "core_harness_hooks.sh"
        self.assertTrue(
            script.is_file(),
            f"{script} should ship with the package",
        )

    def test_lib_path_returns_path_object(self) -> None:
        self.assertIsInstance(lib_path(), Path)


class DefaultPrefixTests(unittest.TestCase):
    def test_default_is_neutral_english(self) -> None:
        # Layer-1 purity: the default ships no consumer-specific locale.
        # Consumers (e.g. claude-org-ja's "ブロック: ") inject their
        # own prefix via env or constructor arg.
        self.assertEqual(DEFAULT_BLOCK_PREFIX, "Blocked: ")


class ParseStdinTests(unittest.TestCase):
    def setUp(self) -> None:
        self._saved_env = os.environ.pop("CORE_HARNESS_BLOCK_PREFIX", None)

    def tearDown(self) -> None:
        if self._saved_env is not None:
            os.environ["CORE_HARNESS_BLOCK_PREFIX"] = self._saved_env

    def _runner(self, raw: str, *, stderr: io.StringIO | None = None) -> HookRunner:
        return HookRunner(
            stdin=io.StringIO(raw),
            stderr=stderr or io.StringIO(),
        )

    def _assert_blocks(self, raw: str) -> str:
        stderr = io.StringIO()
        runner = self._runner(raw, stderr=stderr)
        with self.assertRaises(SystemExit) as cm:
            runner.parse_pretooluse_stdin()
        self.assertEqual(cm.exception.code, BLOCK_EXIT_CODE, repr(raw))
        self.assertTrue(stderr.getvalue().startswith(DEFAULT_BLOCK_PREFIX))
        return stderr.getvalue()

    def test_empty_stdin_blocks(self) -> None:
        # Claude Code always sends a JSON object; an empty payload means
        # the hook cannot see what it guards, so it fails closed (#17).
        self.assertIn("empty", self._assert_blocks(""))

    def test_whitespace_only_blocks(self) -> None:
        self._assert_blocks("   \n\t")

    def test_concatenated_objects_block(self) -> None:
        self._assert_blocks("{}{}")
        self._assert_blocks('{"tool_name":"Bash"}\n{"tool_name":"Bash"}')

    def test_deeply_nested_json_blocks(self) -> None:
        # json.loads raises RecursionError here; uncaught it exits 1,
        # which Claude Code treats as non-blocking (fail open).
        depth = 100000
        self._assert_blocks(
            '{"tool_input":{"a":' + "[" * depth + "]" * depth + "}}"
        )

    def test_trailing_garbage_blocks(self) -> None:
        self._assert_blocks("{}x")

    def test_truncated_json_blocks(self) -> None:
        self._assert_blocks('{"tool_input":')

    def test_scalar_payloads_block(self) -> None:
        for raw in ('"str"', "42", "null", "true", "-n", "-e"):
            with self.subTest(raw=raw):
                self._assert_blocks(raw)

    def test_non_object_tool_input_blocks(self) -> None:
        for raw in (
            '{"tool_input":"git push"}',
            '{"tool_input":["git","push"]}',
            '{"tool_input":1}',
            '{"tool_input":false}',
        ):
            with self.subTest(raw=raw):
                self.assertIn("tool_input", self._assert_blocks(raw))

    def test_missing_or_null_tool_input_ok(self) -> None:
        for payload in (
            {"tool_name": "Bash"},
            {"tool_name": "Bash", "tool_input": None},
            {},
        ):
            with self.subTest(payload=payload):
                result = self._runner(json.dumps(payload)).parse_pretooluse_stdin()
                self.assertEqual(result, payload)

    def test_round_trip_payload(self) -> None:
        payload = {
            "tool_name": "Bash",
            "tool_input": {"command": "echo hello"},
        }
        result = self._runner(json.dumps(payload)).parse_pretooluse_stdin()
        self.assertEqual(result, payload)

    def test_unicode_round_trip(self) -> None:
        payload = {"tool_name": "Bash", "tool_input": {"command": "echo こんにちは"}}
        result = self._runner(json.dumps(payload, ensure_ascii=False)).parse_pretooluse_stdin()
        self.assertEqual(result, payload)

    def test_invalid_json_blocks(self) -> None:
        stderr = io.StringIO()
        runner = self._runner("{not json", stderr=stderr)
        with self.assertRaises(SystemExit) as cm:
            runner.parse_pretooluse_stdin()
        self.assertEqual(cm.exception.code, BLOCK_EXIT_CODE)
        self.assertTrue(stderr.getvalue().startswith(DEFAULT_BLOCK_PREFIX))
        self.assertIn("PreToolUse JSON", stderr.getvalue())

    def test_non_object_payload_blocks(self) -> None:
        stderr = io.StringIO()
        runner = self._runner("[1, 2, 3]", stderr=stderr)
        with self.assertRaises(SystemExit) as cm:
            runner.parse_pretooluse_stdin()
        self.assertEqual(cm.exception.code, BLOCK_EXIT_CODE)
        self.assertTrue(stderr.getvalue().startswith(DEFAULT_BLOCK_PREFIX))


class ExitTests(unittest.TestCase):
    def test_exit_with_block_writes_default_prefix(self) -> None:
        old = os.environ.pop("CORE_HARNESS_BLOCK_PREFIX", None)
        try:
            stderr = io.StringIO()
            runner = HookRunner(stderr=stderr, stdin=io.StringIO(""))
            with self.assertRaises(SystemExit) as cm:
                runner.exit_with_block("test reason")
            self.assertEqual(cm.exception.code, BLOCK_EXIT_CODE)
            self.assertEqual(stderr.getvalue(), f"{DEFAULT_BLOCK_PREFIX}test reason\n")
            self.assertTrue(stderr.getvalue().startswith("Blocked: "))
        finally:
            if old is not None:
                os.environ["CORE_HARNESS_BLOCK_PREFIX"] = old

    def test_consumer_can_inject_legacy_japanese_prefix(self) -> None:
        # Regression: the override path is the contract claude-org-ja
        # relies on to keep its 380+ existing hook tests green during
        # the 0.x transition. Don't break this.
        stderr = io.StringIO()
        runner = HookRunner(
            stderr=stderr,
            stdin=io.StringIO(""),
            block_prefix="ブロック: ",
        )
        with self.assertRaises(SystemExit):
            runner.exit_with_block("テスト理由")
        self.assertEqual(stderr.getvalue(), "ブロック: テスト理由\n")

    def test_exit_with_block_uses_explicit_prefix(self) -> None:
        stderr = io.StringIO()
        runner = HookRunner(
            stderr=stderr,
            stdin=io.StringIO(""),
            block_prefix="BLOCKED: ",
        )
        with self.assertRaises(SystemExit) as cm:
            runner.exit_with_block("nope")
        self.assertEqual(cm.exception.code, BLOCK_EXIT_CODE)
        self.assertEqual(stderr.getvalue(), "BLOCKED: nope\n")

    def test_exit_with_block_uses_env_prefix(self) -> None:
        stderr = io.StringIO()
        old = os.environ.get("CORE_HARNESS_BLOCK_PREFIX")
        os.environ["CORE_HARNESS_BLOCK_PREFIX"] = "DENY> "
        try:
            runner = HookRunner(stderr=stderr, stdin=io.StringIO(""))
            with self.assertRaises(SystemExit):
                runner.exit_with_block("x")
            self.assertEqual(stderr.getvalue(), "DENY> x\n")
        finally:
            if old is None:
                os.environ.pop("CORE_HARNESS_BLOCK_PREFIX", None)
            else:
                os.environ["CORE_HARNESS_BLOCK_PREFIX"] = old

    def test_explicit_arg_beats_env(self) -> None:
        stderr = io.StringIO()
        old = os.environ.get("CORE_HARNESS_BLOCK_PREFIX")
        os.environ["CORE_HARNESS_BLOCK_PREFIX"] = "ENV: "
        try:
            runner = HookRunner(
                stderr=stderr,
                stdin=io.StringIO(""),
                block_prefix="ARG: ",
            )
            with self.assertRaises(SystemExit):
                runner.exit_with_block("x")
            self.assertEqual(stderr.getvalue(), "ARG: x\n")
        finally:
            if old is None:
                os.environ.pop("CORE_HARNESS_BLOCK_PREFIX", None)
            else:
                os.environ["CORE_HARNESS_BLOCK_PREFIX"] = old

    def test_exit_ok_returns_zero(self) -> None:
        runner = HookRunner(stderr=io.StringIO(), stdin=io.StringIO(""))
        with self.assertRaises(SystemExit) as cm:
            runner.exit_ok()
        self.assertEqual(cm.exception.code, ALLOW_EXIT_CODE)


class ModuleLevelHelpersTests(unittest.TestCase):
    """Smoke-test the module-level convenience wrappers via subprocess.

    Running them in-process would tear down the test runner because they
    call ``sys.exit``; running through ``python -c`` gives us actual
    process exit codes to assert on.
    """

    def _run(self, code: str, *, stdin: str = "") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-c", code],
            input=stdin,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

    def test_module_exit_ok(self) -> None:
        result = self._run("from core_harness.hooks import exit_ok; exit_ok()")
        self.assertEqual(result.returncode, ALLOW_EXIT_CODE)

    def test_module_exit_with_block(self) -> None:
        result = self._run(
            "from core_harness.hooks import exit_with_block; exit_with_block('boom')"
        )
        self.assertEqual(result.returncode, BLOCK_EXIT_CODE)
        self.assertIn("boom", result.stderr)
        self.assertIn(DEFAULT_BLOCK_PREFIX, result.stderr)

    def test_module_parse_undecodable_stdin_blocks(self) -> None:
        # A decode error used to escape as a traceback (exit 1), which
        # Claude Code treats as a non-blocking error: fail-open.
        result = subprocess.run(
            [sys.executable, "-c",
             "from core_harness.hooks import parse_pretooluse_stdin; parse_pretooluse_stdin()"],
            input=b'{"tool_input":{"command":"\xff"}}',
            capture_output=True,
            timeout=15,
            check=False,
            env={**os.environ, "PYTHONIOENCODING": "utf-8"},
        )
        self.assertEqual(result.returncode, BLOCK_EXIT_CODE)

    def test_module_parse_empty_stdin_blocks(self) -> None:
        result = self._run(
            "from core_harness.hooks import parse_pretooluse_stdin; parse_pretooluse_stdin()"
        )
        self.assertEqual(result.returncode, BLOCK_EXIT_CODE)

    def test_module_parse_then_exit(self) -> None:
        code = (
            "import json, sys\n"
            "from core_harness.hooks import parse_pretooluse_stdin, exit_ok\n"
            "p = parse_pretooluse_stdin()\n"
            "sys.stdout.write(json.dumps(p))\n"
            "exit_ok()\n"
        )
        payload = {"tool_name": "Bash", "tool_input": {"command": "ls"}}
        result = self._run(code, stdin=json.dumps(payload))
        self.assertEqual(result.returncode, ALLOW_EXIT_CODE)
        self.assertEqual(json.loads(result.stdout), payload)


class PublicSurfaceTests(unittest.TestCase):
    def test_public_symbols_exposed(self) -> None:
        for name in (
            "ALLOW_EXIT_CODE",
            "BLOCK_EXIT_CODE",
            "DEFAULT_BLOCK_PREFIX",
            "HookRunner",
            "exit_ok",
            "exit_with_block",
            "lib_path",
            "parse_pretooluse_stdin",
        ):
            self.assertIn(name, hooks.__all__, f"{name} missing from __all__")
            self.assertTrue(hasattr(hooks, name), f"{name} missing from module")


if __name__ == "__main__":
    unittest.main()
