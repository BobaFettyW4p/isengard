#!/usr/bin/env bash
# Install bin/agent to ~/.local/bin and run first-time setup (directories,
# default allowlist, Claude Code hooks). Safe to re-run; backs up settings.json.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HOME/.local/bin"
install -m 755 "$root/bin/agent" "$HOME/.local/bin/agent"
"$HOME/.local/bin/agent" setup
echo "installed: $HOME/.local/bin/agent"
