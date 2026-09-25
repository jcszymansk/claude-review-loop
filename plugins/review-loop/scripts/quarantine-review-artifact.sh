#!/usr/bin/env bash
# Moves a failed review artifact out of the canonical review path to the
# first free `<review-file>.reviewer-error.<n>` name and prints that name.
#
# Usage: quarantine-review-artifact.sh <review-file> [source-file]
#
# The source defaults to the review file itself. A different source (such as
# a leftover stdout capture) is numbered in the same sequence, so every failed
# attempt of a round stays side by side.
set -euo pipefail

REVIEW_FILE="${1:-}"
SOURCE_FILE="${2:-$REVIEW_FILE}"

if [ -z "$REVIEW_FILE" ]; then
  printf 'Usage: quarantine-review-artifact.sh <review-file> [source-file]\n' >&2
  exit 2
fi
if [ ! -f "$SOURCE_FILE" ]; then
  printf 'Error: review artifact to quarantine does not exist: %s\n' "$SOURCE_FILE" >&2
  exit 1
fi

quarantine_index=1
# mv -n never replaces an existing file, so a name taken by a concurrent
# quarantine between the check and the move leaves the source in place and
# the next number is tried. Its exit status differs between GNU and BSD, so
# success is judged by the source being gone.
while [ "$quarantine_index" -le 1000 ]; do
  quarantine_file="${REVIEW_FILE}.reviewer-error.${quarantine_index}"
  if [ ! -e "$quarantine_file" ]; then
    mv -n -- "$SOURCE_FILE" "$quarantine_file" 2>/dev/null || true
    if [ ! -e "$SOURCE_FILE" ] && [ -f "$quarantine_file" ]; then
      printf '%s\n' "$quarantine_file"
      exit 0
    fi
  fi
  quarantine_index=$((quarantine_index + 1))
done

printf 'Error: no free quarantine name for %s\n' "$REVIEW_FILE" >&2
exit 1
