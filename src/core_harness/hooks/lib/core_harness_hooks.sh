#!/usr/bin/env bash
# core_harness_hooks.sh — Layer 1 framework slice for bash PreToolUse hooks.
#
# This library is path-configurable: consumers locate it at runtime via
#   python -c 'import core_harness.hooks; print(core_harness.hooks.lib_path())'
# and then `source "$LIB_DIR/core_harness_hooks.sh"`. core-harness ships
# only org-neutral helpers here; consumer-specific deny logic
# (path patterns, role names, repo-specific allowlists) lives in the
# consumer repo and calls into these helpers.
#
# Public API (stable for 0.x):
#   block_with_message <reason>            — stderr prefix + exit 2
#   require_dependency <bin> [bin...]      — fail-closed dep check
#   read_pretooluse_command                — print .tool_input.command from stdin JSON
#   read_pretooluse_file_path              — print .tool_input.file_path from stdin JSON
#   read_pretooluse_tool_name              — print .tool_name from stdin JSON
#   split_segments                         — quote-aware ; && || | NL splitter
#   flatten_substitutions                  — append $(...) / `...` bodies
#   collect_assignments                    — extract VAR=value assignments
#   expand_known_vars VAR=val ...          — substitute $VAR / ${VAR}
#   unwrap_eval_and_bashc                  — pull eval / bash -c / sh -c arguments
#
# The block-message prefix defaults to "ブロック: " for back-compat with
# the original consumer's hook tests; export CORE_HARNESS_BLOCK_PREFIX
# to override (must include any trailing punctuation/space).
#
# Idempotent: safe to source twice in the same shell.

if [[ -n "${__CORE_HARNESS_HOOKS_SH_SOURCED:-}" ]]; then
  return 0 2>/dev/null || true
fi
__CORE_HARNESS_HOOKS_SH_SOURCED=1

: "${CORE_HARNESS_BLOCK_PREFIX:=ブロック: }"

# block_with_message <reason>
#   Print "<prefix><reason>" to stderr and exit 2.
block_with_message() {
  local reason="${1:-}"
  printf '%s%s\n' "${CORE_HARNESS_BLOCK_PREFIX}" "${reason}" >&2
  exit 2
}

# require_dependency <bin> [<bin> ...]
#   Verify every named binary is on PATH; if any is missing, block.
#   This is the framework default for fail-closed dependency checks.
require_dependency() {
  local bin
  for bin in "$@"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      block_with_message "$bin がインストールされていません。セキュリティ Hook の実行に必要です。"
    fi
  done
}

