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
#   read_pretooluse_input                  — read + validate stdin JSON once (fail closed);
#                                            call at top level before the accessors
#   read_pretooluse_command                — print .tool_input.command from stdin JSON
#   read_pretooluse_file_path              — print .tool_input.file_path from stdin JSON
#   read_pretooluse_tool_name              — print .tool_name from stdin JSON
#                                            (all three block on an invalid payload)
#   split_segments                         — bash-accurate ; && || | |& & NL splitter
#   flatten_substitutions                  — append $(...) / `...` bodies
#   collect_assignments                    — extract VAR=value assignments
#   expand_known_vars VAR=val ...          — substitute $VAR / ${VAR}
#   unwrap_eval_and_bashc                  — pull eval / bash -c / sh -c arguments
#
# The block-message prefix defaults to the neutral English "Blocked: ";
# consumers that need a different locale-specific prefix (e.g. claude-
# org-ja's "ブロック: ") export CORE_HARNESS_BLOCK_PREFIX before sourcing
# this file (must include any trailing punctuation/space).
#
# Idempotent: safe to source twice in the same shell.

# The marker alone is not trusted: it may be inherited from the
# environment, and skipping the definitions would make every helper call
# fail with 127 (a non-blocking error, i.e. fail open).
if [[ -n "${__CORE_HARNESS_HOOKS_SH_SOURCED:-}" ]] \
    && declare -F read_pretooluse_input >/dev/null 2>&1 \
    && declare -F split_segments >/dev/null 2>&1; then
  return 0 2>/dev/null || true
fi
__CORE_HARNESS_HOOKS_SH_SOURCED=1

: "${CORE_HARNESS_BLOCK_PREFIX:=Blocked: }"

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
      block_with_message "$bin is not installed; required by security hook."
    fi
  done
}

# Payload state inherited from the environment must never replace the
# real stdin payload or let a hook skip validation, so drop both on first
# source. Source the library before calling read_pretooluse_input.
unset __CORE_HARNESS_PRETOOLUSE_VALIDATED __CORE_HARNESS_PRETOOLUSE_INPUT

# read_pretooluse_input
#   Read the PreToolUse JSON payload from stdin (once), validate it, and
#   cache it in __CORE_HARNESS_PRETOOLUSE_INPUT for the read_pretooluse_*
#   accessors. Blocks (exit 2) unless stdin holds exactly one JSON object
#   whose tool_input, when present and non-null, is itself an object:
#   empty / whitespace-only stdin, malformed or truncated JSON, trailing
#   data, several concatenated values, non-object payloads and
#   non-object tool_input are all denied (fail closed). This is the same
#   predicate the Python helper parse_pretooluse_stdin() applies.
#
#   Call it at the top level of the hook, before any $(read_pretooluse_*):
#   an exit inside $(...) only ends that subshell, and stdin read inside
#   $(...) is not cached for the next call. Idempotent.
read_pretooluse_input() {
  [[ -n "${__CORE_HARNESS_PRETOOLUSE_VALIDATED:-}" ]] && return 0
  require_dependency jq
  if [[ -z "${__CORE_HARNESS_PRETOOLUSE_INPUT+x}" ]]; then
    __CORE_HARNESS_PRETOOLUSE_INPUT=$(cat) \
      || block_with_message "Failed to read the PreToolUse payload from stdin."
  fi
  # -s slurps every JSON value on stdin into one array: jq otherwise
  # accepts a stream of values, so '{}{}' would pass as two objects.
  # A parse error makes jq exit non-zero and leaves the verdict empty.
  # jq 1.6/1.7 accept a raw 0x1F byte inside a string and treat a raw
  # 0x1E (RS) as a JSON-text-sequence separator; JSON forbids both (as
  # does Python) anywhere in the text, so deny them up front.
  # jq may stop reading early (a parse error, the nesting-depth limit);
  # when the hook runs with SIGPIPE ignored (as GitHub Actions does),
  # printf then reports "write error: Broken pipe" on stderr, and that
  # line would come before the deny reason. Silence it: jq's verdict
  # alone decides.
  local verdict=invalid
  [[ "$__CORE_HARNESS_PRETOOLUSE_INPUT" == *$'\036'* \
    || "$__CORE_HARNESS_PRETOOLUSE_INPUT" == *$'\037'* ]] \
    || verdict=$(printf '%s' "$__CORE_HARNESS_PRETOOLUSE_INPUT" 2>/dev/null | jq -s -r '
    if length == 0 then "empty"
    elif length > 1 then "multiple"
    elif (.[0] | type) != "object" then "not_object"
    elif (.[0].tool_input != null) and ((.[0].tool_input | type) != "object")
      then "tool_input"
    else "ok" end' 2>/dev/null) || verdict="invalid"
  case "$verdict" in
    ok) ;;
    empty) block_with_message "PreToolUse payload is empty." ;;
    multiple) block_with_message "PreToolUse payload contains more than one JSON value." ;;
    not_object) block_with_message "PreToolUse payload is not a JSON object." ;;
    tool_input) block_with_message "PreToolUse payload field tool_input is not a JSON object." ;;
    *) block_with_message "Failed to parse PreToolUse JSON payload." ;;
  esac
  __CORE_HARNESS_PRETOOLUSE_VALIDATED=1
}

