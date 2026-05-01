"""Tests for ``core_harness.audit`` — Step D / 0.3.0.

No consumer-org fixtures: the audit module is a generic primitive, so
tests use synthetic event names / payloads only.
"""

from __future__ import annotations

import json
import threading
import warnings
from pathlib import Path

import pytest

from core_harness.audit import (
    Journal,
    JournalError,
    JournalLockError,
    JournalReadError,
    append_event,
    iter_events,
)


# ----------------------------------------------------------------------
# Round-trip: append -> iter
# ----------------------------------------------------------------------


def test_append_then_iter_round_trip(tmp_path: Path) -> None:
    j = Journal(tmp_path / "journal.jsonl")
    j.append("alpha", k=1, label="hello")
    j.append("beta", payload={"nested": True})

    events = list(j.iter_events())
    assert len(events) == 2
    assert events[0]["event"] == "alpha"
    assert events[0]["k"] == 1
    assert events[0]["label"] == "hello"
    assert "ts" in events[0]
    assert events[1]["event"] == "beta"
    assert events[1]["payload"] == {"nested": True}


def test_ts_format_is_iso_utc(tmp_path: Path) -> None:
    j = Journal(tmp_path / "journal.jsonl")
    j.append("e")
    [event] = list(j.iter_events())
    ts = event["ts"]
    # YYYY-MM-DDTHH:MM:SSZ
    assert len(ts) == 20
    assert ts.endswith("Z")
    assert ts[4] == "-" and ts[7] == "-" and ts[10] == "T"


def test_iter_on_missing_file_returns_empty(tmp_path: Path) -> None:
    j = Journal(tmp_path / "nope.jsonl")
    assert list(j.iter_events()) == []


def test_append_creates_parent_directory(tmp_path: Path) -> None:
    target = tmp_path / "deeply" / "nested" / "journal.jsonl"
    j = Journal(target)
    j.append("x")
    assert target.exists()


# ----------------------------------------------------------------------
# Reserved keys
# ----------------------------------------------------------------------


@pytest.mark.parametrize("reserved", ["ts", "event"])
def test_reserved_keys_rejected(tmp_path: Path, reserved: str) -> None:
    j = Journal(tmp_path / "j.jsonl")
    with pytest.raises(ValueError):
        j.append("e", **{reserved: "nope"})


def test_empty_event_rejected(tmp_path: Path) -> None:
    j = Journal(tmp_path / "j.jsonl")
    with pytest.raises(ValueError):
        j.append("")


# ----------------------------------------------------------------------
# tail
# ----------------------------------------------------------------------


def test_tail_returns_last_n(tmp_path: Path) -> None:
    j = Journal(tmp_path / "j.jsonl")
    for i in range(5):
        j.append("e", i=i)
    last3 = j.tail(3)
    assert [e["i"] for e in last3] == [2, 3, 4]


def test_tail_zero_is_empty(tmp_path: Path) -> None:
    j = Journal(tmp_path / "j.jsonl")
    j.append("e")
    assert j.tail(0) == []


def test_tail_more_than_total(tmp_path: Path) -> None:
    j = Journal(tmp_path / "j.jsonl")
    j.append("e", i=0)
    j.append("e", i=1)
    assert [e["i"] for e in j.tail(10)] == [0, 1]


def test_tail_negative_rejected(tmp_path: Path) -> None:
    j = Journal(tmp_path / "j.jsonl")
    with pytest.raises(ValueError):
        j.tail(-1)


# ----------------------------------------------------------------------
# Filters
# ----------------------------------------------------------------------


def test_iter_events_filter_by_event(tmp_path: Path) -> None:
    j = Journal(tmp_path / "j.jsonl")
    j.append("alpha", i=1)
    j.append("beta", i=2)
    j.append("alpha", i=3)
    alphas = list(j.iter_events(filter_event="alpha"))
    assert [e["i"] for e in alphas] == [1, 3]


