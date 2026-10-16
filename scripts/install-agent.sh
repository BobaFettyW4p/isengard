#!/usr/bin/env bash
# Install bin/agent to ~/.local/bin, copy the sandbox image sources to ~/agents/sandbox,
# and run first-time setup (directories, default allowlist, Claude Code hooks).
# Safe to re-run; backs up settings.json.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
agents_home="${AGENTS_HOME:-$HOME/agents}"

mkdir -p "$HOME/.local/bin" "$agents_home"
install -m 755 "$root/bin/agent" "$HOME/.local/bin/agent"
rm -rf "$agents_home/sandbox"
cp -r "$root/sandbox" "$agents_home/sandbox"
"$HOME/.local/bin/agent" setup
echo "installed: $HOME/.local/bin/agent (sandbox sources in $agents_home/sandbox)"
echo "for --sandbox agents: agent image build && agent token set"
