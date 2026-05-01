"""Hook framework primitives — Step C (0.2.0).

Layer 1 framework slice for PreToolUse hook wiring. Owns:

- The exit-code / stdin / stderr contract used by hook scripts.
- A small Python helper (``HookRunner`` and module-level functions) so
  Python-implemented hooks don't have to hand-roll ``json.load(sys.stdin)``
  + ``sys.exit`` boilerplate.
- A path-configurable bash companion library shipped under ``hooks/lib/``
  and exposed via :func:`lib_path`. Consumers ``source`` it from their
  org-specific hook scripts.

The framework deliberately knows **nothing** about consumer-specific
concepts: no role names, no path patterns, no consumer-locale string
constants. The default block-message prefix is the neutral English
``"Blocked: "``; consumers that need a different prefix (e.g.
claude-org-ja's ``"ブロック: "`` contract) inject it via the
``CORE_HARNESS_BLOCK_PREFIX`` environment variable or
``HookRunner(block_prefix=...)`` argument. Layer 1 stays unaware of
any specific consumer.

See ``docs/hook-contract.md`` for the full specification.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, IO, Mapping, Optional

DEFAULT_BLOCK_PREFIX = "Blocked: "
"""Default block-message prefix.

Layer-1-neutral English; consumers with org-specific localisation
(e.g. claude-org-ja's legacy ``"ブロック: "`` contract) override this
per-process via ``CORE_HARNESS_BLOCK_PREFIX`` or per-runner via
``HookRunner(block_prefix=...)``. The framework intentionally does not
ship any consumer-specific string as a default.
"""

BLOCK_EXIT_CODE = 2
ALLOW_EXIT_CODE = 0


def _resolve_prefix(explicit: Optional[str]) -> str:
    if explicit is not None:
        return explicit
    env = os.environ.get("CORE_HARNESS_BLOCK_PREFIX")
    if env is not None:
        return env
    return DEFAULT_BLOCK_PREFIX


def lib_path() -> Path:
    """Return the on-disk directory containing the bash companion lib.

    Bash hooks source the lib via::

        source "$(python -c 'import core_harness.hooks; print(core_harness.hooks.lib_path())')/core_harness_hooks.sh"

    The directory contains org-neutral helpers only; consumer-specific
    matching logic lives in the consumer repo.
    """
    return Path(__file__).resolve().parent / "lib"


class HookRunner:
    """Helper for Python-implemented PreToolUse hooks.

    The framework contract is intentionally minimal — three operations:

    - :meth:`parse_pretooluse_stdin` reads and JSON-decodes the hook
      payload Claude Code delivers on stdin.
    - :meth:`exit_with_block` writes ``{prefix}{message}`` to stderr and
      exits ``2``. The prefix defaults to ``"Blocked: "`` (neutral
      English); consumers override via env var or constructor arg.
    - :meth:`exit_ok` exits ``0``.

    Instances are cheap; create one per hook invocation.
    """

    def __init__(
        self,
        *,
        block_prefix: Optional[str] = None,
        stderr: Optional[IO[str]] = None,
        stdin: Optional[IO[str]] = None,
    ) -> None:
        self.block_prefix = _resolve_prefix(block_prefix)
        self._stderr = stderr if stderr is not None else sys.stderr
        self._stdin = stdin if stdin is not None else sys.stdin

    def parse_pretooluse_stdin(self) -> Mapping[str, Any]:
        """Read the PreToolUse JSON payload from stdin.

        Empty stdin is treated as an empty payload (``{}``), matching
        the de-facto contract where hooks receive ``{}`` for tools they
        don't care about and exit 0. Malformed JSON triggers
        :meth:`exit_with_block` so the framework fails closed rather
        than silently allowing through a tool call whose payload it
        couldn't inspect.
        """
        raw = self._stdin.read()
        if not raw or not raw.strip():
            return {}
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError) as exc:
            self.exit_with_block(
                f"Failed to parse PreToolUse JSON: {exc}"
            )
        if not isinstance(payload, dict):
            self.exit_with_block(
                "PreToolUse payload is not a JSON object"
            )
        return payload

    def exit_with_block(self, message: str) -> "Any":
        """Write the deny reason to stderr and exit with code 2.

        Never returns. The annotation is ``Any`` so callers can write
        ``return runner.exit_with_block(...)`` if they prefer.
        """
        self._stderr.write(f"{self.block_prefix}{message}\n")
        try:
            self._stderr.flush()
        except Exception:
            pass
        sys.exit(BLOCK_EXIT_CODE)

    def exit_ok(self) -> "Any":
        """Exit with code 0 (allow). Never returns."""
        sys.exit(ALLOW_EXIT_CODE)


def parse_pretooluse_stdin() -> Mapping[str, Any]:
    """Module-level convenience: ``HookRunner().parse_pretooluse_stdin()``."""
    return HookRunner().parse_pretooluse_stdin()


def exit_with_block(message: str) -> "Any":
    """Module-level convenience: ``HookRunner().exit_with_block(message)``."""
    HookRunner().exit_with_block(message)


def exit_ok() -> "Any":
    """Module-level convenience: ``HookRunner().exit_ok()``."""
    HookRunner().exit_ok()


__all__ = [
    "ALLOW_EXIT_CODE",
    "BLOCK_EXIT_CODE",
    "DEFAULT_BLOCK_PREFIX",
    "HookRunner",
    "exit_ok",
    "exit_with_block",
    "lib_path",
    "parse_pretooluse_stdin",
]
