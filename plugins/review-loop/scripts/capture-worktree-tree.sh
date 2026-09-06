#!/usr/bin/env bash
set -euo pipefail

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

INDEX_FILE="$(mktemp "${TMPDIR:-/tmp}/review-loop-index.XXXXXX")"
rm -f "$INDEX_FILE"
trap 'rm -f "$INDEX_FILE"' EXIT

if git rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
  GIT_INDEX_FILE="$INDEX_FILE" git read-tree HEAD
else
  GIT_INDEX_FILE="$INDEX_FILE" git read-tree --empty
fi

# When either artifact path is already ignored, pairing "." with an exclude
# makes git treat the ignored entry as explicitly named and fail. Fall back to
# adding the invocation directory and then resetting the artifact globs, which
# preserves scope and exclusions while staying ignore-safe.
if ! GIT_INDEX_FILE="$INDEX_FILE" git add -A -- \
  . \
  ':(exclude)reviews/**' \
  ':(exclude).claude/review-loop*' 2>/dev/null; then
  GIT_INDEX_FILE="$INDEX_FILE" git add -A -- .
  GIT_INDEX_FILE="$INDEX_FILE" git reset -- ':(glob)reviews/**' ':(glob).claude/review-loop*'
fi
GIT_INDEX_FILE="$INDEX_FILE" git write-tree
