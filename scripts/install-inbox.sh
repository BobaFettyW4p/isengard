#!/usr/bin/env bash
# Install agent-inbox and its systemd user units, and create the inbox directories.
# Run on the host, outside any Claude sandbox. Safe to re-run.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
agents_home="${AGENTS_HOME:-$HOME/agents}"
unit_dir="$HOME/.config/systemd/user"

mkdir -p "$HOME/.local/bin" "$agents_home/inbox/requests" "$agents_home/inbox/claimed" \
         "$agents_home/inbox/results" "$unit_dir"
install -m 755 "$root/bin/agent-inbox" "$HOME/.local/bin/agent-inbox"
install -m 644 "$root"/systemd/agent-inbox.{service,path,timer} "$unit_dir/"
systemctl --user daemon-reload
systemctl --user enable --now agent-inbox.path agent-inbox.timer

echo "installed agent-inbox; units: $(systemctl --user is-active agent-inbox.path) (path), $(systemctl --user is-active agent-inbox.timer) (timer)"
echo "a repo accepts requests once it has repos/<repo>.md, a base clone, and repos/<repo>.conf (IMAGE=<image>)"
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]]; then
  echo "note: lingering is off, so the watcher stops when you log out; for a headless box run: loginctl enable-linger $USER"
fi
