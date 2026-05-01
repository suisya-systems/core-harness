#!/usr/bin/env bash
# Bash-side tests for src/core_harness/audit/lib/journal_append.sh
# (Step D / 0.3.0). Generic-only: no consumer-org event names.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$SCRIPT_DIR/../src/core_harness/audit/lib/journal_append.sh"

if [[ ! -f "$LIB_PATH" ]]; then
  echo "FAIL: lib not found at $LIB_PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed; bash audit tests require jq" >&2
  exit 0
fi

# shellcheck source=../src/core_harness/audit/lib/journal_append.sh
source "$LIB_PATH"

PASS=0
FAIL=0

check() {
  local name="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then
    PASS=$((PASS+1))
    printf '  ok   %s\n' "$name"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL %s\n' "$name" >&2
    ( "$@" ) || true
  fi
}

TMPDIR_AUDIT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_AUDIT"' EXIT

# ----- basic round-trip -----------------------------------------------------

t_basic_append_and_read() {
    local path="$TMPDIR_AUDIT/basic.jsonl"
    journal_append "$path" "ping" k=1 label=hello
    [ -f "$path" ] || return 1
    local line
    line="$(cat "$path")"
    # ts present, event=ping, k="1" (string-typed by --arg), label=hello
    echo "$line" | jq -e '.event == "ping"' >/dev/null || return 1
    echo "$line" | jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null || return 1
    echo "$line" | jq -e '.k == "1"' >/dev/null || return 1
    echo "$line" | jq -e '.label == "hello"' >/dev/null || return 1
}
check "journal_append basic round-trip" t_basic_append_and_read

# ----- JSON escaping: quotes / backslashes -------------------------------

t_quotes_and_backslashes() {
    local path="$TMPDIR_AUDIT/escape.jsonl"
    journal_append "$path" "tricky" \
        quoted='he said "hi"' \
        backslash='a\b\c' \
        mixed='line1
line2'
    local last
    last="$(tail -n1 "$path")"
    echo "$last" | jq -e '.quoted == "he said \"hi\""' >/dev/null || return 1
    echo "$last" | jq -e '.backslash == "a\\b\\c"' >/dev/null || return 1
    # newline embedded in value survives via --arg
    echo "$last" | jq -e '.mixed | contains("line1\nline2")' >/dev/null || return 1
}
check "journal_append handles quotes / backslashes / newlines" t_quotes_and_backslashes

# ----- reserved keys rejected ---------------------------------------------

t_reserved_ts_rejected() {
    local path="$TMPDIR_AUDIT/reserved.jsonl"
    if journal_append "$path" "e" ts=2026-05-02T00:00:00Z 2>/dev/null; then
        return 1
    fi
    # On rejection nothing should have been written.
    [ ! -s "$path" ]
}
check "journal_append rejects reserved key ts" t_reserved_ts_rejected

t_reserved_event_rejected() {
    local path="$TMPDIR_AUDIT/reserved2.jsonl"
    if journal_append "$path" "e" event=other 2>/dev/null; then
        return 1
    fi
    [ ! -s "$path" ]
}
check "journal_append rejects reserved key event" t_reserved_event_rejected

# ----- malformed field syntax -------------------------------------------

t_missing_equals_rejected() {
    local path="$TMPDIR_AUDIT/bad.jsonl"
    if journal_append "$path" "e" no_equals 2>/dev/null; then
        return 1
    fi
}
check "journal_append rejects field without =" t_missing_equals_rejected

# ----- missing args ----------------------------------------------------

t_missing_args_rejected() {
    if journal_append 2>/dev/null; then return 1; fi
    if journal_append /tmp/x 2>/dev/null; then return 1; fi
    return 0
}
check "journal_append rejects missing args" t_missing_args_rejected

# ----- journal_append_raw -----------------------------------------------

t_raw_append() {
    local path="$TMPDIR_AUDIT/raw.jsonl"
    echo '{"ts":"2026-05-02T00:00:00Z","event":"raw","x":42}' \
        | journal_append_raw "$path"
    local line
    line="$(cat "$path")"
    echo "$line" | jq -e '.event == "raw" and .x == 42' >/dev/null || return 1
}
check "journal_append_raw appends pre-encoded line" t_raw_append

# ----- parent dir auto-create ------------------------------------------

t_parent_dir_created() {
    local path="$TMPDIR_AUDIT/deep/sub/path.jsonl"
    journal_append "$path" "e" k=v
    [ -f "$path" ]
}
check "journal_append creates parent directories" t_parent_dir_created

# ----- multi-append accumulates ----------------------------------------

t_multi_append() {
    local path="$TMPDIR_AUDIT/multi.jsonl"
    journal_append "$path" "e" i=1
    journal_append "$path" "e" i=2
    journal_append "$path" "e" i=3
    local n
    n="$(wc -l < "$path")"
    [ "$n" -eq 3 ]
}
check "journal_append accumulates lines" t_multi_append

# ----------------------------------------------------------------------

echo
echo "PASS: $PASS  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
