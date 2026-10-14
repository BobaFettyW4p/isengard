# isengard

A home server for running long-lived coding agents, plus the small tool used to manage them.

The server is an old desktop (Ryzen 9 5900X, 31 GB RAM, RTX 3060 Ti 8 GB, Fedora) turned into a headless box.
It is reached over Tailscale and runs Claude Code agents, each in its own git worktree and tmux session.

## Layout

| Path | What it is |
|---|---|
| [`bin/agent`](bin/agent) | The agent manager (bash). One worktree + tmux session per agent. |
| [`scripts/install-agent.sh`](scripts/install-agent.sh) | Installs `agent` to `~/.local/bin` and runs first-time setup. |
| [`tests/lifecycle.sh`](tests/lifecycle.sh) | End-to-end test of `agent` using a fake agent (no API usage). |
| [`docs/server-setup.md`](docs/server-setup.md) | Runbook: how the server was set up, in order, with the gotchas. |
| [`docs/agent-harness.md`](docs/agent-harness.md) | How `agent` works: statuses, hooks, allowlist, limits, rough edges. |
| [`docs/local-models.md`](docs/local-models.md) | What fits in 8 GB of VRAM, and what hardware upgrades would change. |
| [`docs/roadmap.md`](docs/roadmap.md) | What's next and open questions. |

## Quick start (on the server)

```bash
scripts/install-agent.sh          # one time
claude                            # then /login, once, if the login has expired
gh auth login                     # once, for cloning and pushing

agent new owner/repo fix-bug "Fix the failing test in tests/test_x.py"
agent ls                          # status of every agent
agent peek fix-bug                # glance at recent output
agent attach fix-bug              # watch live (detach: Ctrl-b d)
agent diff fix-bug                # what it changed
agent rm fix-bug                  # stop it, remove the worktree (branch kept)
```

Run the self-test any time with `tests/lifecycle.sh`.

## Status

v0 works end to end with a fake agent. A live Claude run is pending a fresh `/login` on the server.
See the [roadmap](docs/roadmap.md).
