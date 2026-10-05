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
    ( "$@" ) >&2 || true
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

# ----- payload validation: read_pretooluse_input + accessors (#17) --------

# Left in place on purpose (no cleanup): CI runners are ephemeral.
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/core_harness_hooks_test.XXXXXX")
REPO_SRC="$SCRIPT_DIR/../src"

# show <string>: a one-line, bounded rendering of a test input for
# failure messages (CI log viewers drop very long lines).
show() {
  local s=$1
  if [[ ${#s} -gt 80 ]]; then
    printf '%q...(%s chars)' "${s:0:80}" "${#s}"
  else
    printf '%q' "$s"
  fi
}

# jrun <shell snippet> <payload> [env assignment...]
#   Run the snippet in a fresh bash that has sourced the lib, with the
#   payload on stdin. Sets JRC (exit code), JOUT (stdout), JERR (stderr).
jrun() {
  local snippet=$1 payload=$2
  shift 2
  JRC=0
  JOUT=$(printf '%s' "$payload" | env ${@+"$@"} CORE_HARNESS_BLOCK_PREFIX="Blocked: " \
    "$BASH" -c "source '$LIB_PATH'; $snippet" 2>"$TEST_TMP/err") || JRC=$?
  JERR=$(cat "$TEST_TMP/err")
}

# Payloads every helper must refuse (exit 2). Kept in sync with the
# Python parity table below and with tests/test_hooks.py.
INVALID_PAYLOADS=(
  ""
  $' \n\t '
  "-n"
  "-e"
  '{not json'
  '{"tool_input":'
  '{}x'
  '{}{}'
  $'{"tool_name":"Bash"}\n{"tool_name":"Bash"}'
  '[]'
  '[{"tool_input":{"command":"ls"}}]'
  '"str"'
  '42'
  'null'
  'true'
  '{"tool_input":"git push"}'
  '{"tool_input":["git","push"]}'
  '{"tool_input":1}'
  '{"tool_input":false}'
  # A raw 0x1F byte: invalid JSON that jq 1.6/1.7 accept inside a string.
  $'{"tool_input":{"command":"a\037b"}}'
  # A raw 0x1E (RS) byte: jq 1.6 takes it for a JSON-text-sequence separator.
  $'\036{}'
  $'{}\036'
  $'\036{"tool_input":{"command":"ls"}}'
  # Deeper than every parser's limit (Python recursion, jq 1.6: 256,
  # jq 1.7: 10000): Python used to escape with RecursionError (exit 1).
  "{\"tool_input\":{\"a\":$(printf '%100000s' '' | tr ' ' '[')$(printf '%100000s' '' | tr ' ' ']')}}"
)

ACCESSORS=(read_pretooluse_input read_pretooluse_command read_pretooluse_file_path read_pretooluse_tool_name)

t_invalid_payloads_block() {
  local p f
  for p in "${INVALID_PAYLOADS[@]}"; do
    for f in "${ACCESSORS[@]}"; do
      jrun "$f" "$p"
      if [[ $JRC -ne 2 || "$JERR" != "Blocked: "* || -n "$JOUT" ]]; then
        printf '    %s on %s: rc=%s out=%s err=%q\n' "$f" "$(show "$p")" "$JRC" "$(show "$JOUT")" "$JERR"
        return 1
      fi
    done
  done
}

t_invalid_payloads_block_sigpipe_ignored() {
  # GitHub Actions starts steps with SIGPIPE ignored. jq stops reading a
  # payload early (parse error, nesting-depth limit), so the printf that
  # feeds it then gets EPIPE and, with SIGPIPE ignored, prints "write
  # error: Broken pipe" - which must not displace the deny reason as the
  # first stderr line.
  local p f
  for p in "${INVALID_PAYLOADS[@]}"; do
    for f in "${ACCESSORS[@]}"; do
      jrun "trap '' PIPE; $f" "$p"
      if [[ $JRC -ne 2 || "$JERR" != "Blocked: "* || -n "$JOUT" ]]; then
        printf '    %s on %s: rc=%s out=%s err=%q\n' "$f" "$(show "$p")" "$JRC" "$(show "$JOUT")" "$JERR"
        return 1
      fi
    done
  done
}

t_valid_payloads_allow() {
  jrun 'read_pretooluse_input; echo ok' '{"tool_name":"Bash"}'
  [[ $JRC -eq 0 && "$JOUT" == "ok" ]] || return 1
  jrun 'read_pretooluse_command' '{"tool_name":"Bash"}'
  [[ $JRC -eq 0 && -z "$JOUT" ]] || return 1
  jrun 'read_pretooluse_command' '{"tool_name":"Bash","tool_input":null}'
  [[ $JRC -eq 0 && -z "$JOUT" ]] || return 1
  jrun 'read_pretooluse_tool_name' '{"tool_name":"Bash","tool_input":null}'
  [[ $JRC -eq 0 && "$JOUT" == "Bash" ]] || return 1
  jrun 'read_pretooluse_command' $'\n {"tool_name":"Bash","tool_input":{"command":"ls -la"}} \n'
  [[ $JRC -eq 0 && "$JOUT" == "ls -la" ]] || return 1
  # A command value that looks like an echo option is returned verbatim.
  jrun 'read_pretooluse_command' '{"tool_input":{"command":"-n"}}'
  [[ $JRC -eq 0 && "$JOUT" == "-n" ]] || return 1
  jrun 'read_pretooluse_file_path' '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}'
  [[ $JRC -eq 0 && "$JOUT" == "/tmp/x" ]]
}

t_primed_accessors_share_cache() {
  jrun 'read_pretooluse_input; read_pretooluse_input
        a=$(read_pretooluse_tool_name) || exit 7
        b=$(read_pretooluse_command) || exit 7
        printf "%s|%s" "$a" "$b"' \
    '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
  [[ $JRC -eq 0 && "$JOUT" == "Bash|git status" ]]
}

t_unprimed_second_accessor_blocks() {
  # Without read_pretooluse_input at top level, the first $(...) drains
  # stdin inside its subshell; the second sees nothing and must block
  # rather than return "" (which used to read as "out of scope").
  jrun 'a=$(read_pretooluse_tool_name); b=$(read_pretooluse_command); echo "rc=$? a=$a b=$b"' \
    '{"tool_name":"Bash","tool_input":{"command":"git push"}}'
  [[ $JRC -eq 0 && "$JOUT" == "rc=2 a=Bash b=" && "$JERR" == "Blocked: "* ]]
}

t_unvalidated_cache_is_validated() {
  # Seeds that jq extracts from cleanly, so only validation can block.
  local seed
  for seed in 'null' '{}{}' '"x"'; do
    jrun "__CORE_HARNESS_PRETOOLUSE_INPUT='$seed'; read_pretooluse_command" \
      '{"tool_input":{"command":"ls"}}'
    [[ $JRC -eq 2 ]] || return 1
  done
  # A validation flag inherited from the environment must not skip checks.
  jrun 'read_pretooluse_command' '{"tool_input":"git push"}' \
    __CORE_HARNESS_PRETOOLUSE_VALIDATED=1
  [[ $JRC -eq 2 ]] || return 1
  # A payload cache inherited from the environment must not replace stdin.
  jrun 'read_pretooluse_command' '{"tool_input":{"command":"git push"}}' \
    __CORE_HARNESS_PRETOOLUSE_INPUT='{"tool_input":{"command":"ls"}}'
  [[ $JRC -eq 0 && "$JOUT" == "git push" ]]
}

t_inherited_source_marker_ignored() {
  # An exported marker must not make `source` skip the definitions (every
  # helper would then exit 127: non-blocking, i.e. fail open).
  jrun 'read_pretooluse_command' '{"tool_input":"x"}' __CORE_HARNESS_HOOKS_SH_SOURCED=1
  [[ $JRC -eq 2 && "$JERR" == "Blocked: "* ]] || return 1
  jrun 'split_segments' 'a; b' __CORE_HARNESS_HOOKS_SH_SOURCED=1
  [[ $JRC -eq 0 && "$JOUT" == $'a\n b' ]]
}

t_missing_jq_blocks() {
  # PATH without jq: the helpers must block, not return empty.
  local bindir="$TEST_TMP/nojq"
  mkdir -p "$bindir"
  ln -sf "$(command -v cat)" "$bindir/cat"
  jrun 'read_pretooluse_command' '{"tool_input":{"command":"ls"}}' PATH="$bindir"
  [[ $JRC -eq 2 && "$JERR" == *"jq"* ]]
}

# The hook template from docs/hook-contract.md section 3, extracted
# verbatim, with a deny rule in place of the placeholder comment. It is
# run as written (hook-e.sh) and without `set -e` (hook.sh): the template
# must stay fail-closed even without errexit. PATH_OK holds a python3
# that can import the repo's package.
DOC_PATH="$SCRIPT_DIR/../docs/hook-contract.md"
PY_BIN=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
PATH_OK="$TEST_TMP/py-ok"
mkdir -p "$PATH_OK" "$TEST_TMP/py-broken" "$TEST_TMP/py-none"
printf '#!/bin/sh\nPYTHONPATH="%s" exec "%s" "$@"\n' "$REPO_SRC" "$PY_BIN" > "$PATH_OK/python3"
printf '#!/bin/sh\nexit 1\n' > "$TEST_TMP/py-broken/python3"
chmod +x "$PATH_OK/python3" "$TEST_TMP/py-broken/python3"
write_template_hooks() {
  awk '/^## 3\. /{s=1} s&&/^```bash$/{b=1; next} b&&/^```$/{exit} b' "$DOC_PATH" \
    | sed -e 's/^# … org-specific deny logic …$/case "$cmd" in *"git push"*) block_with_message "no push." ;; esac/' \
    > "$TEST_TMP/hook-e.sh"
  sed -e 's/^set -euo pipefail$/set -uo pipefail/' "$TEST_TMP/hook-e.sh" > "$TEST_TMP/hook.sh"
  grep -q '^set -uo pipefail$' "$TEST_TMP/hook.sh" \
    && grep -q 'block_with_message "no push."' "$TEST_TMP/hook.sh"
}

# hook_rc <PATH> <payload>: exit codes of both template hooks, "e/no-e".
hook_rc() {
  local h rc out=""
  for h in hook-e hook; do
    rc=0
    printf '%s' "$2" | PATH="$1" "$BASH" "$TEST_TMP/$h.sh" >/dev/null 2>&1 || rc=$?
    out+="${out:+/}$rc"
  done
  echo "$out"
}

t_template_hook_fail_closed() {
  [[ -n "$PY_BIN" ]] || { echo "    skip: no python3/python on PATH"; return 0; }
  write_template_hooks || { echo "    template not found in $DOC_PATH"; return 1; }
  local p rc ok="$PATH_OK:$PATH"
  for p in "${INVALID_PAYLOADS[@]}"; do
    rc=$(hook_rc "$ok" "$p")
    if [[ $rc != 2/2 ]]; then printf '    template allowed %s (rc=%s)\n' "$(show "$p")" "$rc"; return 1; fi
  done
  [[ $(hook_rc "$ok" '{"tool_name":"Bash","tool_input":{"command":"git push"}}') == 2/2 ]] || return 1
  [[ $(hook_rc "$ok" '{"tool_name":"Bash","tool_input":{"command":"ls"}}') == 0/0 ]] || return 1
  [[ $(hook_rc "$ok" '{"tool_name":"Read","tool_input":{"file_path":"/x"}}') == 0/0 ]] || return 1
  # The library cannot be resolved: python3 fails, or is not on PATH.
  [[ $(hook_rc "$TEST_TMP/py-broken:$PATH" '{"tool_input":{"command":"ls"}}') == 2/2 ]] || return 1
  [[ $(hook_rc "$TEST_TMP/py-none" '{"tool_input":{"command":"ls"}}') == 2/2 ]]
}

# Python and bash must reach the same allow/block verdict on every payload.
PARITY_EXTRA_VALID=(
  '{}'
  '{"tool_name":"Bash"}'
  '{"tool_name":"Bash","tool_input":null}'
  '{"tool_name":"Bash","tool_input":{}}'
  $'  {"tool_name":"Bash","tool_input":{"command":"ls"}}\n'
  '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x","old_string":"a"}}'
)

t_python_bash_parity() {
  local p py_rc sh_rc
  if [[ -z "$PY_BIN" ]]; then echo "    skip: no python3/python on PATH"; return 0; fi
  for p in "${INVALID_PAYLOADS[@]}" "${PARITY_EXTRA_VALID[@]}"; do
    py_rc=0
    printf '%s' "$p" | PYTHONPATH="$REPO_SRC${PYTHONPATH:+:$PYTHONPATH}" "$PY_BIN" -c \
      'from core_harness.hooks import parse_pretooluse_stdin; parse_pretooluse_stdin()' \
      >/dev/null 2>&1 || py_rc=$?
    jrun 'read_pretooluse_input' "$p"
    sh_rc=$JRC
    if [[ $py_rc -ne $sh_rc || ( $sh_rc -ne 0 && $sh_rc -ne 2 ) ]]; then
      printf '    parity mismatch on %s: python=%s bash=%s\n' "$(show "$p")" "$py_rc" "$sh_rc"
      return 1
    fi
  done
  # Sanity: the table really contains both verdicts.
  jrun 'read_pretooluse_input' '{}'; [[ $JRC -eq 0 ]]
}

# ----- split_segments vs. real bash (#18) ----------------------------------

SOH=$(printf '\001')

# split_to_array <command>: fill SEGS with split_segments' segments, using
# an unambiguous separator so multi-line segments stay whole.
split_to_array() {
  SEGS=()
  local s
  while IFS= read -r -d "$SOH" s; do SEGS+=("$s"); done < <(
    printf '%s' "$1" | __CORE_HARNESS_SPLIT_ORS="$SOH" split_segments)
}

# Oracle: run <command> in a child bash in which `m` is a no-op command
# and a DEBUG trap records the marker of every top-level simple command
# "m M<k> ..." bash executes. The DEBUG trap is not inherited by command
# substitutions or subshells (no `set -T`), so only commands that bash
# itself treats as separate top-level commands (including pipeline
# elements and & background jobs) are recorded. Run twice, with m
# returning true then false, so both sides of && / || are seen.
ORACLE_PRELUDE='__rec() {
  case $BASH_COMMAND in
    "m M"*) __x=${BASH_COMMAND#m }; printf "%s\n" "${__x%%[!M0-9]*}" >&3 ;;
  esac
}
m() { return $MRC; }
trap __rec DEBUG
'

# Generated commands may contain redirections: run them in a scratch
# directory so they can never create files in the caller's cwd.
ORACLE_CWD="$TEST_TMP/oracle-cwd"
mkdir -p "$ORACLE_CWD"
oracle_heads() {
  local script=$1
  (
    cd "$ORACLE_CWD" || exit 1
    PATH=/usr/bin:/bin MRC=0 "$BASH" -c "$ORACLE_PRELUDE$script" 3>&1 >/dev/null 2>&1 </dev/null || true
    PATH=/usr/bin:/bin MRC=1 "$BASH" -c "$ORACLE_PRELUDE$script" 3>&1 >/dev/null 2>&1 </dev/null || true
  ) | sort -u | tr '\n' ' ' | sed 's/ $//'
}

ORACLE_OK=0
if [[ ${BASH_VERSINFO[0]} -ge 4 ]]; then ORACLE_OK=1; fi

# seg_head_check <command> <heads>: every marker in <heads> (space
# separated) must start its own segment, i.e. bash's command boundary
# before it was found by split_segments.
seg_head_check() {
  local script=$1 heads=$2 h s found stripped
  split_to_array "$script"
  for h in $heads; do
    found=0
    for s in ${SEGS[@]+"${SEGS[@]}"}; do
      stripped=${s#"${s%%[![:space:]]*}"}
      # A redirection or `time -p` may precede the command word (the
      # fuzz alphabet has only these prefixes).
      while [[ "$stripped" == "<<E"* || "$stripped" == "time -p "* ]]; do
        stripped=${stripped#<<E}
        stripped=${stripped#time -p }
        stripped=${stripped#"${stripped%%[![:space:]]*}"}
      done
      case "$stripped" in
        "m $h"|"m $h"[!0-9]*) found=1; break ;;
      esac
    done
    if [[ $found -eq 0 ]]; then
      printf '    hidden boundary before %s in %q\n' "$h" "$script"
      printf '      segment: %q\n' ${SEGS[@]+"${SEGS[@]}"}
      return 1
    fi
  done
}

# oc <expected heads> <command>: bash runs exactly <expected heads> as
# separate top-level commands (checked against the oracle when the
# running bash is >= 4), and split_segments separates each of them.
ORACLE_FAILS=0
oc() {
  local expected=$1 script=$2 got
  if [[ $ORACLE_OK -eq 1 ]]; then
    got=$(oracle_heads "$script")
    if [[ "$got" != "$expected" ]]; then
      printf '    oracle mismatch for %q: bash ran [%s], table says [%s]\n' "$script" "$got" "$expected"
      ORACLE_FAILS=$((ORACLE_FAILS+1)); return 1
    fi
  fi
  seg_head_check "$script" "$expected" || { ORACLE_FAILS=$((ORACLE_FAILS+1)); return 1; }
}

t_oracle_self_check() {
  [[ "$(oracle_heads 'm M1; m M2')" == "M1 M2" ]] || return 1
  [[ "$(oracle_heads 'm M1 | m M2')" == "M1 M2" ]] || return 1
  [[ "$(oracle_heads 'm M1 & m M2')" == "M1 M2" ]] || return 1
  [[ "$(oracle_heads 'm M1 && m M2 || m M3')" == "M1 M2 M3" ]] || return 1
  [[ "$(oracle_heads 'm M1 $(m M2) `m M3`')" == "M1" ]] || return 1
  [[ "$(oracle_heads 'm M1 \; m M2')" == "M1" ]]
}

t_split_vs_bash_adversarial() {
  ORACLE_FAILS=0
  # Escaped separators and quotes outside quotes.
  oc "M1 M2" 'm M1 \"; m M2'
  oc "M1 M2" "m M1 \\'; m M2"
  oc "M1 M2" 'm M1 \\; m M2'
  oc "M1"    'm M1 \; m M2'
  oc "M1"    'm M1 \| m M2'
  oc "M1"    'm M1 \&\& m M2'
  oc "M1"    'm M1 \&\& m M2 \|\| m M3'
  # Double quotes.
  oc "M1"    'm M1 "a\"; m M2"'
  oc "M1 M2" 'm M1 "a\\"; m M2'
  oc "M1 M2" 'm M1 "\$(" ; m M2'
  oc "M1 M2" 'm M1 "a\`"; m M2'
  # Single quotes: backslash is literal, the quote closes.
  oc "M1 M2" "m M1 'a\\'; m M2"
  # ANSI-C quoting: backslash escapes the quote.
  oc "M1"    "m M1 \$'a\\'; m M2'"
  oc "M1 M2" "m M1 \$'a\\\\'; m M2"
  # Backticks.
  oc "M1 M2" 'm M1 `echo \``; m M2'
  oc "M1 M2" 'm M1 `echo ";"`; m M2'
  # Command substitution.
  oc "M1 M2" 'm M1 $(echo \)); m M2'
  oc "M1 M2" 'm M1 "$(echo ")")"; m M2'
  oc "M1 M2" 'm M1 $(echo "a;b"); m M2'
  oc "M1 M2" 'm M1 "$(echo "$(echo ";")")"; m M2'
  oc "M1 M2" 'm M1 $(echo "$(echo \")"); m M2'
  oc "M1 M2" 'm M1 $((1+2)); m M2'
  oc "M1 M2" 'm M1 $(( (1+2) * 3 )); m M2'
  oc "M1 M2" "m M1 \"\$(case x in x) echo \"'\";; esac)\"; m M2 '\\'"
  # Parameter expansion has its own quoting inside double quotes.
  oc "M1 M2" "m M1 \"\${x:-'\"'}\"; m M2 '\\'"
  oc "M1 M2" 'm M1 ${x:-"a;b"}; m M2'
  # Line continuation and trailing backslash.
  oc "M1 M2" $'m M1 \\\nM1b; m M2'
  oc "M1 M2" $'m M1 "a\\\nb"; m M2'
  oc "M1"    'm M1 \'
  oc "M1 M2" 'm M1; m M2 \'
  # Background, pipes and redirections.
  oc "M1 M2" 'm M1 & m M2'
  oc "M1 M2" 'm M1&m M2'
  oc "M1 M2" 'm M1 |& m M2'
  oc "M1 M2" 'm M1 >&2 & m M2'
  oc "M1 M2" 'm M1 \>& m M2'
  oc "M1 M2" $'m M1\nm M2'
  # Comments: quotes inside a comment must not swallow the next line.
  oc "M1 M2" $'m M1 # it\'s\nm M2'
  oc "M1 M2" $'m M1 # it\'s\nm M2 \\\''
  oc "M1 M2" $'m M1 #"\nm M2 "a;b"'
  oc "M1"    'm M1 a#b; m2'
  # Here-documents: the body is data, its quotes do not count.
  oc "M1 M2" $'m M1 <<\'E\'\n"\'`\nE\nm M2'
  oc "M1 M2" $'m M1 <<-E\n\t\'\n\tE\nm M2'
  oc "M1 M2" $'m M1 <<\'E\'\n\'\nE\nm M2 \\\''
  oc "M1 M2" $'m M1 "$(cat <<\'EOF\'\ndon\'t; stop\nEOF\n)"; m M2'
  oc "M2"    $'((x=1<<2))\nm M2\n2'
  oc "M1 M2" $'m M1 $((1<<2))\nm M2\n2'
  oc "M1 M2" $'m M1 $[1<<2]\n2]\nm M2'
  oc "M1 M2" $'a[1<<2]=5; m M1\n2\nm M2'
  oc "M2"    $'x=1 a[1<<2]=3\nm M2\n2]=3'
  oc "M1 M2" $'m M1 a[1<<2]=5\n2]=5\nm M2'
  oc "M2"    $'cat <<$\'E\'\n\'\nE\nm M2'
  oc "M1"    $'m M1 <<E\n\'\nm M2'
  # Each escape rule, with an input whose wrong parse stays balanced (so
  # the fallback cannot mask a regression).
  oc "M1 M2" 'm M1 "a\" b" ; m M2 \"'
  oc "M1 M2" "m M1 'a\\' ; m M2 'b\\'"
  oc "M1 M2" "m M1 \$'a\\'' ; m M2 \\'"
  oc "M1 M2" 'm M1 `echo \``; m M2 \`'
  # Quotes inside $( ) and backticks inside "..." are their own contexts
  # (again with inputs whose wrong parse stays balanced).
  oc "M1 M2" $'m M1 $(echo ")"\'"\'); m M2 \'"\' # "'
  oc "M1 M2" $'m M1 $(echo \')\'"\'"); m M2 "\'" # \''
  oc "M1 M2" $'m M1 "`echo \'"\'`"; m M2 \'"\' # "'
  # Posix mode: a single quote inside "${ }" is literal (fallback).
  oc "M1 M2" $'set -o posix\nm M1 "${a:-\'}"; m M2; m "\'}"'
  # The fallback also splits the continuation-joined text.
  oc "M2"    $'x=$(case a in a) :;; esac); m \\\nM2 x'
  # Line continuation inside multi-character tokens.
  oc "M1 M2" $'m M1 "$\\\n(m X \'"\')"; m M2 \\\''
  oc "M1 M2" $'m M1 "$\\\n{x:-\'"\'}"; m M2 \\\''
  oc "M1 M2" $'m M1 <\\\n<E\n\'\nE\nm M2 \\\''
  oc "M1 M2" $'m M1 $\\\n\'a\\\'\'; m M2 \\\''
  oc "M1 M2" $'m M1 <<E\\\nX\n\'\nEX\nm M2 \\\''
  # Unquoted here-document delimiter: a body line ending in \ joins the next.
  oc "M1 M2" $'m M1 <<E\nx\\\nE\n\'\nE\nm M2 \\\''
  oc "M1 M2" $'m M1 <<-E\n\tx\\\n\tE\n\'\nE\nm M2 \\\''
  # $(( / (( that bash re-parses as $( ( ... ) ) / ( ( ... ) ) (the
  # oracle does not see commands inside the subshells, only M2).
  oc "M1 M2" $'m M1 "$((m X) \'"\')"; m M2 \\\''
  oc "M2"    $'((m M1) <<E\n\'\nE\n); m M2 \\\''
  oc "M2"    $'((m M1) <<E\n\'\nE\n)\nm M2 \\\''
  oc "M2"    $'((m M1)) && ((m M3) <<E\n\'\nE\n)\nm M2 \\\''
  oc "M2"    $'if ((m M1) <<E\n\'\nE\n)\nthen\nm M2 \\\'; fi'
  # # inside (( )) is not a comment.
  oc "M2"    '((x= #1)); m M2'
  oc "M2"    'for ((i=0; i<1; i++ #x)); do :; done; m M2'
  oc "M1"    '((#x)); m M1'
  oc "M1"    '((#x))&m M1'
  # Single quotes inside ${ } are their own context.
  oc "M1 M2" "m M1 \${x:-'}'} ; m M2 \\'"
  # The word after for is a name, not an a[...]= subscript.
  oc "M3"    'for x[; do :; done; m M3 # ]'
  oc "M3"    $'for x[\ndo :; done\nm M3 #]'
  # time -p / time -- keep (( in command position (arithmetic, not <<).
  oc "M2 M3" $'time -p ((x=1<<2)) ; m M3\nm M2\n2'
  oc "M2 M3" $'time -p -- ((x=1<<2)) ; m M3\nm M2\n2'
  # Here-document delimiters: quote removal as bash does it, or fallback.
  oc "M1 M2" $'m M1 <<"E\\x"\nE\\x\nm M2\nEx\n'
  oc "M1 M2" $'m M1 <<E"\\a"\nE\\a\nm M2\nEa'
  oc "M1 M2" $'m M1 <<"E\\$"\nE$\nm M2\nE\\$'
  oc "M1 M2" $'m M1 <<$\'E\\x41\'\nEA\nm M2\nE\\x41'
  oc "M1 M2" $'m M1 <<$(x)\n$(x)\nm M2\n$\n'
  oc "M1 M2" $'m M1 <<E$(x)\nE$(x)\nm M2\nE$'
  oc "M1 M2" $'m M1 <<`a b`\n`a b`\nm M2\n`a'
  oc "M1 M2" $'m M1 <<${a b}\n${a b}\nm M2\n${a'
  # A here-document opened inside $( ) while an outer one is pending.
  oc "M1 M2 M3 M4" $'m M1 <<E $(cat <<F\nF\n)\nE\nm M2; m M3\nm M4 $(cat <<F\nF\n)'
  # coproc [NAME] (( ... << ... )): arithmetic, not a here-document.
  oc "M1 M2 M3" $'m M1; coproc ((x=1<<2))\nm M2; m M3\n2'
  oc "M1 M2 M3" $'m M1; coproc C ((x=1<<2))\nm M2; m M3\n2'
  [[ $ORACLE_FAILS -eq 0 ]]
}

t_split_heredoc_in_substitution_same_line() {
  # The body of a here-document opened and closed inside $( ) on one line
  # is read differently by bash 5.1 (dropped) and 5.2 (next lines): the
  # oracle is version dependent, so check that both markers split.
  seg_head_check $'m M1 $(cat <<EOF)\nm M2\nEOF\n' "M1 M2"
}

t_split_case_in_substitution() {
  # bash >= 5.2 runs both (5.1 rejects the input), so check the split
  # only: `for case` must not be taken for a case statement inside $( ).
  seg_head_check 'm M1 $(for case in a; do :; done); m M2; time -p case x in x) :;; esac; time -p case y in y) :;; esac' "M1 M2" || return 1
  seg_head_check 'm M1 $(for case in a; do :; done); m M2; case y in y) for esac in b; do for esac in c; do :; done; done;; z) :;; esac' "M1 M2"
}

t_split_pipe_ampersand_exact() {
  local got
  got=$(printf '%s' 'a |& b' | split_segments | tr '\n' '|')
  [[ "$got" == "a | b|" ]]
}

t_split_redirection_ampersand_not_separator() {
  local got
  got=$(printf '%s' 'echo M1 >&2' | split_segments)
  [[ "$got" == 'echo M1 >&2' ]] || return 1
  got=$(printf '%s' 'echo M1 &>/dev/null' | split_segments)
  [[ "$got" == 'echo M1 &>/dev/null' ]] || return 1
  got=$(printf '%s' 'echo M1 &>>log 2>&1 <&0' | split_segments)
  [[ "$got" == 'echo M1 &>>log 2>&1 <&0' ]]
}

t_split_line_continuation_removed() {
  local got
  got=$(printf 'echo a \\\nb; c' | split_segments | tr '\n' '|')
  [[ "$got" == "echo a b| c|" ]]
}

t_split_trailing_backslash_kept() {
  local got
  got=$(printf '%s' 'echo a\' | split_segments)
  [[ "$got" == 'echo a\' ]]
}

t_split_unbalanced_falls_back() {
  # Unterminated quote: bash would reject it, but split everything anyway.
  local got
  got=$(printf '%s' 'echo "a; git push' | split_segments | tr '\n' '|')
  [[ "$got" == 'echo "a| git push|' ]]
}

t_split_existing_format_kept() {
  # Consecutive separators still yield an empty segment, as before.
  local got
  got=$(printf '%s' 'a;;b' | split_segments | tr '\n' '|')
  [[ "$got" == "a||b|" ]] || return 1
  got=$(printf 'a\n\nb\n' | split_segments | tr '\n' '|')
  [[ "$got" == "a||b|" ]] || return 1
  got=$(printf '%s' 'git commit -m "line1
line2" && git push' | split_segments | tr '\n' '|')
  [[ "$got" == 'git commit -m "line1|line2" | git push|' ]]
}

t_split_heredoc_commit_message_whole() {
  # The common `git commit -m "$(cat <<'EOF' ... EOF)"` form stays one
  # segment: separators and quotes in the message body are data.
  local cmd got want
  cmd=$'git commit -m "$(cat <<\'EOF\'\nfix: don\'t push; really | ok\nEOF\n)" && git push'
  got=$(printf '%s' "$cmd" | __CORE_HARNESS_SPLIT_ORS="$SOH" split_segments | tr '\001' '|')
  want=$'git commit -m "$(cat <<\'EOF\'\nfix: don\'t push; really | ok\nEOF\n)" | git push|'
  [[ "$got" == "$want" ]]
}

# Deterministic mini-fuzz: random token strings that bash accepts must
# never hide a command boundary. Uses its own LCG so the corpus is the
# same on every bash version.
FUZZ_TOKENS=( "m M" "m M" "m M" " " " " " " ";" ";" "&&" "||" "|" "&" "\\" "\"" "'" "\$'" "\`" "\$(" ")" $'\n' "a" "\${x:-" "}" "#" "<<E" $'\nE\n' "\$((" "((" "\$" "<" "x\\" $'\\\n' "for case in a; do :; done" "for x[" "time -p " "case x in x) " ";;" " esac" )
t_split_fuzz_vs_bash() {
  local seed=42 iter len k tok script marker accepted=0 heads
  for ((iter = 0; iter < 2000; iter++)); do
    script=""; marker=0
    seed=$(( (seed * 1103515245 + 12345) % 2147483648 ))
    len=$(( 2 + (seed / 65536) % 9 ))
    for ((k = 0; k < len; k++)); do
      seed=$(( (seed * 1103515245 + 12345) % 2147483648 ))
      tok=${FUZZ_TOKENS[$(( (seed / 65536) % ${#FUZZ_TOKENS[@]} ))]}
      if [[ "$tok" == "m M" ]]; then marker=$((marker+1)); tok="m M$marker "; fi
      script+=$tok
    done
    "$BASH" -n -c "$script" >/dev/null 2>&1 || continue
    accepted=$((accepted+1))
    heads=$(oracle_heads "$script")
    seg_head_check "$script" "$heads" || return 1
  done
  printf "    fuzz: %s bash-accepted inputs checked\n" "$accepted" >&2
  [[ $accepted -ge 200 ]]
}

# ---------------------------------------------------------------------------

echo "running core_harness_hooks.sh tests"
# Tool versions, for reading CI failures.
printf '  bash %s | %s | awk: %s\n' "$BASH_VERSION" "$(jq --version 2>&1)" \
  "$(awk --version 2>/dev/null | head -n 1 || true)"
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
check "invalid payloads block in every accessor"   t_invalid_payloads_block
check "invalid payloads block with SIGPIPE ignored" t_invalid_payloads_block_sigpipe_ignored
check "valid payloads allow"                       t_valid_payloads_allow
check "primed accessors share the cache"           t_primed_accessors_share_cache
check "unprimed second accessor blocks"            t_unprimed_second_accessor_blocks
check "unvalidated cache / inherited flag checked" t_unvalidated_cache_is_validated
check "inherited source marker ignored"            t_inherited_source_marker_ignored
check "missing jq blocks"                          t_missing_jq_blocks
check "contract template hook fails closed"        t_template_hook_fail_closed
check "python/bash payload verdict parity"         t_python_bash_parity
SKIP=0
# check_oracle <name> <fn>: the oracle relies on bash >= 4 DEBUG-trap
# behaviour (macOS /bin/bash is 3.2); report the skip instead of passing.
check_oracle() {
  if [[ $ORACLE_OK -eq 1 ]]; then check "$@"; return; fi
  SKIP=$((SKIP+1))
  printf '  skip %s (bash %s < 4: no real-bash oracle)\n' "$1" "$BASH_VERSION"
}
check_oracle "split_segments oracle self-check"    t_oracle_self_check
check "split_segments matches bash (adversarial)"  t_split_vs_bash_adversarial
check "split_segments case word in substitution"  t_split_case_in_substitution
check "split_segments heredoc closed in \$( )"     t_split_heredoc_in_substitution_same_line
check "split_segments |& output exact"             t_split_pipe_ampersand_exact
check "split_segments redirection & kept"          t_split_redirection_ampersand_not_separator
check "split_segments line continuation"           t_split_line_continuation_removed
check "split_segments trailing backslash"          t_split_trailing_backslash_kept
check "split_segments unbalanced fallback"         t_split_unbalanced_falls_back
check "split_segments output format kept"          t_split_existing_format_kept
check "split_segments heredoc commit message"      t_split_heredoc_commit_message_whole
check_oracle "split_segments fuzz vs bash"         t_split_fuzz_vs_bash

echo
echo "passed: $PASS"
echo "failed: $FAIL"
echo "skipped: $SKIP"

if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
exit 0
