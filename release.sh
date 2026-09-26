#!/usr/bin/env sh
# release.sh - rebuild prebuilt/, publish it to the orphan `pages` branch.
#
# Usage:  ./release.sh
#
# POSIX twin of release.bat; keep the two in step.
#
# main stays source-only: prebuilt/ is gitignored and never committed to
# main.  This script builds prebuilt/, then publishes ITS CONTENTS to a
# single-commit (orphan) `pages` branch and force-pushes it.  Because the
# branch is rewritten from scratch each run, history never accumulates -
# the gallery costs one copy on the remote instead of growing main.
#
# GitHub Pages serves the `pages` branch (Settings -> Pages -> Deploy from
# a branch -> `pages`, `/ (root)`) at
#   https://simonclavet.github.io/zimr/
# `zig build dist` writes a `.nojekyll` marker into prebuilt/ so Pages
# serves the files as-is instead of running them through Jekyll.
#
# GitHub limits: 100 MB per file (warns above 50 MB), 1 GB per Pages site.
# The API docs (`zig build docs`) are local-only for that reason: their
# sources.tar is ~100 MB, so `dist` leaves docs/ out of prebuilt/.
#
# Source commits to main are a separate, manual concern - this script does
# not touch main.  Requires the GitHub remote set up as `origin`
# (https://github.com/simonclavet/zimr.git).

set -eu

zig build -Dmode=release dist

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo
    echo "prebuilt/ refreshed.  Not a git repo - skipping pages publish."
    echo "Initialize git + add the GitHub remote, then re-run."
    exit 0
fi

if [ ! -d prebuilt ]; then
    echo
    echo "prebuilt/ not found after build - aborting."
    exit 1
fi

echo
echo "Publishing prebuilt/ to the orphan \`pages\` branch..."

# Build the pages commit off to the side using a throwaway index file, so
# neither the working tree nor main's index is ever touched.
pages_index=$(mktemp)
rm -f "$pages_index"
trap 'rm -f "$pages_index"' EXIT

# Force past .gitignore - prebuilt/ is ignored on purpose.
GIT_INDEX_FILE="$pages_index" git add -f -A -- prebuilt

# Write the staged tree, then pull out just the prebuilt/ subtree so its
# CONTENTS (index.html, wasm, ...) sit at the branch root, not under a
# prebuilt/ subdir.
full_tree=$(GIT_INDEX_FILE="$pages_index" git write-tree)
pages_tree=$(git rev-parse "$full_tree:prebuilt")

# Root commit (no -p parent) => orphan branch tip, no history growth.
pages_commit=$(git commit-tree "$pages_tree" -m "Update pages gallery")

# Force-replace the remote pages branch with our fresh orphan commit.
if ! git push origin "$pages_commit:refs/heads/pages" --force; then
    echo
    echo "pages push failed.  Retry:"
    echo "    git push origin $pages_commit:refs/heads/pages --force"
    exit 1
fi

echo
echo "Release complete.  pages branch updated (main untouched)."
echo "Live gallery: https://simonclavet.github.io/zimr/"
