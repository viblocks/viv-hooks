# ADR-001 — Bash + jq + Python as the hook runtime

**Status:** Accepted
**Date:** 2026-05-08
**Category:** viv-hooks local

## Context

Claude Code hooks are executed as shell commands. Any language with an interpreter on the user's system can implement them. Common choices:

- **Bash** — universal, no install required, easy to inspect
- **Python** — better data manipulation, requires interpreter
- **Node.js** — couples to the project's node toolchain
- **Go/Rust binary** — fastest, requires compilation + distribution

viblocks-ai's existing hooks are bash + jq + Python helpers. Extracting them with a language change would require rewriting + revalidating ~1900 lines.

## Decision

Hook runtime is **bash + jq + Python3**:

- Hook scripts are bash (`hooks/**/*.sh`)
- JSON manipulation uses `jq` (1.6+)
- Date/time arithmetic where bash is awkward uses Python3 fallback
- No compilation step; no language toolchain coupling

Hard dependencies a consumer must have on PATH:
- `bash` (5.0+ recommended; tested on macOS bash 3.2 and Linux bash 5+)
- `jq` (any 1.6+)
- `python3` (3.8+; only used as fallback for date parsing and message extraction)

Soft dependencies (used if available, fallback otherwise):
- `realpath` (preferred for canonicalization; Python fallback otherwise)
- `flock` (preferred for marker-registry mutex; mkdir-spinlock fallback otherwise)

## Rationale

| Concern | How this satisfies |
|---|---|
| Vendoring simplicity | `cp -r` works; no install step required |
| Auditability | Bash + JSON are inspectable in any editor |
| Consistency with viblocks | Existing hooks transferred without rewrite |
| Cross-platform | Tested on macOS (bash 3.2 + jq) and Linux (bash 5 + jq) |

## Consequences

- Bash is **slower** than a compiled binary. Hook latency adds to every Edit/Write/Bash call. Acceptable because hooks run only at tool-use boundaries (not in tight loops).
- Bash 3.2 (macOS default) lacks some features (associative arrays, namerefs in some forms). The codebase targets bash 3.2-compatible idioms; namerefs (bash 4.3+) are used only with explicit feature checks.
- Python3 is **required** for a few code paths (ISO 8601 parsing on macOS where GNU date is absent). Not optional.

## Alternatives considered

- **Pure Python:** rejected — replaces 1900 lines of working bash with a rewrite; introduces interpreter startup latency on every hook (cold-start ~50ms × ~5 hooks per Edit = ~250ms overhead).
- **Compiled binary (Go/Rust):** rejected — distribution complexity (per-platform builds, signing, vendor process); inspectability lost.
- **Mixed bash + Python (Python for parsers, bash for orchestration):** kept partially — Python is the fallback for tasks bash handles awkwardly, but the primary surface is bash.

## Related

- ADR-RD-008 (pure descriptors; viv-hooks is the only code repo)
- ADR-002 local (fail-closed defaults — applies regardless of language choice)
