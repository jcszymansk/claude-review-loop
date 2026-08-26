#!/usr/bin/env bash
set -euo pipefail

CODEX_CONFIG="${HOME}/.codex/config.toml"

if [ ! -f "$CODEX_CONFIG" ]; then
  mkdir -p "$(dirname "$CODEX_CONFIG")"
  printf '[features]\nmulti_agent = true\n' > "$CODEX_CONFIG"
  echo "Created $CODEX_CONFIG with multi_agent enabled"
elif ! grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
  if grep -qE '^\[features\]' "$CODEX_CONFIG"; then
    if [ "$(uname)" = "Darwin" ]; then
      sed -i '' '/^\[features\]/a\'$'\n''multi_agent = true' "$CODEX_CONFIG"
    else
      sed -i '/^\[features\]/a multi_agent = true' "$CODEX_CONFIG"
    fi
  else
    printf '\n[features]\nmulti_agent = true\n' >> "$CODEX_CONFIG"
  fi
  echo "Enabled multi_agent in $CODEX_CONFIG"
fi
