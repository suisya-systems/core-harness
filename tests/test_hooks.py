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


class ParseStdinTests(unittest.TestCase):
    def _runner(self, raw: str, *, stderr: io.StringIO | None = None) -> HookRunner:
        return HookRunner(
            stdin=io.StringIO(raw),
            stderr=stderr or io.StringIO(),
        )

    def test_empty_stdin_returns_empty_dict(self) -> None:
        self.assertEqual(self._runner("").parse_pretooluse_stdin(), {})

    def test_whitespace_only_returns_empty_dict(self) -> None:
        self.assertEqual(self._runner("   \n\t").parse_pretooluse_stdin(), {})

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
        stderr = io.StringIO()
        runner = HookRunner(stderr=stderr, stdin=io.StringIO(""))
        with self.assertRaises(SystemExit) as cm:
            runner.exit_with_block("test reason")
        self.assertEqual(cm.exception.code, BLOCK_EXIT_CODE)
        self.assertEqual(stderr.getvalue(), f"{DEFAULT_BLOCK_PREFIX}test reason\n")

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
