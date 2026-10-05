# PreToolUse Hook Contract

> Status: experimental (0.2). Subject to change per
> [`semver-policy.md`](semver-policy.md) until 1.0.

`core-harness` defines a minimal, language-neutral wire contract for
[Claude Code PreToolUse hooks](https://docs.claude.com/en/docs/claude-code/hooks).
Consumer-org-specific deny logic plugs into this contract from either
Python or bash without depending on each other.

## 1. Wire format

### 1.1 Input — stdin

Claude Code delivers a single JSON object on stdin per hook invocation.
Hooks MAY ignore fields they do not need. The fields the framework
acknowledges are:

| Field | Type | Tools | Notes |
|---|---|---|---|
| `tool_name` | string | all | One of `Bash`, `Edit`, `Write`, `NotebookEdit`, etc. |
| `tool_input.command` | string | `Bash` | The shell command string Claude is about to run. |
| `tool_input.file_path` | string | `Edit`/`Write`/`NotebookEdit` | Target file path (caller-provided; not yet normalized). |

Hooks MUST tolerate empty / absent fields by treating them as "out of
scope" (exit 0). Hooks MUST NOT trust the field set to be exhaustive —
new fields may be added by upstream tooling between minor versions of
Claude Code.

A payload the hook cannot inspect is not "out of scope". Both helpers
(Python `parse_pretooluse_stdin()`, bash `read_pretooluse_input` and the
`read_pretooluse_*` accessors) apply the same validity predicate and
**deny** (exit 2, fail closed) when:

- stdin is empty or whitespace-only;
- stdin is not exactly one JSON value (parse error, truncated input,
  trailing data, several concatenated values);
- the top-level value is not an object (array, string, number, `null`,
  boolean);
- `tool_input` is present, not `null`, and not an object.

An absent or `null` `tool_input`, and absent fields inside it, remain out
of scope (the accessors print empty).

Known divergences outside this predicate (in each case one side denies
and the other inspects the payload; neither silently allows a payload it
could not read):

- Python rejects a leading UTF-8 BOM, which `jq` accepts.
- Undecodable bytes: Python rejects them only when its stdin decodes
  strictly (for example `PYTHONIOENCODING=utf-8`); under
  `surrogateescape` (C/POSIX locale, UTF-8 mode) it accepts them, as
  `jq` does.
- Nesting depth: each parser denies JSON nested deeper than its limit
  (`jq` 1.6: 256, `jq` 1.7: 10000, Python: its recursion limit, about
  1000), so payloads between the limits get different verdicts.
- Lone surrogate escapes (`"\ud800"`) are accepted by Python and
  rejected by `jq` 1.6. Integers longer than Python's int-conversion
  limit (4300 digits, on Pythons that have one) and the non-standard
  number literals `jq` 1.6 accepts (leading zeros `01`, a leading `+` or
  `.` as in `+1` / `.5`, a trailing `.` as in `1.`) are rejected by
  Python and accepted by `jq`.
- bash cannot hold NUL bytes in a variable, so NULs are dropped before
  validation.

### 1.2 Output — exit code + stderr

| Exit code | Meaning | stderr |
|---|---|---|
| `0` | Allow. The tool call proceeds. | Ignored. |
| `2` | Deny. The tool call is blocked. | The first line is shown to the user as the deny reason. |
| `1` (or any non-zero ≠ 2) | Non-blocking error. Claude Code shows stderr but **the tool call proceeds** (fail-open). | Shown to the user, not as a deny reason. |

Because any exit code other than `2` lets the tool call through, a hook
MUST map every failure path — crashes, missing dependencies, unreadable
input, failed parsing — to exit `2`. The helpers do so; hook code that
adds its own failure paths must as well.

The deny-reason line follows the format:

```
{block_prefix}{reason}
```

where `{block_prefix}` defaults to the neutral English `"Blocked: "`.
Layer 1 ships no consumer-specific locale string. Consumers that need a
different prefix (for example a localized contract such as
`"ブロック: "`) inject it per process via
the `CORE_HARNESS_BLOCK_PREFIX` environment variable, or per-call via
`HookRunner(block_prefix=...)` in Python /
`CORE_HARNESS_BLOCK_PREFIX=...` exported before sourcing
`core_harness_hooks.sh` in bash.

Resolution order (Python and bash both): explicit constructor argument
→ `CORE_HARNESS_BLOCK_PREFIX` env var → `DEFAULT_BLOCK_PREFIX`
(`"Blocked: "`).

Future minor versions may introduce a typed (JSON) stderr alternative
behind a feature flag; the plain-text contract documented here remains
the default for the 0.x line.

## 2. Python helper API

```python
from core_harness.hooks import HookRunner, exit_with_block, exit_ok, parse_pretooluse_stdin

# Long form — preferred when you need to inject stderr/stdin in tests:
runner = HookRunner()
payload = runner.parse_pretooluse_stdin()
if payload.get("tool_name") != "Bash":
    runner.exit_ok()
command = (payload.get("tool_input") or {}).get("command", "")
if "--no-verify" in command:
    runner.exit_with_block("--no-verify は禁止です。")
runner.exit_ok()
```

### Behaviour

- `parse_pretooluse_stdin()`: returns the payload dict when it passes the
  §1.1 predicate; otherwise `exit_with_block` (fail closed). Empty or
  whitespace-only stdin now blocks (it used to return `{}`), as does a
  non-object `tool_input` (it used to pass through, and the usual
  `payload.get("tool_input", {}).get(...)` then raised `AttributeError`:
  exit 1, which Claude Code treats as fail-open).
- `exit_with_block(message)`: writes `{prefix}{message}\n` to stderr,
  flushes, exits 2. Never returns.
- `exit_ok()`: exits 0. Never returns.
- The block-message prefix defaults to `"Blocked: "` (neutral English)
  and is resolved in this priority order: explicit constructor
  argument → `CORE_HARNESS_BLOCK_PREFIX` env var →
  `DEFAULT_BLOCK_PREFIX`.

## 3. Bash helper API

Hooks source the library by resolving its path through Python:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Every failure path must exit 2 (section 1.2), including a missing library.
LIB_DIR=$(python3 -c 'import core_harness.hooks; print(core_harness.hooks.lib_path())') \
  || { echo "Blocked: core_harness is not importable." >&2; exit 2; }
# shellcheck source=/dev/null
source "$LIB_DIR/core_harness_hooks.sh" \
  || { echo "Blocked: core_harness_hooks.sh could not be loaded." >&2; exit 2; }

require_dependency jq awk

# Read and validate stdin once, at top level (blocks on a bad payload).
read_pretooluse_input

cmd=$(read_pretooluse_command) || exit 2
[[ -z "$cmd" ]] && exit 0

# … org-specific deny logic …

exit 0
```

### Public functions

| Function | Purpose |
|---|---|
| `block_with_message <reason>` | stderr prefix + exit 2. |
| `require_dependency <bin> [<bin> …]` | Fail closed if any binary missing. |
| `read_pretooluse_input` | Read stdin once, validate it (§1.1), cache it; block on an invalid payload. |
| `read_pretooluse_command` | Print `.tool_input.command` (or empty); block on an invalid payload. |
| `read_pretooluse_file_path` | Print `.tool_input.file_path` (or empty); block on an invalid payload. |
| `read_pretooluse_tool_name` | Print `.tool_name` (or empty); block on an invalid payload. |
| `split_segments` | Split a command string at the top-level boundaries bash uses (`;` `&&` `\|\|` `\|` `\|&` `&` newline), honouring quotes, escapes, line continuations, `$( )`, `${ }`, backticks, comments and here-documents. |
| `flatten_substitutions` | Reveal `$(…)` / `` `…` `` bodies. |
| `collect_assignments` | Extract `VAR=value` chains. |
| `expand_known_vars VAR=val …` | Substitute `$VAR` / `${VAR}`. |
| `unwrap_eval_and_bashc` | Reveal `eval` / `bash -c` / `sh -c` argument bodies. |

Call `read_pretooluse_input` at the top level before any
`$(read_pretooluse_*)`. Each `$(...)` runs in a subshell: a block inside
it only ends that subshell, and stdin read inside it is not cached for
the next call. Reading at top level makes an invalid payload exit the
hook itself and fills the cache that later `$(...)` calls inherit, so a
hook can call several accessors. `|| exit 2` keeps the extraction
fail-closed even without `set -e`. An accessor called without priming
still validates, but a second un-primed call finds stdin already drained
and blocks.

## 4. Contract guarantees vs. responsibilities

`core-harness` owns:

- The wire format documented above.
- The Python / bash helper APIs.
- The set of generic command-string parsers (segment splitting, eval
  unwrapping, command-substitution flattening) — these are reusable
  across consumers and grouped in the framework so bug fixes propagate.

`core-harness` does **not** own:

- Any specific deny rule (no `--no-verify` blocker, no `git push`
  blocker, no path-based file boundary). Those live in the consumer
  repo, which composes the framework helpers with its own policy.
- Any role catalogue (no consumer-specific role names).
- Path-normalisation helpers tied to the consumer's directory layout —
  consumers ship those alongside their org-specific hooks.

## 5. Consumer-specific localisation

Layer 1 (`core-harness`) ships only the neutral English default
`"Blocked: "`. Consumers with a localised contract — for example a
legacy localized deny-line such as `"ブロック: "` — inject their prefix
at the org boundary, never inside `core-harness`:

- **Python** consumers: instantiate `HookRunner(block_prefix="ブロック: ")`,
  or set `CORE_HARNESS_BLOCK_PREFIX` once at process start.
- **Bash** consumers: `export CORE_HARNESS_BLOCK_PREFIX="ブロック: "`
  before sourcing `core_harness_hooks.sh`.

This keeps the dependency one-way: `core-harness` does not know about
any consumer's locale, and adding a new consumer with a different
locale does not require a `core-harness` release.

## 6. Open questions tracked for 1.0

- Typed (JSON) stderr alternative — see inventory §5.2.5. Not in 0.x.
- PostToolUse / Stop / Notification / SubagentStop hook contracts — not
  used by any current consumer. Will be added if/when a consumer
  requires them.
