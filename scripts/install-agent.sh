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
# Record what is installed and where it came from, for 'agent update'.
if rev="$(git -C "$root" rev-parse HEAD 2>/dev/null)"; then echo "$rev" > "$agents_home/version"; fi
if src="$(git -C "$root" remote get-url origin 2>/dev/null)"; then echo "$src" > "$agents_home/source"; fi
"$HOME/.local/bin/agent" setup
echo "installed: $HOME/.local/bin/agent (sandbox sources in $agents_home/sandbox)"
echo "for --sandbox agents: agent image build && agent token set"
