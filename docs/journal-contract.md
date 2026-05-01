# Journal Contract — `core_harness.audit` (0.3+)

> **Status: experimental (0.3.0).** Signature/semantics may shift before
> 1.0 per [`semver-policy.md`](semver-policy.md). The wire format
> (envelope keys + reader tolerance) is intended to be stable from
> 0.3.0 onward; signature changes will be flagged in `CHANGELOG.md`.

This document specifies the audit-journal primitive that
`core_harness.audit` exposes to consumers. The framework deliberately
owns the *how* (envelope, locking, reader tolerance) and not the
*what* (which event names exist, which payload fields each event
carries). Consumers own their event-type catalog.

---

## 1. Wire format

The journal is a single file containing **one JSON object per line**
(JSON Lines). Each line MUST be a self-contained, single-line JSON
object terminated by `\n`.

### 1.1 Reserved envelope keys

Two keys are reserved by Layer 1 and present on every line written
through `Journal.append` / `journal_append`:

| Key     | Type                              | Source        | Purpose                                  |
|---------|-----------------------------------|---------------|------------------------------------------|
| `ts`    | string, `YYYY-MM-DDTHH:MM:SSZ`    | auto (UTC)    | Append time (ISO-8601, second precision) |
| `event` | string, non-empty                 | caller        | Event name (free-form; consumer-defined) |

Caller-supplied `**fields` MUST NOT contain these keys; the framework
raises `ValueError` (Python) or returns exit code 2 (bash) on
collision.

### 1.2 Payload

After the envelope, any number of caller-supplied keys are appended
in insertion order. The framework places no constraints on payload
shape: nested objects, arrays, unicode strings (`ensure_ascii=False`),
booleans, numbers, and `null` are all permitted.

The bash helper string-types every k=v argument because shell has no
type system; consumers needing typed payload values from bash should
either pre-encode JSON and use `journal_append_raw`, or call the
Python API.

### 1.3 Example line

```json
{"ts":"2026-05-02T12:34:56Z","event":"alpha","k":1,"label":"hello"}
```

---

## 2. Path injection (Q4 one-way dependency)

The journal file path is **supplied by the consumer**. Layer 1 never
reads consumer-shaped environment variables (e.g.
`CORE_HARNESS_JOURNAL_PATH`) on its own; consumers either:

- Instantiate `Journal(Path(...))` explicitly, or
- Call `core_harness.audit.append_event(path, event, **fields)`, or
- Source the bash lib and pass `path` as the first arg to
  `journal_append`.

Parent directories are created on first append.

---

## 3. Concurrent-write safety

- **POSIX**: `fcntl.flock(fd, LOCK_EX)` is held for the duration of
  each line write. The fd is opened with `O_APPEND` so the kernel
  positions writes at end-of-file even if the lock is contended.
- **Windows**: `msvcrt.locking(fd, LK_LOCK, 1)` on a single-byte
  region at offset 0. All appenders contend for the same byte, which
  serializes them.
- **In-process**: a module-level `threading.Lock` keyed by the
  resolved absolute path serializes appenders inside one Python
  interpreter (the OS-level lock alone is not sufficient — multiple
  threads sharing one fd can interleave `os.write` calls).
- **Bash**: when `flock(1)` (util-linux) is available the lib uses it
  via fd 9; otherwise it falls back to `>>` append, which is atomic
  for short writes on Linux but offers no cross-process guarantee on
  other platforms. Consumers needing cross-platform concurrency
  safety from non-Python code should use the Python API.

Test coverage: `tests/test_audit.py::test_concurrent_append_round_trip`
runs 20 threads × 5 appends and asserts no torn writes (every line
parses as JSON, every (tid, i) pair is present exactly once).

---

## 4. Reader tolerance

`Journal.iter_events` and `Journal.tail` skip:

1. Blank lines (`""` or whitespace-only).
2. Lines that fail `json.loads` (e.g. partial writes from a crashed
   producer that did not hold the lock — should be impossible with
   the lock contract above, but tolerated for forward-compat).
3. Lines whose top-level value is not a JSON object (e.g. a stray
   array literal).

Skipped lines emit a `UserWarning` so retros / drift CI can detect
corruption without bringing the read down. This matches the
de-facto contract documented in the consumer-side inventory
(`tests/fixtures/journal-sample.jsonl` intentionally contains a
`not-valid-json` line).

---

## 5. Filters

`Journal.iter_events` accepts two optional filters:

- `filter_event: str | None` — exact match on the `event` field.
- `since: str | None` — lexicographic `>=` comparison on the `ts`
  field. The fixed `YYYY-MM-DDTHH:MM:SSZ` format guarantees that
  string comparison yields the same ordering as datetime comparison.

Filters compose: passing both narrows the result.

`Journal.tail(n)` returns the last `n` valid events in file order
(oldest first). The implementation is a linear scan; journals are
expected to be small (the canonical consumer's journal is ~200 lines
at the time of writing).

---

## 6. Exception hierarchy

```
JournalError
├── JournalLockError    raised when an exclusive append lock cannot
│                       be acquired (Windows retry exhaustion, etc.)
└── JournalReadError    raised when the journal file cannot be
                        opened for reading (permissions, etc.)
```

Catching `JournalError` covers all framework-raised failures.
`ValueError` is used for caller-input violations (reserved-key
collision, empty event name, negative `tail(n)`).

---

## 7. What this primitive does **not** own

- Event-type catalogs (`worker_spawned`, `pr_merged`, …) — these are
  org-specific and live in the consumer repo (e.g. a
  `docs/journal-events.md` on the ja side).
- Per-event field schemas — payload shape per event name is the
  consumer's contract with itself.
- Rotation, archival, or pruning policy — not in scope for 0.x.
- Aggregation / dashboarding — readers (e.g. dashboard servers) live
  in the consumer.

---

## 8. Surface summary

| Symbol                                      | Status       | Where                |
|---------------------------------------------|--------------|----------------------|
| `Journal(path)`                             | experimental | Python               |
| `Journal.append(event, **fields)`           | experimental | Python               |
| `Journal.iter_events(filter_event, since)`  | experimental | Python               |
| `Journal.tail(n)`                           | experimental | Python               |
| `append_event(path, event, **fields)`       | experimental | Python (module-level)|
| `iter_events(path, filter_event, since)`    | experimental | Python (module-level)|
| `JournalError` / `JournalLockError` / `JournalReadError` | experimental | Python  |
| `journal_append <path> <event> [k=v ...]`   | experimental | bash lib             |
| `journal_append_raw <path>`                 | experimental | bash lib             |

See [`api-surface-v0.x.md`](api-surface-v0.x.md) for the consolidated
table.