# Internal: validate (reading stdin if needed), then print a jq field.
__core_harness_read_field() {
  read_pretooluse_input
  printf '%s' "$__CORE_HARNESS_PRETOOLUSE_INPUT" 2>/dev/null | jq -r "$1 // empty" \
    || block_with_message "Failed to extract $1 from the PreToolUse payload."
}

# read_pretooluse_command
#   Print the value of .tool_input.command (Bash tool) or empty.
#   Blocks on an invalid payload (see read_pretooluse_input).
read_pretooluse_command() {
  __core_harness_read_field '.tool_input.command'
}

# read_pretooluse_file_path
#   Print the value of .tool_input.file_path (Edit/Write tool) or empty.
#   Blocks on an invalid payload (see read_pretooluse_input).
read_pretooluse_file_path() {
  __core_harness_read_field '.tool_input.file_path'
}

# read_pretooluse_tool_name
#   Print the value of .tool_name or empty.
#   Blocks on an invalid payload (see read_pretooluse_input).
read_pretooluse_tool_name() {
  __core_harness_read_field '.tool_name'
}

# ---------------------------------------------------------------------------
# Generic Bash command-string parser. Lives in the framework slice
# because nothing in these helpers is consumer-specific (no role names,
# no path patterns). Bug fixes propagate to all consumers that source
# this library.
# ---------------------------------------------------------------------------