def test_iter_events_since(tmp_path: Path) -> None:
    path = tmp_path / "j.jsonl"
    # Hand-craft lines so we control the timestamps.
    path.write_text(
        "\n".join(
            [
                json.dumps({"ts": "2026-05-01T00:00:00Z", "event": "old"}),
                json.dumps({"ts": "2026-05-02T12:00:00Z", "event": "mid"}),
                json.dumps({"ts": "2026-05-03T00:00:00Z", "event": "new"}),
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    j = Journal(path)
    out = list(j.iter_events(since="2026-05-02T00:00:00Z"))
    assert [e["event"] for e in out] == ["mid", "new"]


def test_iter_events_filter_and_since_combined(tmp_path: Path) -> None:
    path = tmp_path / "j.jsonl"
    path.write_text(
        "\n".join(
            [
                json.dumps({"ts": "2026-05-01T00:00:00Z", "event": "alpha"}),
                json.dumps({"ts": "2026-05-02T00:00:00Z", "event": "alpha"}),
                json.dumps({"ts": "2026-05-02T00:00:00Z", "event": "beta"}),
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    out = list(
        Journal(path).iter_events(
            filter_event="alpha", since="2026-05-02T00:00:00Z"
        )
    )
    assert len(out) == 1
    assert out[0]["event"] == "alpha"
    assert out[0]["ts"] == "2026-05-02T00:00:00Z"


# ----------------------------------------------------------------------
# Reader tolerance: blank / malformed lines (the inventory's
# "not-valid-json" contract).
# ----------------------------------------------------------------------


def test_iter_skips_blank_and_malformed_lines(tmp_path: Path) -> None:
    path = tmp_path / "j.jsonl"
    path.write_text(
        "\n".join(
            [
                json.dumps({"ts": "2026-05-01T00:00:00Z", "event": "ok-1"}),
                "",  # blank
                "   ",  # whitespace-only
                "not-valid-json",  # malformed
                "[1,2,3]",  # JSON, but not an object
                json.dumps({"ts": "2026-05-02T00:00:00Z", "event": "ok-2"}),
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        out = list(Journal(path).iter_events())

    assert [e["event"] for e in out] == ["ok-1", "ok-2"]
    # At least one warning each for malformed JSON and non-object line.
    messages = [str(w.message) for w in caught]
    assert any("malformed" in m for m in messages)
    assert any("non-object" in m for m in messages)


# ----------------------------------------------------------------------
# Concurrency: 100 threads all appending the same path round-trip.
# ----------------------------------------------------------------------


def test_concurrent_append_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "j.jsonl"
    j = Journal(path)
    n_threads = 20
    per_thread = 5
    barrier = threading.Barrier(n_threads)

    def worker(tid: int) -> None:
        barrier.wait()
        for i in range(per_thread):
            j.append("ping", tid=tid, i=i)

    threads = [threading.Thread(target=worker, args=(t,)) for t in range(n_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    events = list(j.iter_events())
    assert len(events) == n_threads * per_thread
    seen = {(e["tid"], e["i"]) for e in events}
    assert len(seen) == n_threads * per_thread

    # Sanity: every line is well-formed JSON (no torn writes).
    raw_lines = path.read_text(encoding="utf-8").splitlines()
    assert len(raw_lines) == n_threads * per_thread
    for line in raw_lines:
        json.loads(line)  # raises if torn


# ----------------------------------------------------------------------
# Module-level convenience wrappers.
# ----------------------------------------------------------------------


def test_module_level_append_and_iter(tmp_path: Path) -> None:
    path = tmp_path / "j.jsonl"
    append_event(path, "alpha", k=1)
    append_event(path, "beta", k=2)
    out = list(iter_events(path, filter_event="beta"))
    assert len(out) == 1
    assert out[0]["k"] == 2


# ----------------------------------------------------------------------
# Exception hierarchy.
# ----------------------------------------------------------------------


def test_exception_hierarchy() -> None:
    assert issubclass(JournalLockError, JournalError)
    assert issubclass(JournalReadError, JournalError)


def test_unicode_payload_round_trip(tmp_path: Path) -> None:
    j = Journal(tmp_path / "j.jsonl")
    j.append("e", note="日本語テスト", emoji_off=True)
    [event] = list(j.iter_events())
    assert event["note"] == "日本語テスト"
