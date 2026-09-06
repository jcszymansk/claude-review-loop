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

GIT_INDEX_FILE="$INDEX_FILE" git add -A -- \
  . \
  ':(exclude)reviews/**' \
  ':(exclude).claude/review-loop*'
GIT_INDEX_FILE="$INDEX_FILE" git write-tree
