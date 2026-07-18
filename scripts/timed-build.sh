#!/usr/bin/env bash
# scripts/timed-build.sh — wrap `zig build <args>` with wall-clock
# timing, appending a row to `build_timings.tsv` at the repo root.
#
# This is the canonical way to invoke the audit gates so we have a
# trail of compile-time evolution.  Use it instead of `zig build`
# when you want the run captured:
#
#   ./scripts/timed-build.sh test -Dfocus=tier-a
#   ./scripts/timed-build.sh wgpu-check
#   ./scripts/timed-build.sh tier-a-check
#
# The TSV columns: timestamp_iso, command, wall_seconds, exit_status,
# cache_state, git_short_sha, host.  The file appends, never trims —
# `tail` / `awk` it to see trends.  Throwaway lines (one bad commit,
# benchmark on the wrong machine, etc.) can be deleted by hand.
#
# Why a script and not a Zig build step?  Two reasons:
#   1. The wall time is measured AROUND `zig build`, not inside it —
#      includes process startup, plan eval, cache lookups, the whole
#      end-to-end experience.  That's what humans feel as "iteration
#      time."
#   2. The TSV lives outside the build graph, so it persists across
#      `rm -rf .zig-cache` and never invalidates anything.
#
# Cache state detection: warm if `.zig-cache/o/` already has entries,
# cold otherwise.  Best-effort; first call after a `rm -rf` is
# correctly cold, subsequent calls warm.

set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSV="$REPO_ROOT/build_timings.tsv"

# Header on first write.
if [[ ! -f "$TSV" ]]; then
    printf "timestamp_iso\tcommand\twall_seconds\texit_status\tcache_state\tgit_short_sha\thost\n" > "$TSV"
fi

# Cache-state heuristic: presence of .zig-cache/o/ entries.
if [[ -d "$REPO_ROOT/.zig-cache/o" ]] && [[ -n "$(ls -A "$REPO_ROOT/.zig-cache/o" 2>/dev/null | head -1)" ]]; then
    CACHE_STATE="warm"
else
    CACHE_STATE="cold"
fi

# Git sha (best-effort; falls back to "unknown" outside a git checkout).
if GIT_SHA="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null)"; then
    :
else
    GIT_SHA="unknown"
fi

HOST="$(hostname 2>/dev/null || echo unknown)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Argv echoed into the command column.  Use a TAB-safe form: replace
# any tabs in args with spaces (shouldn't happen but be paranoid).
CMD_DISPLAY="zig build $(printf '%s ' "$@" | sed 's/\t/ /g' | sed 's/ $//')"

# Run.  Capture exit code without aborting on failure — we want to
# log unsuccessful runs too (they're often the most interesting).
START_NS="$(date +%s%N)"
zig build "$@"
EXIT="$?"
END_NS="$(date +%s%N)"

# Wall time in seconds with 2 decimal places.  Use Bash arithmetic
# rather than `bc` so this script has zero non-standard deps.
ELAPSED_NS="$((END_NS - START_NS))"
SECONDS_WHOLE="$((ELAPSED_NS / 1000000000))"
SECONDS_FRAC="$(( (ELAPSED_NS / 10000000) % 100 ))"
WALL=$(printf "%d.%02d" "$SECONDS_WHOLE" "$SECONDS_FRAC")

printf "%s\t%s\t%s\t%d\t%s\t%s\t%s\n" \
    "$TIMESTAMP" "$CMD_DISPLAY" "$WALL" "$EXIT" "$CACHE_STATE" "$GIT_SHA" "$HOST" \
    >> "$TSV"

echo
echo "[timed] $CMD_DISPLAY"
echo "[timed] wall=${WALL}s exit=$EXIT cache=$CACHE_STATE (logged to build_timings.tsv)"

exit "$EXIT"