# Internal: read stdin JSON once, cache in a process-scoped temp.
# Hooks that call multiple read_pretooluse_* helpers should use this
# pattern via the public helpers (which all hit the cache).
__core_harness_read_stdin_once() {
  if [[ -z "${__CORE_HARNESS_PRETOOLUSE_INPUT+x}" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      block_with_message "jq がインストールされていません。セキュリティ Hook の実行に必要です。"
    fi
    __CORE_HARNESS_PRETOOLUSE_INPUT=$(cat)
  fi
}

# read_pretooluse_command
#   Print the value of .tool_input.command (Bash tool) or empty.
read_pretooluse_command() {
  __core_harness_read_stdin_once
  printf '%s' "$__CORE_HARNESS_PRETOOLUSE_INPUT" | jq -r '.tool_input.command // empty'
}

# read_pretooluse_file_path
#   Print the value of .tool_input.file_path (Edit/Write tool) or empty.
read_pretooluse_file_path() {
  __core_harness_read_stdin_once
  printf '%s' "$__CORE_HARNESS_PRETOOLUSE_INPUT" | jq -r '.tool_input.file_path // empty'
}

# read_pretooluse_tool_name
#   Print the value of .tool_name or empty.
read_pretooluse_tool_name() {
  __core_harness_read_stdin_once
  printf '%s' "$__CORE_HARNESS_PRETOOLUSE_INPUT" | jq -r '.tool_name // empty'
}

# ---------------------------------------------------------------------------
# Generic Bash command-string parser. Originally claude-org-ja's
# `.hooks/lib/segment-split.sh` — moved here as the framework slice
# because nothing in these helpers is consumer-specific (no role names,
# no path patterns). Bug fixes propagate to all consumers.
# ---------------------------------------------------------------------------

# split_segments
#   Read a Bash command string from stdin; print one segment per line,
#   splitting on ; && || | and unquoted newlines. Honours single/double
#   quotes and $(...) / `...` boundaries.
split_segments() {
  awk '
    BEGIN { in_dq=0; in_sq=0; in_bt=0; paren_depth=0; seg=""; }
    {
      if(NR>1 && in_dq==0 && in_sq==0 && in_bt==0 && paren_depth==0) { print seg; seg=""; }
      else if(NR>1) { seg = seg "\n"; }
      line=$0
      n=length(line)
      i=1
      while(i<=n) {
        c=substr(line,i,1)
        next_c = (i<n) ? substr(line,i+1,1) : ""
        if(in_sq==1) {
          if(c=="\x27"){ in_sq=0 }
          seg=seg c; i++; continue
        }
        if(in_dq==1) {
          if(c=="\""){ in_dq=0; seg=seg c; i++; continue }
          if(c=="$" && next_c=="("){ paren_depth++; seg=seg c; i++; continue }
          if(paren_depth>0) {
            if(c=="(") paren_depth++
            if(c==")") paren_depth--
          }
          seg=seg c; i++; continue
        }
        if(in_bt==1) {
          if(c=="`"){ in_bt=0 }
          seg=seg c; i++; continue
        }
        if(c=="\""){ in_dq=1; seg=seg c; i++; continue }
        if(c=="\x27"){ in_sq=1; seg=seg c; i++; continue }
        if(c=="`"){ in_bt=1; seg=seg c; i++; continue }
        if(c=="$" && next_c=="("){ paren_depth++; seg=seg c; i++; continue }
        if(paren_depth>0) {
          if(c=="(") paren_depth++
          if(c==")") paren_depth--
          seg=seg c; i++; continue
        }
        if(c==";"){ print seg; seg=""; i++; continue }
        if(c=="&" && next_c=="&"){ print seg; seg=""; i+=2; continue }
        if(c=="|" && next_c=="|"){ print seg; seg=""; i+=2; continue }
        if(c=="|"){ print seg; seg=""; i++; continue }
        seg=seg c; i++
      }
    }
    END { if(length(seg)>0) print seg }
  '
}

# flatten_substitutions
#   Read one segment from stdin; print the segment with $(...) and `...`
#   bodies appended (space-separated) so downstream regex matching can
#   see flag tokens hidden behind command substitution. Quote chars in
#   the appended portion are squashed to spaces.
#
#   Limitations: 1-level nesting only; $((arith)) ignored.
flatten_substitutions() {
  awk '
    {
      out = $0
      s = $0
      while (match(s, /\$\([^()]*\)/)) {
        body = substr(s, RSTART+2, RLENGTH-3)
        out = out " " body
        s = substr(s, RSTART+RLENGTH)
      }
      s = $0
      while (match(s, /`[^`]*`/)) {
        body = substr(s, RSTART+1, RLENGTH-2)
        out = out " " body
        s = substr(s, RSTART+RLENGTH)
      }
      gsub(/[\047\042]/, " ", out)
      print out
    }
  '
}

# collect_assignments
#   Read multiple segments from stdin (one per line); print one
#   `VAR=value` line per detected assignment.
#
#   Handles: leading VAR=val, `export VAR=val`, multi-assign chains
#   `A=1 B=2 cmd`, and command-substitution values `VAR=$(cmd)` (body
#   appended for downstream regex).
collect_assignments() {
  awk '
    function emit_assign(var, val,    flat, body, s) {
      flat = val
      s = val
      while (match(s, /\$\([^()]*\)/)) {
        body = substr(s, RSTART+2, RLENGTH-3)
        flat = flat " " body
        s = substr(s, RSTART+RLENGTH)
      }
      s = val
      while (match(s, /`[^`]*`/)) {
        body = substr(s, RSTART+1, RLENGTH-2)
        flat = flat " " body
        s = substr(s, RSTART+RLENGTH)
      }
      gsub(/[\047\042]/, " ", flat)
      print var "=" flat
    }
    {
      seg = $0
      sub(/^[ \t]+/, "", seg)
      if (match(seg, /^export[ \t]+/)) {
        seg = substr(seg, RLENGTH + 1)
        sub(/^[ \t]+/, "", seg)
      }
      while (match(seg, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        var = substr(seg, 1, RLENGTH - 1)
        rest = substr(seg, RLENGTH + 1)
        val = ""; n = length(rest)
        in_dq = 0; in_sq = 0; in_bt = 0; paren_depth = 0; i = 1
        while (i <= n) {
          c = substr(rest, i, 1)
          next_c = (i < n) ? substr(rest, i+1, 1) : ""
          if (in_sq) {
            if (c == "\x27") { in_sq = 0; i++; continue }
            val = val c; i++; continue
          }
          if (in_dq) {
            if (c == "\"") { in_dq = 0; i++; continue }
            if (c == "$" && next_c == "(") { paren_depth++; val = val c; i++; continue }
            if (paren_depth > 0) {
              if (c == "(") paren_depth++
              if (c == ")") paren_depth--
            }
            val = val c; i++; continue
          }
          if (in_bt) {
            if (c == "`") { in_bt = 0 }
            val = val c; i++; continue
          }
          if (c == "\"") { in_dq = 1; i++; continue }
          if (c == "\x27") { in_sq = 1; i++; continue }
          if (c == "`") { in_bt = 1; val = val c; i++; continue }
          if (c == "$" && next_c == "(") { paren_depth++; val = val c; i++; continue }
          if (paren_depth > 0) {
            if (c == "(") paren_depth++
            if (c == ")") paren_depth--
            val = val c; i++; continue
          }
          if (c == " " || c == "\t") break
          val = val c; i++
        }
        if (length(val) > 0) emit_assign(var, val)
        seg = substr(rest, i + 1)
        sub(/^[ \t]+/, "", seg)
      }
    }
  '
}

# unwrap_eval_and_bashc
#   Read segments from stdin; print eval / bash -c / sh -c argument
#   bodies as additional segments (one per line). Up to 2 levels deep.
unwrap_eval_and_bashc() {
  local current next iter
  current=$(cat)
  [[ -z "$current" ]] && return 0
  for iter in 1 2; do
    next=$(printf '%s\n' "$current" | __core_harness_unwrap_pass)
    [[ -z "$next" ]] && break
    printf '%s\n' "$next"
    current="$next"
  done
}

__core_harness_unwrap_pass() {
  awk '
    function emit_body(body) {
      if (length(body) > 0) print body
    }
    {
      line = $0
      while (1) {
        if (match(line, /(^|[^A-Za-z0-9_-])(eval|bash[ \t]+-c|sh[ \t]+-c)[ \t]+"[^"]*"/)) {
          tok = substr(line, RSTART, RLENGTH)
          q = index(tok, "\"")
          emit_body(substr(tok, q+1, length(tok)-q-1))
          line = substr(line, RSTART+RLENGTH)
          continue
        }
        if (match(line, /(^|[^A-Za-z0-9_-])(eval|bash[ \t]+-c|sh[ \t]+-c)[ \t]+\047[^\047]*\047/)) {
          tok = substr(line, RSTART, RLENGTH)
          q = index(tok, "\047")
          emit_body(substr(tok, q+1, length(tok)-q-1))
          line = substr(line, RSTART+RLENGTH)
          continue
        }
        if (match(line, /(^|[^A-Za-z0-9_-])eval[ \t]+[^ \t"\047;&|`][^ \t;&|`]*/)) {
          tok = substr(line, RSTART, RLENGTH)
          eidx = index(tok, "eval")
          if (eidx > 0) {
            after = substr(tok, eidx + 4)
            sub(/^[ \t]+/, "", after)
            emit_body(after)
          }
          line = substr(line, RSTART+RLENGTH)
          continue
        }
        break
      }
    }
  '
}

# expand_known_vars VAR=val [VAR=val ...]
#   Read one segment from stdin; print the segment with $VAR / ${VAR}
#   references replaced by their values. Word-boundary aware so $FOOBAR
#   is not replaced when only FOO is known.
expand_known_vars() {
  local segment
  segment=$(cat)
  local pair var val
  for pair in "$@"; do
    var="${pair%%=*}"
    val="${pair#*=}"
    segment="${segment//\$\{$var\}/$val}"
    segment=$(printf '%s' "$segment" | awk -v v="$var" -v r="$val" '
      {
        out = ""; n = length($0); i = 1
        while (i <= n) {
          c = substr($0, i, 1)
          if (c == "$" && i < n) {
            rest = substr($0, i+1)
            if (match(rest, "^" v "([^A-Za-z0-9_]|$)")) {
              out = out r
              i = i + 1 + length(v)
              continue
            }
          }
          out = out c
          i = i + 1
        }
        print out
      }
    ')
  done
  printf '%s\n' "$segment"
}
