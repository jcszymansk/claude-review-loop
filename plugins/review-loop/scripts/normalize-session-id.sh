#!/usr/bin/env bash
# Usage: normalize-session-id.sh <candidate>
#
# Prints the Claude Code session id when <candidate> is a plausible one, and
# nothing otherwise. The id ends up in the state file and in path lookups, so
# anything outside a conservative character set is dropped rather than escaped.
set -euo pipefail

candidate="${1:-}"
if [[ "$candidate" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
  printf '%s\n' "$candidate"
fi
