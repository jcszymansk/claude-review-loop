---
description: "Cancel an active review loop"
allowed-tools:
  - Bash
  - Read
---

Run the cancellation helper:

```bash
SESSION_ID="${CLAUDE_SESSION_ID}"
"${CLAUDE_PLUGIN_ROOT}/scripts/cancel-review-loop.sh" "${SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
```

The helper finds this session's review loop wherever it was started, or else
the loop in the current directory. It stops the active reviewer process and
its children, then removes the runtime state, the generated reviewer files
and the loop's session registry entry, and reports the phase and review ID
the loop was at.
Leave `reviews/<review_id>/` untouched. It contains the review history and
must remain available after cancellation.

Report the helper output. If no review loop was active, it reports:
"No active review loop found."
