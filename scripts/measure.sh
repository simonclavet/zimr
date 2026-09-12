#!/bin/sh
# measure.sh — run one build command under `timeout` and record wall time, peak
# RSS, .zig-cache delta and free-disk delta into /tmp/measure.log.
#
# Usage:  scripts/measure.sh <label> <timeout-seconds> <command...>
#
# Why this exists
# ---------------
# 1. claude.md's cold-build procedure is an idempotent retry loop, and
#    `--summary all` only prints on COMPLETION — a chain that needs several
#    timeout rounds leaves no per-round record at all.  Cache delta per round is
#    the only reliable progress signal, so capture it every time.
# 2. There is no `/usr/bin/time` in this sandbox, so peak RSS is sampled by
#    polling /proc.  We sum RSS across the whole `zig` process tree (the build
#    runner plus every `zig build-exe` it spawns) because the number that
#    matters is what the 3.9 GB box has to hold at once, not any one process.
#
# Sampling is 0.25 s; a compile step shorter than that can be under-reported,
# which is fine — the steps we care about run for tens of seconds.

LABEL="$1"; shift
TMO="$1"; shift

CACHE_BEFORE=$(du -sm .zig-cache 2>/dev/null | cut -f1); CACHE_BEFORE=${CACHE_BEFORE:-0}
FREE_BEFORE=$(df -m / | tail -1 | awk '{print $4}')
START=$(date +%s)

rm -f /tmp/measure.peak
( peak=0
  while :; do
    tot=0
    for p in $(pgrep -x zig 2>/dev/null); do
      r=$(awk '/^VmRSS:/ {print $2}' /proc/"$p"/status 2>/dev/null)
      tot=$(( tot + ${r:-0} ))
    done
    [ "$tot" -gt "$peak" ] && { peak=$tot; echo "$peak" > /tmp/measure.peak; }
    sleep 0.25
  done ) &
SAMPLER=$!

timeout "$TMO" "$@" >/tmp/b.log 2>&1
RC=$?

kill "$SAMPLER" 2>/dev/null
WALL=$(( $(date +%s) - START ))
CACHE_AFTER=$(du -sm .zig-cache 2>/dev/null | cut -f1); CACHE_AFTER=${CACHE_AFTER:-0}
FREE_AFTER=$(df -m / | tail -1 | awk '{print $4}')
PEAK_KB=$(cat /tmp/measure.peak 2>/dev/null); PEAK_MB=$(( ${PEAK_KB:-0} / 1024 ))

printf '%-44s rc=%-4s wall=%-5ss peakRSS=%-6sMB cache=%sMB (+%sMB) free=%sMB (-%sMB)\n' \
  "$LABEL" "$RC" "$WALL" "$PEAK_MB" \
  "$CACHE_AFTER" "$(( CACHE_AFTER - CACHE_BEFORE ))" \
  "$FREE_AFTER" "$(( FREE_BEFORE - FREE_AFTER ))" | tee -a /tmp/measure.log

exit $RC