# split_segments
#   Read a Bash command string from stdin; print one segment per line,
#   splitting at the top-level command boundaries bash itself uses:
#   ; && || | |& & (background) and unquoted newlines. The separators are
#   dropped; segment text is otherwise verbatim (a segment whose quotes
#   span a newline prints across several lines).
#
#   Quoting follows bash:
#   - Unquoted: a backslash escapes the next character (\; \| \& \" \'
#     \` \( \) \$ are literal); backslash-newline is a line continuation
#     and is removed; a trailing backslash is kept.
#   - "...": a backslash escapes the next character; backslash-newline
#     is removed; $( ... ), ${ ... } and `...` open nested contexts.
#   - '...': no escapes; only ' closes. $'...': a backslash escapes.
#   - `...`: a backslash escapes; only an unescaped ` closes.
#   - $( ... ), $(( ... )), ${ ... }, $[ ... ] and assignment subscripts
#     (a[...]=) are parsed as nested contexts with their own quoting (so
#     "$(echo ")")" is one word); nothing inside them splits.
#   - A & that belongs to a redirection (>& <& &> &>>) is not a separator.
#   - # at the start of a word starts a comment that runs to the end of
#     the line; quotes inside it are ignored, as bash ignores them.
#   - Here-document bodies (<<WORD / <<-WORD) are copied verbatim, unparsed,
#     into the segment of the command that owns them. With an unquoted
#     WORD, a body line ending in an odd number of backslashes is joined
#     with the next line before it is compared to WORD, as bash does.
#   - Backslash-newline is removed before tokens are read, so it also
#     joins multi-character operators ($\<NL>( is $(, <\<NL>< is <<).
#
#   Limitations: top-level ( ... ) / { ...; } groups, <( ... ) / >( ... ),
#   [[ ]], (( )), `for ((;;))` headers and case clauses are split at the
#   separators inside them, and >| is split as a pipe (over-splits: more,
#   smaller segments, never a hidden boundary). Aliases are not expanded.
#   If the input does not parse to a balanced state (an unterminated
#   quote or substitution - input bash would reject - a here-document
#   whose delimiter never appears, or a construct this parser gets
#   wrong), or contains a construct whose meaning depends on how bash
#   re-parses it (a $(( or top-level (( not closed by )), which bash
#   re-reads as $( ( or ( (; # at the start of a word or << inside
#   arithmetic, which is a comment / here-document in that reading; a
#   case / esac word inside $( ) or ( ), whose pattern ) needs bash's
#   reserved-word rules to tell apart from a closing paren; the word
#   coproc, whose compound command this parser does not track; a here-document
#   delimiter written with $'...', $( ), ${ }, $[ ] or `...`; a ' or $'
#   inside "${ ... }", literal in posix mode; a here-document opened
#   inside $( ) or ( ) that closes before its body starts, whose body
#   bash 5.1 and 5.2 read differently), split_segments falls back to
#   splitting at every ; & | and newline character, ignoring quotes, so
#   that no boundary can hide. The fallback prints the splitting of the
#   raw text and, when it has line continuations, also the splitting of
#   the text with them joined (extra segments only).
split_segments() {
  awk -v ors="${__CORE_HARNESS_SPLIT_ORS:-}" '
    function emit() { segs[++ns] = seg; seg = "" }
    # Split s at every ; & | and newline character, ignoring quotes.
    function fallback(s,   q, m, ch) {
      seg = ""; m = length(s)
      for (q = 1; q <= m; q++) {
        ch = substr(s, q, 1)
        if (ch == ";" || ch == "&" || ch == "|" || ch == "\n") emit(); else seg = seg ch
      }
      if (length(seg) > 0) emit()
    }
    function push(t) { st[++sp] = t }
    function frame_start() { ws = 1; cp = 1; ap = 1; wb = 0 }
    # Remove backslash-newline pairs at index p, as bash does before it
    # tokenizes (everywhere but in quotes that keep them literally).
    function unsplice(p) {
      while (substr(buf, p, 2) == "\\\n") { buf = substr(buf, 1, p - 1) substr(buf, p + 2); n -= 2 }
    }
    # 1 if the innermost command context is arithmetic: a $(( )) frame
    # (not behind a nested $( )), or a top-level (( )).
    function arith(   q) {
      for (q = sp; q > 0; q--) {
        if (st[q] == "c") return 0
        if (st[q] == "r") return 1
      }
      return ar
    }
    function start_word() { if (wb == 0) { wb = i; cpw = cp; apw = ap } }
    # cp: a reserved word may start here; ap: an assignment may start here.
    function end_word(   w) {
      if (wb == 0) return
      w = (wb > 0) ? substr(buf, wb, i - wb) : ""
      # The ) of a case pattern must not close $( ) / ( ), and telling it apart
      # needs the reserved-word rules of bash (for case / time -p case ...):
      # inside any nested context, fall back instead of guessing.
      if (sp > 0 && (w == "case" || w == "esac")) lost = 1
      # coproc [NAME] takes a full compound command (arithmetic, groups,
      # loops) that this parser does not track after it: fall back.
      if (w == "coproc") lost = 1
      # time -p / time -- keep the next word in command position.
      to = (tm && (w == "-p" || w == "--")) ? 1 : 0
      cp = (cpw && ((w in kw) || to)) ? 1 : 0
      tm = (cp && (w == "time" || (to && w == "-p"))) ? 1 : 0
      # The word after for is a name: no a[...]= subscript there.
      ap = ((cp && w != "for") || (apw && w ~ /^[A-Za-z_][A-Za-z0-9_]*(\[.*\])?\+?=/)) ? 1 : 0
      wb = 0
    }
    # Queue the delimiter of a here-document whose << starts at index j.
    function queue_heredoc(j,   strip, d, ch, done, quoted) {
      strip = 0; quoted = 0
      unsplice(j)
      if (substr(buf, j, 1) == "-") { strip = 1; j++ }
      while (substr(buf, j, 1) == " " || substr(buf, j, 1) == "\t" || substr(buf, j, 2) == "\\\n") {
        unsplice(j); if (substr(buf, j, 1) == " " || substr(buf, j, 1) == "\t") j++
      }
      d = ""; done = 0
      while (j <= n && !done) {
        unsplice(j)
        ch = substr(buf, j, 1)
        if (ch == "$" && substr(buf, j + 1, 1) == "\"") { j++; continue }
        # Constructs whose delimiter text bash computes differently from
        # this reader (ANSI-C escapes, $( ), ${ }, $[ ], `...`):
        # give up and use the fallback.
        if (ch == "`" || (ch == "$" && index("\047{[(", substr(buf, j + 1, 1)) > 0)) {
          lost = 1; break
        }
        if (ch == "\047") {
          quoted = 1; j++
          while (j <= n && substr(buf, j, 1) != "\047") { d = d substr(buf, j, 1); j++ }
          j++
        } else if (ch == "\"") {
          quoted = 1; j++
          while (j <= n && substr(buf, j, 1) != "\"") {
            # In "...", a backslash quotes only $ ` " \ and newline
            # (backslash-newline is removed); elsewhere it is literal.
            if (substr(buf, j, 1) == "\\" && index("$`\"\\\n", substr(buf, j + 1, 1)) > 0) {
              j++
              if (substr(buf, j, 1) == "\n") { j++; continue }
            }
            d = d substr(buf, j, 1); j++
          }
          j++
        } else if (ch == "\\") {
          quoted = 1; d = d substr(buf, j + 1, 1); j += 2
        } else if (index(" \t\n;&|()<>", ch) > 0) {
          done = 1
        } else {
          d = d ch; j++
        }
      }
      # A here-document opened in a different nesting context while
      # another one is still pending: bash reads the bodies of each
      # context separately, this single queue cannot, so give up.
      if (hq > 0 && hdp[hq] != sp) lost = 1
      hd[++hq] = d; hs[hq] = strip; hu[hq] = !quoted; hdp[hq] = sp
    }
    # Copy pending here-document bodies (they start after the newline at
    # index i) into seg; leave i on the newline that ends the last one.
    # With an unquoted delimiter bash joins a line ending in an odd number
    # of backslashes with the next one before comparing it to the delimiter.
    function read_heredocs(   k, j, e, line, cmp, found, pl) {
      j = i + 1
      for (k = 1; k <= hq; k++) {
        found = 0
        while (j <= n) {
          cmp = ""; pl = 0
          while (j <= n) {
            e = j
            while (e <= n && substr(buf, e, 1) != "\n") e++
            line = substr(buf, j, e - j)
            seg = seg "\n" line
            j = e + 1
            if (pl++ == 0 && hs[k]) sub(/^\t+/, "", line)
            if (hu[k] && e <= n && match(line, /\\+$/) && RLENGTH % 2 == 1) {
              cmp = cmp substr(line, 1, length(line) - 1)
              continue
            }
            cmp = cmp line
            break
          }
          if (cmp == hd[k]) { found = 1; break }
        }
        if (!found) lost = 1
      }
      hq = 0
      i = (j > n + 1) ? n + 1 : j - 1
    }
    BEGIN {
      if (ors == "") ors = "\n"
      split("if then else elif do while until ! { time for", tmp, " ")
      for (k in tmp) kw[tmp[k]] = 1
    }
    { buf = (NR == 1) ? $0 : buf "\n" $0 }
    END {
      orig = buf; n = length(buf); i = 1; sp = 0; ns = 0; seg = ""; hq = 0
      redir = 0; ar = 0; apd = 0; lost = 0
      frame_start()
      while (i <= n) {
        t = (sp > 0) ? st[sp] : ""
        if (t != "s" && t != "a" && t != "b") {
          # Drop line continuations before reading a token, including
          # inside multi-character operators ($\<NL>( is $( to bash).
          unsplice(i)
          if (index("$<>&|()", substr(buf, i, 1)) > 0) {
            unsplice(i + 1)
            if (substr(buf, i, 2) == "$(" || substr(buf, i, 2) == "<<") unsplice(i + 2)
          }
          if (i > n) break
        }
        c = substr(buf, i, 1); nc = substr(buf, i + 1, 1)
        if (t == "s") {
          seg = seg c; i++
          if (c == "\047") sp--
          continue
        }
        if (t == "a" || t == "b") {
          if (c == "\\") { seg = seg c nc; i += 2; continue }
          seg = seg c; i++
          if ((t == "a" && c == "\047") || (t == "b" && c == "`")) sp--
          continue
        }
        if (t == "d" || t == "e" || t == "k") {
          if (c == "\\") {
            if (nc != "\n") seg = seg c nc
            i += 2; continue
          }
          if ((t == "d" && c == "\"") || (t == "e" && c == "}") || (t == "k" && c == "]")) {
            sp--; seg = seg c; i++; continue
          }
          # In posix mode a single quote inside "${ ... }" is literal, else it
          # opens a quote: the mode is not known statically, so fall back.
          if (t == "e" && st[sp - 1] == "d" && (c == "\047" || (c == "$" && nc == "\047"))) lost = 1
          if (t != "d" && c == "\047") { push("s"); seg = seg c; i++; continue }
          if (t != "d" && c == "\"") { push("d"); seg = seg c; i++; continue }
          if (t != "d" && c == "$" && nc == "\047") { push("a"); seg = seg c nc; i += 2; continue }
          if (c == "$" && nc == "(") {
            if (substr(buf, i + 2, 1) == "(") { push("r"); seg = seg "$(("; i += 3 }
            else { push("c"); seg = seg "$("; i += 2 }
            frame_start(); continue
          }
          if (c == "$" && nc == "{") { push("e"); seg = seg "${"; i += 2; continue }
          if (c == "$" && nc == "[") { push("k"); seg = seg "$["; i += 2; continue }
          if (c == "`") { push("b"); seg = seg c; i++; continue }
          seg = seg c; i++; continue
        }
        # Unquoted: top level (sp == 0), or inside $( ), ( ) or $(( )).
        pr = redir; redir = 0
        if (c == "\\") {
          if (nc == "\n") { i += 2; continue }
          start_word(); ws = 0
          seg = seg c nc; i += 2; continue
        }
        if (ws && c == "#" && arith()) {
          # Not a comment inside (( )), but one if bash re-parses the
          # (( as nested subshells: ambiguous, so fall back.
          lost = 1
        } else if (ws && c == "#") {
          while (i <= n && substr(buf, i, 1) != "\n") { seg = seg substr(buf, i, 1); i++ }
          continue
        }
        if (c == "\"" || c == "\047" || c == "`" || (c == "$" && (nc == "\047" || nc == "{" || nc == "[" || nc == "("))) {
          start_word(); ws = 0
          if (c == "\"") { push("d"); seg = seg c; i++; continue }
          if (c == "\047") { push("s"); seg = seg c; i++; continue }
          if (c == "`") { push("b"); seg = seg c; i++; continue }
          if (nc == "\047") { push("a"); seg = seg c nc; i += 2; continue }
          if (nc == "{") { push("e"); seg = seg c nc; i += 2; continue }
          if (nc == "[") { push("k"); seg = seg c nc; i += 2; continue }
          if (substr(buf, i + 2, 1) == "(") { push("r"); seg = seg "$(("; i += 3 }
          else { push("c"); seg = seg "$("; i += 2 }
          frame_start(); continue
        }
        if (c == " " || c == "\t") { end_word(); ws = 1; seg = seg c; i++; continue }
        if (c == "[" && wb > 0 && apw && substr(buf, wb, i - wb) ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
          # Array subscript in an assignment (a[i<<2]=x): bash parses the
          # brackets as one unit, so << inside is not a here-document.
          push("k"); seg = seg c; i++; continue
        }
        if (c == "\n") {
          end_word()
          if (hq > 0) { read_heredocs(); continue }
          if (sp == 0) emit(); else seg = seg c
          i++; ws = 1; cp = 1; ap = 1; continue
        }
        if (c == ";" || c == "|" || c == "&") {
          end_word()
          if (c == "&" && nc != "&" && (pr || nc == ">")) {
            # >& <& &> &>> : part of a redirection, not a separator.
            seg = seg c; i++; ws = 1; continue
          }
          w = 1
          if ((c == "&" && nc == "&") || (c == "|" && (nc == "|" || nc == "&"))) w = 2
          if (sp == 0) emit(); else seg = seg substr(buf, i, w)
          i += w; ws = 1; cp = 1; ap = 1; continue
        }
        if (c == "<" || c == ">") {
          end_word()
          if (c == "<" && nc == "<" && substr(buf, i + 2, 1) == "<") { seg = seg "<<<"; i += 3; ws = 1; continue }
          if (c == "<" && nc == "<" && arith()) {
            # A shift in arithmetic, a here-document if bash re-parses
            # the (( as nested subshells: ambiguous, so fall back.
            lost = 1; seg = seg "<<"; i += 2; ws = 1; continue
          }
          if (c == "<" && nc == "<") {
            queue_heredoc(i + 2); seg = seg "<<"; i += 2; ws = 1; continue
          }
          seg = seg c; i++; ws = 1; redir = 1; continue
        }
        if (c == "(") {
          end_word()
          if (cp && nc == "(" && sp > 0) { push("r"); seg = seg "(("; i += 2; frame_start(); continue }
          if (cp && nc == "(" && sp == 0 && !ar) { ar = 1; apd = 2; seg = seg "(("; i += 2; ws = 1; continue }
          if (sp > 0) { push("p"); seg = seg c; i++; frame_start(); continue }
          if (ar) apd++
          seg = seg c; i++; ws = 1; cp = 1; ap = 1; continue
        }
        if (c == ")") {
          end_word()
          if (t == "r") {
            # $(( closed by a single ) is re-parsed by bash as $( ( ... ).
            if (nc != ")") lost = 1
            sp--
            if (nc == ")") { seg = seg "))"; i += 2 } else { seg = seg c; i++ }
            ws = 0; wb = -1; cpw = 0; apw = 0; continue
          }
          if (t == "c" || t == "p") {
            # A here-document opened inside this frame whose body has not
            # been read yet: bash versions disagree on where its body is
            # (5.1 and older drop it, 5.2 reads the following lines).
            if (hq > 0 && hdp[hq] >= sp) lost = 1
            sp--; seg = seg c; i++
            if (t == "c") { ws = 0; wb = -1; cpw = 0; apw = 0 } else { ws = 1; cp = 1; ap = 1 }
            continue
          }
          # Top level (a case pattern terminator, or a stray paren).
          # A top-level (( whose matching ) is not followed by ) is
          # re-parsed by bash as nested subshells.
          if (ar && sp == 0 && apd == 2 && nc != ")") lost = 1
          if (ar && sp == 0 && --apd <= 0) ar = 0
          seg = seg c; i++; ws = 1; cp = 1; ap = 1; continue
        }
        start_word(); ws = 0
        seg = seg c; i++
      }
      end_word()
      if (length(seg) > 0) emit()
      if (sp > 0 || lost) {
        # Unbalanced, or a here-document never ended: we lost sync with bash. Split at every separator
        # character, ignoring quotes, so no boundary can stay hidden.
        # Also split the text with its line continuations joined (a
        # backslash-newline after an even run of backslashes), as bash
        # sees it outside comments and single quotes; both splittings are
        # printed, which only adds segments.
        ns = 0
        fallback(orig)
        joined = ""; bs = 0; n = length(orig)
        for (i = 1; i <= n; i++) {
          c = substr(orig, i, 1)
          if (c == "\\" && substr(orig, i + 1, 1) == "\n" && bs % 2 == 0) { i++; bs = 0; continue }
          joined = joined c
          bs = (c == "\\") ? bs + 1 : 0
        }
        if (joined != orig) fallback(joined)
      }
      for (k = 1; k <= ns; k++) printf "%s%s", segs[k], ors
    }
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
