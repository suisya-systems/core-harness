#!/usr/bin/env bash
# Bash-side tests for core_harness_hooks.sh (Step C / 0.2).
#
# Exercises: block_with_message exit code + stderr prefix, JSON
# accessors, and the generic command-string parsers.
#
# Run from any directory. No claude-org fixtures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="$SCRIPT_DIR/../src/core_harness/hooks/lib/core_harness_hooks.sh"

if [[ ! -f "$LIB_PATH" ]]; then
  echo "FAIL: lib not found at $LIB_PATH" >&2
  exit 1
fi

# shellcheck source=../src/core_harness/hooks/lib/core_harness_hooks.sh
source "$LIB_PATH"

PASS=0
FAIL=0

# Each `check` runs the supplied test in a subshell so that
# block_with_message's exit 2 doesn't terminate the runner.
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

# ----- block_with_message ---------------------------------------------------

t_block_exit_code() {
  local rc=0
  ( block_with_message "test reason" ) 2>/dev/null || rc=$?
  [[ $rc -eq 2 ]]
}

t_block_default_prefix() {
  # Layer-1 default is the neutral English "Blocked: ". We force a
  # fresh sub-shell so this test is robust against an inherited
  # CORE_HARNESS_BLOCK_PREFIX from the calling environment.
  local out
  out=$(unset CORE_HARNESS_BLOCK_PREFIX; bash -c "
    source '$LIB_PATH'
    block_with_message 'test reason'
  " 2>&1 || true)
  [[ "$out" == "Blocked: test reason" ]]
}

t_block_legacy_japanese_via_env() {
  # The override path the original consumer (claude-org-ja) uses to
  # keep its existing 380+ hook tests green: export the legacy
  # "ブロック: " prefix before sourcing the lib.
  local out
  out=$( CORE_HARNESS_BLOCK_PREFIX="ブロック: " bash -c "
    source '$LIB_PATH'
    block_with_message 'テスト理由'
  " 2>&1 || true)
  [[ "$out" == "ブロック: テスト理由" ]]
}

t_block_env_prefix() {
  local out
  out=$( CORE_HARNESS_BLOCK_PREFIX="DENY> " bash -c "
    source '$LIB_PATH'
    block_with_message 'oops'
  " 2>&1 || true)
  [[ "$out" == "DENY> oops" ]]
}

# ----- require_dependency ---------------------------------------------------

t_require_dep_present() {
  local rc=0
  ( require_dependency bash ) 2>/dev/null || rc=$?
  [[ $rc -eq 0 ]]
}

t_require_dep_missing() {
  local rc=0
  ( require_dependency __nonexistent_binary_xyz_42 ) 2>/dev/null || rc=$?
  [[ $rc -eq 2 ]]
}

# ----- read_pretooluse_* ----------------------------------------------------

t_read_command() {
  local got
  got=$(printf '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' \
    | ( read_pretooluse_command ) )
  [[ "$got" == "echo hi" ]]
}

t_read_file_path() {
  local got
  got=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}' \
    | ( read_pretooluse_file_path ) )
  [[ "$got" == "/tmp/x" ]]
}

t_read_tool_name() {
  local got
  got=$(printf '{"tool_name":"Bash","tool_input":{}}' \
    | ( read_pretooluse_tool_name ) )
  [[ "$got" == "Bash" ]]
}

t_read_command_missing_field_empty() {
  local got
  got=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}' \
    | ( read_pretooluse_command ) )
  [[ -z "$got" ]]
}

# ----- split_segments -------------------------------------------------------

t_split_simple() {
  local got
  got=$(printf '%s' 'a; b && c | d || e' | split_segments | tr '\n' '|')
  [[ "$got" == "a| b | c | d | e|" ]]
}

t_split_quoted_separators_preserved() {
  # The ; inside double quotes must NOT be a segment break.
  local got
  got=$(printf '%s' 'git commit -m "a ; b" --no-verify' | split_segments | wc -l | tr -d ' ')
  [[ "$got" == "1" ]]
}

t_split_command_substitution_preserved() {
  # The | inside $(...) must NOT be a segment break.
  local got
  got=$(printf '%s' 'echo $(ls | wc -l)' | split_segments | wc -l | tr -d ' ')
  [[ "$got" == "1" ]]
}

# ----- flatten_substitutions -----------------------------------------------

t_flatten_dollar_paren() {
  local got
  got=$(printf '%s' 'git commit $(printf -- "--no-verify") -m x' | flatten_substitutions)
  [[ "$got" == *"--no-verify"* ]]
}

t_flatten_backticks() {
  local got
  got=$(printf '%s' 'git commit `printf -- "--no-verify"` -m x' | flatten_substitutions)
  [[ "$got" == *"--no-verify"* ]]
}

# ----- collect_assignments + expand_known_vars -----------------------------

t_collect_simple_assign() {
  local got
  got=$(printf '%s' 'flag=--no-verify' | collect_assignments)
  [[ "$got" == "flag=--no-verify" ]]
}

t_collect_export_assign() {
  local got
  got=$(printf '%s' 'export FOO=bar' | collect_assignments)
  [[ "$got" == "FOO=bar" ]]
}

t_expand_known_vars() {
  local got
  got=$(printf '%s' 'git commit "$flag"' | expand_known_vars 'flag=--no-verify')
  [[ "$got" == *"--no-verify"* ]]
}

t_expand_word_boundary() {
  # $FOOBAR should not be replaced when only FOO is known.
  local got
  got=$(printf '%s' 'echo $FOOBAR' | expand_known_vars 'FOO=x')
  [[ "$got" == 'echo $FOOBAR' ]]
}

# ----- unwrap_eval_and_bashc -----------------------------------------------

t_unwrap_eval_double_quote() {
  local got
  got=$(printf '%s\n' 'eval "git commit --no-verify"' | unwrap_eval_and_bashc)
  [[ "$got" == *"git commit --no-verify"* ]]
}

t_unwrap_bash_c_single_quote() {
  local got
  got=$(printf '%s\n' "bash -c 'git push --force'" | unwrap_eval_and_bashc)
  [[ "$got" == *"git push --force"* ]]
}

t_unwrap_sh_c() {
  local got
  got=$(printf '%s\n' "sh -c 'rm -rf /'" | unwrap_eval_and_bashc)
  [[ "$got" == *"rm -rf /"* ]]
}

# ---------------------------------------------------------------------------

echo "running core_harness_hooks.sh tests"
check "block_with_message exits 2"                 t_block_exit_code
check "block_with_message default prefix"          t_block_default_prefix
check "block_with_message env prefix override"     t_block_env_prefix
check "block_with_message legacy JP via env"       t_block_legacy_japanese_via_env
check "require_dependency allows present binary"   t_require_dep_present
check "require_dependency blocks missing binary"   t_require_dep_missing
check "read_pretooluse_command"                    t_read_command
check "read_pretooluse_file_path"                  t_read_file_path
check "read_pretooluse_tool_name"                  t_read_tool_name
check "read_pretooluse_command empty when absent"  t_read_command_missing_field_empty
check "split_segments simple"                      t_split_simple
check "split_segments preserves quoted separators" t_split_quoted_separators_preserved
check "split_segments preserves command-sub"       t_split_command_substitution_preserved
check "flatten_substitutions reveals dollar-paren" t_flatten_dollar_paren
check "flatten_substitutions reveals backticks"    t_flatten_backticks
check "collect_assignments simple"                 t_collect_simple_assign
check "collect_assignments export form"            t_collect_export_assign
check "expand_known_vars substitutes"              t_expand_known_vars
check "expand_known_vars respects word boundary"   t_expand_word_boundary
check "unwrap_eval_and_bashc double-quote"         t_unwrap_eval_double_quote
check "unwrap_eval_and_bashc bash -c single"       t_unwrap_bash_c_single_quote
check "unwrap_eval_and_bashc sh -c"                t_unwrap_sh_c

echo
echo "passed: $PASS"
echo "failed: $FAIL"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
