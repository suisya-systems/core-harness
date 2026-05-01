"""Audit / journal primitives — Step D (0.3.0).

Layer 1 framework slice for the append-only JSON-Lines audit journal.
Owns:

- The on-disk wire format (one JSON object per line, ``ts`` + ``event``
  envelope, free payload thereafter).
- Concurrent-write safety (``fcntl.flock`` on POSIX, ``msvcrt.locking``
  on Windows).
- Reader tolerance: blank lines and broken JSON are skipped with a
  ``warnings.warn`` so retros / drift CI can still iterate.

The framework deliberately knows **nothing** about which event types
exist or which fields each event carries. The caller (the consumer
runtime) owns the event-type catalog and per-event field conventions
("Layer 1 owns the *how*, not the *what*").

Path injection follows the Q4 one-way dependency rule: the journal
file path is supplied by the consumer through the ``Journal``
constructor; ``core_harness`` never reads ``CORE_HARNESS_JOURNAL_PATH``
or any other consumer-shaped env var on its own.

See ``docs/journal-contract.md`` for the full specification.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import warnings
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Mapping, Optional


__all__ = [
    "Journal",
    "JournalError",
    "JournalLockError",
    "JournalReadError",
    "append_event",
    "iter_events",
]


_RESERVED_KEYS = ("ts", "event")


class JournalError(Exception):
    """Base class for all :mod:`core_harness.audit` failures."""


class JournalLockError(JournalError):
    """Raised when an exclusive append lock cannot be acquired."""


class JournalReadError(JournalError):
    """Raised when the journal file cannot be opened for reading."""


def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


_PROCESS_LOCKS: "dict[str, threading.Lock]" = {}
_PROCESS_LOCKS_GUARD = threading.Lock()


def _process_lock_for(path: Path) -> threading.Lock:
    key = str(path.resolve())
    with _PROCESS_LOCKS_GUARD:
        lock = _PROCESS_LOCKS.get(key)
        if lock is None:
            lock = threading.Lock()
            _PROCESS_LOCKS[key] = lock
        return lock


if sys.platform == "win32":
    import msvcrt

    def _lock_exclusive(fd: int) -> None:
        retries = 0
        while True:
            try:
                msvcrt.locking(fd, msvcrt.LK_LOCK, 1)
                return
            except OSError:
                retries += 1
                if retries > 10:
                    raise JournalLockError(
                        "could not acquire exclusive lock on journal file"
                    )

    def _unlock(fd: int) -> None:
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        except OSError:
            pass

else:
    import fcntl

    def _lock_exclusive(fd: int) -> None:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError as exc:  # pragma: no cover — defensive
            raise JournalLockError(str(exc)) from exc

    def _unlock(fd: int) -> None:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass


def _encode_line(event: str, fields: Mapping[str, Any]) -> str:
    for reserved in _RESERVED_KEYS:
        if reserved in fields:
            raise ValueError(
                f"reserved key {reserved!r} cannot appear in fields"
            )
    payload = {"ts": _utcnow_iso(), "event": event}
    payload.update(fields)
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def _append_raw(path: Path, line: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    proc_lock = _process_lock_for(path)
    with proc_lock:
        fd = os.open(
            str(path),
            os.O_WRONLY | os.O_CREAT | os.O_APPEND,
            0o644,
        )
        try:
            _lock_exclusive(fd)
            try:
                data = (line + "\n").encode("utf-8")
                view = memoryview(data)
                while view:
                    written = os.write(fd, view)
                    if written <= 0:  # pragma: no cover — defensive
                        raise JournalError("short write to journal")
                    view = view[written:]
            finally:
                _unlock(fd)
        finally:
            os.close(fd)


class Journal:
    """Append-only JSON-Lines journal with concurrent-write safety.

    Each line is a JSON object with two reserved envelope keys:

    * ``ts`` — ISO-8601 UTC (``YYYY-MM-DDTHH:MM:SSZ``), generated at
      append time.
    * ``event`` — caller-supplied event name (free-form string).

    Caller-supplied ``fields`` may not collide with the reserved keys.
    Readers skip blank lines and broken JSON with a :class:`UserWarning`.
    Path injection follows the Q4 one-way dependency rule — the path is
    supplied by the consumer.
    """

    def __init__(self, path: Path) -> None:
        self.path = Path(path)

    def append(self, event, /, **fields: Any) -> None:
        if not isinstance(event, str) or not event:
            raise ValueError("event must be a non-empty string")
        line = _encode_line(event, fields)
        _append_raw(self.path, line)

    def iter_events(
        self,
        filter_event: Optional[str] = None,
        since: Optional[str] = None,
    ) -> Iterator[dict]:
        if not self.path.exists():
            return
        try:
            handle = self.path.open("r", encoding="utf-8")
        except OSError as exc:
            raise JournalReadError(str(exc)) from exc
        with handle as fh:
            for lineno, raw in enumerate(fh, start=1):
                line = raw.rstrip("\n").rstrip("\r")
                if not line.strip():
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    warnings.warn(
                        f"skipping malformed journal line {lineno} in {self.path}",
                        UserWarning,
                        stacklevel=2,
                    )
                    continue
                if not isinstance(obj, dict):
                    warnings.warn(
                        f"skipping non-object journal line {lineno} in {self.path}",
                        UserWarning,
                        stacklevel=2,
                    )
                    continue
                if filter_event is not None and obj.get("event") != filter_event:
                    continue
                if since is not None:
                    ts = obj.get("ts")
                    if not isinstance(ts, str) or ts < since:
                        continue
                yield obj

    def tail(self, n: int) -> "list[dict]":
        if n < 0:
            raise ValueError("n must be non-negative")
        if n == 0:
            return []
        buf: "list[dict]" = []
        for event in self.iter_events():
            buf.append(event)
            if len(buf) > n:
                buf.pop(0)
        return buf


def append_event(path, event, /, **fields: Any) -> None:
    """Convenience: ``Journal(path).append(event, **fields)``."""
    Journal(path).append(event, **fields)


def iter_events(
    path: Path,
    filter_event: Optional[str] = None,
    since: Optional[str] = None,
) -> Iterator[dict]:
    """Convenience: ``Journal(path).iter_events(filter_event, since)``."""
    return Journal(path).iter_events(filter_event=filter_event, since=since)
