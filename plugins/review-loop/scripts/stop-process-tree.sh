#!/usr/bin/env bash
# Stops a process and all of its descendants: TERM first, then KILL for any
# process still alive after the grace period. When the root leads its own
# process group, every member of that group is included too, which also
# reaches descendants that were re-parented after their parent died.
#
# Usage: stop-process-tree.sh <pid> <grace-seconds>
#
# Prints one status line per action on stdout so callers can log them.
# Exit status: 0 when the tree was signalled and is gone, 1 when a process
# survived KILL, 2 on invalid arguments, 3 when nothing was running.
set -u

ROOT_PID="${1:-}"
GRACE_SECONDS="${2:-}"

case "$GRACE_SECONDS" in
  ''|*[!0-9]*)
    printf 'Usage: stop-process-tree.sh <pid> <grace-seconds>\n' >&2
    exit 2
    ;;
esac
case "$ROOT_PID" in
  ''|0*|1|*[!0-9]*)
    printf 'Usage: stop-process-tree.sh <pid> <grace-seconds>\n' >&2
    exit 2
    ;;
esac

process_table() {
  ps -e -o pid= -o ppid= -o pgid= -o stat= 2>/dev/null || true
}

ROOT_GROUP=""
if [ "$(ps -o pgid= -p "$ROOT_PID" 2>/dev/null | tr -d ' ')" = "$ROOT_PID" ]; then
  ROOT_GROUP="$ROOT_PID"
fi

# Space-separated PIDs that belong to the tree. It only grows: the tree is
# collected before any signal is sent, because a child whose parent dies is
# re-parented and can no longer be found by walking down from the root, and
# it is collected again before every check, so processes forked during the
# grace period are found through their surviving parents.
known_pids="$ROOT_PID"

refresh_known_pids() {
  known_pids=$(process_table | awk -v known="$known_pids" -v group="$ROOT_GROUP" -v self="$$" '
    BEGIN {
      count = split(known, initial, " ")
      for (i = 1; i <= count; i++) member[initial[i]] = 1
    }
    {
      pids[NR] = $1
      parent[$1] = $2
      process_group[$1] = $3
    }
    END {
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= NR; i++) {
          pid = pids[i]
          if (pid in member || pid == self || parent[pid] == self) continue
          if ((parent[pid] in member) || (group != "" && process_group[pid] == group)) {
            member[pid] = 1
            changed = 1
          }
        }
      }
      line = ""
      for (pid in member) line = line pid " "
      print line
    }')
}

# A zombie still exists until its parent reaps it, but it no longer runs
# anything, so it does not count.
running_pids() {
  process_table | awk -v known="$known_pids" '
    BEGIN {
      count = split(known, pids, " ")
      for (i = 1; i <= count; i++) member[pids[i]] = 1
    }
    ($1 in member) && $4 !~ /^Z/ { line = line $1 " " }
    END { sub(/ $/, "", line); print line }'
}

signal_known() {
  local signal="$1"
  local pid

  if [ -n "$ROOT_GROUP" ]; then
    kill "-$signal" -- "-$ROOT_GROUP" 2>/dev/null || true
  fi
  for pid in $known_pids; do
    kill "-$signal" "$pid" 2>/dev/null || true
  done
}

wait_for_exit() {
  local polls="$1"
  local survivors

  refresh_known_pids
  survivors=$(running_pids)
  while [ -n "$survivors" ] && [ "$polls" -gt 0 ]; do
    sleep 0.1
    polls=$((polls - 1))
    refresh_known_pids
    survivors=$(running_pids)
  done
  printf '%s' "$survivors"
}

# Survivors of TERM may keep forking. Stopping them first means the set of
# processes to KILL no longer grows while it is being collected.
freeze_known_pids() {
  local attempts=0
  local previous

  while [ "$attempts" -lt 10 ]; do
    attempts=$((attempts + 1))
    signal_known STOP
    previous="$known_pids"
    refresh_known_pids
    [ "$known_pids" = "$previous" ] && return 0
  done
}

refresh_known_pids
targets=$(running_pids)
if [ -z "$targets" ]; then
  printf 'process tree %s already exited\n' "$ROOT_PID"
  exit 3
fi

signal_known TERM
printf 'sent TERM to process tree %s (pids: %s)\n' "$ROOT_PID" "$targets"

survivors=$(wait_for_exit $((GRACE_SECONDS * 10)))
if [ -z "$survivors" ]; then
  printf 'process tree %s stopped after TERM\n' "$ROOT_PID"
  exit 0
fi

freeze_known_pids
survivors=$(running_pids)
signal_known KILL
printf 'escalated to KILL after %ss grace for pids: %s\n' "$GRACE_SECONDS" "$survivors"

survivors=$(wait_for_exit 10)
if [ -n "$survivors" ]; then
  printf 'processes still alive after KILL: %s\n' "$survivors"
  exit 1
fi
printf 'process tree %s stopped after KILL\n' "$ROOT_PID"
