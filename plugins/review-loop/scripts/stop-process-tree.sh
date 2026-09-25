#!/usr/bin/env bash
# Stops a process and all of its descendants: TERM first, then KILL for any
# process still alive after the grace period.
#
# Usage: stop-process-tree.sh <pid> <grace-seconds>
#
# Prints one status line per action on stdout so callers can log them.
# Exits 0 when the tree is gone, 1 when a process survived KILL, and 2 on
# invalid arguments.
set -u

ROOT_PID="${1:-}"
GRACE_SECONDS="${2:-}"

valid_pid() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 1 ] 2>/dev/null
}

case "$GRACE_SECONDS" in
  ''|*[!0-9]*)
    printf 'Usage: stop-process-tree.sh <pid> <grace-seconds>\n' >&2
    exit 2
    ;;
esac
if ! valid_pid "$ROOT_PID"; then
  printf 'Usage: stop-process-tree.sh <pid> <grace-seconds>\n' >&2
  exit 2
fi

child_pids() {
  local parent="$1"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$parent" 2>/dev/null || true
  else
    ps -e -o pid= -o ppid= 2>/dev/null |
      awk -v parent="$parent" '$2 == parent {print $1}' || true
  fi
}

# Children are listed before their parent. The whole tree is collected before
# any signal is sent, because a child whose parent dies is re-parented and can
# no longer be found by walking down from the root.
collect_process_tree() {
  local pid="$1"
  local child

  while IFS= read -r child; do
    [ -n "$child" ] || continue
    collect_process_tree "$child"
  done < <(child_pids "$pid")

  if [ "$pid" -ne "$$" ] && kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "$pid"
  fi
}

tree_pids=()
while IFS= read -r pid; do
  tree_pids+=("$pid")
done < <(collect_process_tree "$ROOT_PID")

if [ "${#tree_pids[@]}" -eq 0 ]; then
  printf 'process tree %s already exited\n' "$ROOT_PID"
  exit 0
fi

# A zombie still answers kill -0 until its parent reaps it, but it no longer
# runs anything, so it does not count as a survivor.
is_running() {
  local pid="$1"
  local state

  kill -0 "$pid" 2>/dev/null || return 1
  state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
  case "$state" in
    ''|Z*) return 1 ;;
  esac
}

alive_pids() {
  local pid
  for pid in "${tree_pids[@]}"; do
    if is_running "$pid"; then
      printf '%s ' "$pid"
    fi
  done
}

for pid in "${tree_pids[@]}"; do
  kill -TERM "$pid" 2>/dev/null || true
done
printf 'sent TERM to process tree %s (pids: %s)\n' "$ROOT_PID" "${tree_pids[*]}"

remaining_polls=$((GRACE_SECONDS * 10))
survivors=$(alive_pids)
while [ -n "$survivors" ] && [ "$remaining_polls" -gt 0 ]; do
  sleep 0.1
  remaining_polls=$((remaining_polls - 1))
  survivors=$(alive_pids)
done

if [ -z "$survivors" ]; then
  printf 'process tree %s stopped after TERM\n' "$ROOT_PID"
  exit 0
fi

for pid in $survivors; do
  kill -KILL "$pid" 2>/dev/null || true
done
printf 'escalated to KILL after %ss grace for pids: %s\n' "$GRACE_SECONDS" "${survivors% }"

remaining_polls=10
survivors=$(alive_pids)
while [ -n "$survivors" ] && [ "$remaining_polls" -gt 0 ]; do
  sleep 0.1
  remaining_polls=$((remaining_polls - 1))
  survivors=$(alive_pids)
done

if [ -n "$survivors" ]; then
  printf 'processes still alive after KILL: %s\n' "${survivors% }"
  exit 1
fi
printf 'process tree %s stopped after KILL\n' "$ROOT_PID"
