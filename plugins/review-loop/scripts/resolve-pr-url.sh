#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <pull request URL>\n' "${0##*/}" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

PR_URL="$1"
if [[ ! "$PR_URL" =~ ^(https?)://([A-Za-z0-9.-]+(:[0-9]+)?)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(pull|pulls)/([0-9]+)/?$ ]]; then
  printf 'Invalid pull request URL: %s\n' "$PR_URL" >&2
  exit 1
fi

SCHEME="${BASH_REMATCH[1]}"
HOST="${BASH_REMATCH[2]}"
OWNER="${BASH_REMATCH[4]}"
REPOSITORY="${BASH_REMATCH[5]}"
ACTION="${BASH_REMATCH[6]}"
NUMBER="${BASH_REMATCH[7]}"

HOST_LOWER="$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')"
case "$HOST_LOWER" in
  github.com)
    if [ "$ACTION" != "pull" ] || [ "$SCHEME" != "https" ]; then
      printf 'GitHub pull request URLs must use https://github.com/.../pull/<number>: %s\n' "$PR_URL" >&2
      exit 1
    fi
    PROVIDER=github
    ;;
  *)
    if [ "$ACTION" != "pull" ] && [ "$ACTION" != "pulls" ]; then
      printf 'Gitea pull request URLs must use /pull/<number> or /pulls/<number>: %s\n' "$PR_URL" >&2
      exit 1
    fi
    PROVIDER=gitea
    ;;
esac

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$PROVIDER" "$SCHEME" "$HOST" "$OWNER" "$REPOSITORY" "$NUMBER"
