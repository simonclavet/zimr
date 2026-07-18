#!/usr/bin/env sh
# release.sh - rebuild prebuilt/ at ReleaseSmall and push to Codeberg.
#
# Usage:  ./release.sh ["commit message"]
#
# Steps:
#   1. zig build -Drelease=true dist  (refreshes prebuilt/)
#   2. git add prebuilt/ && commit + push (only if prebuilt/ changed)
#
# If the working tree isn't a git repo yet, step 1 still runs and
# step 2 is skipped with a note.

set -eu

zig build -Drelease=true dist

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo
    echo "prebuilt/ refreshed.  Not a git repo - skipping commit/push."
    echo "Initialize git + add the Codeberg remote, then re-run."
    exit 0
fi

git add prebuilt/

if git diff --cached --quiet; then
    echo
    echo "prebuilt/ unchanged - nothing to commit."
    exit 0
fi

MSG="${1:-Refresh prebuilt gallery}"
git commit -m "$MSG"
git push
