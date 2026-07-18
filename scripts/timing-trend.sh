#!/usr/bin/env bash
# scripts/timing-trend.sh — summarize build_timings.tsv to spot
# compile-time creep.  Reports per-command median, p90, and most
# recent run, plus the delta vs. the median.  No dependencies beyond
# `awk` (and Bash); the TSV is the source of truth.
#
# Usage:
#     ./scripts/timing-trend.sh                  # all commands
#     ./scripts/timing-trend.sh tier-a-check     # filter to one
#
# Tail the file directly to see the raw stream:
#     tail -20 build_timings.tsv | column -t -s $'\t'
#
# Trends that should prompt action:
#   - p90 climbing turn-over-turn for the same command + cache state
#   - latest run >2× median for the same command + cache state
#   - any command's warm median exceeding 30s for the per-turn audit
#     gates (test -Dfocus=tier-a, wgpu-check, tier-a-check)

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSV="$REPO_ROOT/build_timings.tsv"

if [[ ! -f "$TSV" ]]; then
    echo "no build_timings.tsv at $TSV — run scripts/timed-build.sh first"
    exit 0
fi

FILTER="${1:-}"

# awk: skip header, group by (command, cache_state), compute stats,
# print one row per group.  Stats: count, median, p90, latest.
awk -F'\t' -v filter="$FILTER" '
NR == 1 { next }       # header
$5 != "warm" && $5 != "cold" { next }   # skip malformed rows
filter != "" && index($2, filter) == 0 { next }
{
    key = $2 "\t" $5
    n[key]++
    times[key, n[key]] = $3 + 0
    latest_ts[key] = $1
    latest_t[key] = $3 + 0
    latest_exit[key] = $4 + 0
}
END {
    # Bubble-sort times per group (n is small per command).
    for (k in n) {
        cnt = n[k]
        for (i = 1; i <= cnt; i++) {
            for (j = i + 1; j <= cnt; j++) {
                if (times[k, i] > times[k, j]) {
                    t = times[k, i]; times[k, i] = times[k, j]; times[k, j] = t
                }
            }
        }
        median[k] = times[k, int((cnt + 1) / 2)]
        p90_idx = int(cnt * 0.9 + 0.5)
        if (p90_idx < 1) p90_idx = 1
        if (p90_idx > cnt) p90_idx = cnt
        p90[k] = times[k, p90_idx]
    }

    printf "%-50s  %-5s  %5s  %7s  %7s  %7s  %s\n", \
        "command", "cache", "runs", "median", "p90", "latest", "Δ vs median"
    printf "%-50s  %-5s  %5s  %7s  %7s  %7s  %s\n", \
        "-------", "-----", "----", "------", "---", "------", "-----------"

    for (k in n) {
        split(k, parts, "\t")
        cmd = parts[1]; cache = parts[2]
        delta = latest_t[k] - median[k]
        delta_pct = (median[k] > 0) ? (delta / median[k] * 100) : 0
        flag = ""
        if (latest_exit[k] != 0) flag = " ✗"
        else if (delta > 5 && delta_pct > 50) flag = " ⚠ slower"

        printf "%-50s  %-5s  %5d  %6.2fs  %6.2fs  %6.2fs  %+6.2fs (%+.0f%%)%s\n", \
            substr(cmd, 1, 50), cache, n[k], median[k], p90[k], latest_t[k], \
            delta, delta_pct, flag
    }
}' "$TSV" | sort -k1,1
