# isengard

A home server for running long-lived coding agents, plus the small tool used to manage them.

The server is an old desktop (Ryzen 9 5900X, 31 GB RAM, RTX 3060 Ti 8 GB, Fedora) turned into a headless box.
It is reached over Tailscale and runs Claude Code agents, each in its own git worktree and tmux session.

## Layout

| Path | What it is |
|---|---|
| [`bin/agent`](bin/agent) | The agent manager (bash). One worktree + tmux session per agent. |
| [`sandbox/`](sandbox) | Image sources for sandboxed agents (Containerfile, in-container hook, baked Claude config). |
| [`scripts/install-agent.sh`](scripts/install-agent.sh) | Installs `agent` to `~/.local/bin`, copies the sandbox sources, runs first-time setup. |
| [`tests/lifecycle.sh`](tests/lifecycle.sh) | End-to-end test of `agent` using a fake agent (no API usage). |
| [`tests/sandbox.sh`](tests/sandbox.sh) | Same for `--sandbox`: a fake agent in a real container. |
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

# unattended, in a container with no prompts and no GitHub credentials:
agent new --sandbox owner/repo fix-bug2 "Fix it"
agent pr fix-bug2                 # pull its work out, push the branch, open a PR
```

For long prompts, pass `-` as the task and the prompt is read from stdin, so you can write it in any editor on your laptop:

```bash
ssh perseus agent new --sandbox owner/repo fix-bug - < prompt.md
```

A small shell function makes this a habit (in your laptop's `~/.zshrc`; opens `$EDITOR`, then sends the result;
`$EDITOR` must block until the file is closed, e.g. `code --wait`):

```bash
anew() { f=$(mktemp); ${VISUAL:-${EDITOR:-vi}} "$f" && [ -s "$f" ] && ssh perseus agent new "$@" - < "$f"; rm -f "$f"; }   # anew -s owner/repo name
alias pa='ssh -t perseus agent'     # pa ls, pa attach fix-bug, pa pr fix-bug
```

Run the self-tests any time with `tests/lifecycle.sh` and `tests/sandbox.sh`.

## Status

v0 works end to end, including a live Claude agent on the server (status hooks, permission stops, cleanup).
v1 (`--sandbox`) works with a scripted agent in a real container; a live run needs a Claude token (`agent token set`).
See the [roadmap](docs/roadmap.md).
