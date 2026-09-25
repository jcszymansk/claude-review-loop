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
quarantine_file="${REVIEW_FILE}.reviewer-error.${quarantine_index}"
while [ -e "$quarantine_file" ]; do
  quarantine_index=$((quarantine_index + 1))
  quarantine_file="${REVIEW_FILE}.reviewer-error.${quarantine_index}"
done

mv -- "$SOURCE_FILE" "$quarantine_file"
printf '%s\n' "$quarantine_file"
