#!/usr/bin/env bash
# core_harness audit journal — bash companion library (Step D, 0.3.0).
#
# Layer 1 framework slice. Provides:
#
#   journal_append <path> <event> [k=v ...]
#       Append one JSON line to <path>. ``ts`` (ISO-8601 UTC) and
#       ``event`` are added automatically. Remaining args are treated as
#       string-typed key=value fields. ``ts`` / ``event`` keys in the
#       k=v list are rejected.
#
#   journal_append_raw <path>
#       Read a single pre-encoded JSON line from stdin and append it.
#       Caller is responsible for envelope correctness; this is the
#       escape hatch for non-string field types.
#
# Concurrent-write safety: ``flock`` (util-linux) on systems where it is
# available, falling back to "open in append mode and trust the kernel
# for writes <= PIPE_BUF" otherwise. Consumers who need cross-platform
# concurrency safety should prefer the Python ``Journal.append`` API.
#
# This library deliberately knows nothing about consumer-specific event
# names or payload shapes. The journal file path is supplied by the
# caller (Q4 one-way dependency).

set -o pipefail

# Sentinel so source-guards can detect the library is loaded.
CORE_HARNESS_AUDIT_LIB_LOADED=1

_journal_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        printf 'core_harness.audit: jq is required for journal_append\n' >&2
        return 127
    fi
}

_journal_iso_utc_now() {
    # ``date -u +%FT%TZ`` is portable across GNU coreutils, BSD/macOS
    # date, and Git-for-Windows date. Output: ``YYYY-MM-DDTHH:MM:SSZ``.
    date -u +%FT%TZ
}

_journal_write_locked() {
    local path="$1"
    local dir
    dir="$(dirname -- "$path")"
    [ -d "$dir" ] || mkdir -p -- "$dir"

    if command -v flock >/dev/null 2>&1; then
        # ``flock`` opens the file via fd 9 and serializes appends. We
        # write the line via a here-string read by ``cat`` so the lock
        # stays held until the write completes.
        ( flock 9
          cat >> "$path"
        ) 9>>"$path"
    else
        # Best-effort: ``>>`` in POSIX shell is O_APPEND; concurrent
        # writes <= PIPE_BUF are atomic on Linux. Cross-process safety
        # without flock is not guaranteed — see module docstring.
        cat >> "$path"
    fi
}

# journal_append <path> <event> [k=v ...]
journal_append() {
    if [ "$#" -lt 2 ]; then
        printf 'usage: journal_append <path> <event> [k=v ...]\n' >&2
        return 2
    fi
    _journal_require_jq || return $?

    local path="$1"; shift
    local event="$1"; shift

    if [ -z "$event" ]; then
        printf 'core_harness.audit: event must be non-empty\n' >&2
        return 2
    fi

    local ts
    ts="$(_journal_iso_utc_now)"

    # Build a jq invocation that produces ``{ts, event, ...fields}``.
    # ``--arg`` binds string values safely, dodging shell-quoting bugs
    # in caller-supplied payload values.
    local -a jq_args=(-nc --arg ts "$ts" --arg event "$event")
    local filter='{ts: $ts, event: $event}'

    local pair key val
    for pair in "$@"; do
        case "$pair" in
            *=*)
                key="${pair%%=*}"
                val="${pair#*=}"
                ;;
            *)
                printf 'core_harness.audit: malformed field %q (want key=value)\n' "$pair" >&2
                return 2
                ;;
        esac
        if [ -z "$key" ]; then
            printf 'core_harness.audit: empty field key in %q\n' "$pair" >&2
            return 2
        fi
        case "$key" in
            ts|event)
                printf 'core_harness.audit: reserved key %q cannot appear in fields\n' "$key" >&2
                return 2
                ;;
        esac
        jq_args+=(--arg "$key" "$val")
        filter="$filter + {\"$key\": \$$key}"
    done

    local line
    if ! line="$(jq "${jq_args[@]}" "$filter")"; then
        printf 'core_harness.audit: jq encoding failed\n' >&2
        return 1
    fi

    printf '%s\n' "$line" | _journal_write_locked "$path"
}

# journal_append_raw <path>
# Reads one JSON object (single line) from stdin and appends it verbatim.
journal_append_raw() {
    if [ "$#" -lt 1 ]; then
        printf 'usage: journal_append_raw <path>\n' >&2
        return 2
    fi
    local path="$1"
    _journal_write_locked "$path"
}
