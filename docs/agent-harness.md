# Agent harness (v0)

`bin/agent` runs each Claude Code agent as **a git worktree plus a tmux session**. Watching an agent and
leaving it alone are the same thing: attach to look, detach to walk away. 2 to 4 agents at once is the intended range.

## Commands

```
agent new <repo> <name> [task...]   new agent; task becomes the first prompt
agent ls                            status, age and last output line for every agent
agent peek <name> [lines]           print recent terminal output without attaching
agent attach <name>                 attach to the tmux session (detach: Ctrl-b d)
agent diff <name>                   commits and changes on the agent's branch
agent log [n]                       recent needs-you / done events
agent rm <name> [--force]           stop it, remove the worktree, keep the branch
agent setup                         create ~/agents, default allowlist, install hooks
```

`<repo>` can be `owner/name` (cloned with `gh`), a git URL, a name already under `~/agents/repos`, or a path to a local repo.
`<name>` is `[a-z0-9-]+`. Set `AGENT_CMD` to run something other than `claude` (the self-test uses this).

## What `agent new` does

1. Resolves or clones the repo into `~/agents/repos/<repo>`.
2. Creates a worktree at `~/agents/work/<repo>-<name>` on a new branch `agent/<name>`, from the remote's default branch
   (`origin/HEAD`), with **no upstream**, so a plain `git push` behaves.
3. Copies `~/agents/allowlist.json` to the worktree's `.claude/settings.local.json` and adds that path to the repo's
   `info/exclude`, so it never shows up in git.
4. Starts `claude` in a detached tmux session `agent-<name>` under `systemd-run --user --scope` with
   `MemoryMax=8G` and `CPUQuota=800%` (override with `AGENT_MEM_MAX`, `AGENT_CPU_QUOTA`). A runaway agent is
   killed instead of taking the machine down.
5. Passes `AGENT_NAME` and `AGENTS_HOME` into the session so hooks know which agent they belong to.

## Statuses

| Status | Meaning | Set by |
|---|---|---|
| `working` | Running a prompt or tool | `UserPromptSubmit` and `PostToolUse` hooks |
| `needs-you` | Waiting on a permission prompt or question | `Notification` hook; also set at launch for a repo Claude hasn't trusted yet |
| `done` | Finished its turn | `Stop` hook |
| `exited` | The process ended (the tmux pane is kept) | tmux pane state |
| `gone` | The tmux session no longer exists | tmux |

Claude's own "waiting for your input" idle reminder arrives as a `Notification` too; `agent hook` ignores it so it
doesn't overwrite `done`.

`agent setup` merges the four hooks into `~/.claude/settings.json` (existing settings are preserved, a timestamped
backup is made, and it is idempotent). Hooks do nothing for Claude sessions not started by `agent`, because they
check for `AGENT_NAME`.

State lives in `~/agents/state/<name>.env` and `<name>.status`; events in `~/agents/events.log`.

## Permissions: the allowlist

v0 has no sandbox. Safety comes from **pre-approving only safe commands and letting everything else stop and wait for you**:

```json
{
  "permissions": {
    "defaultMode": "acceptEdits",
    "allow": [
      "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
      "Bash(git add:*)", "Bash(git commit:*)", "Bash(ls:*)", "Bash(grep:*)", "Bash(rg:*)",
      "Bash(pytest:*)", "Bash(uv run pytest:*)", "Bash(ruff:*)", "Bash(uv run ruff:*)",
      "Bash(npm test:*)", "Bash(npm run test:*)", "Bash(npm run lint:*)", "Bash(npm run build:*)",
      "Bash(make test:*)"
    ]
  }
}
```

File edits inside the worktree are auto-accepted. `git push`, installs, network access and anything unlisted prompt.
That is what makes "fire and forget" workable: an agent works as far as the allowlist goes, then blocks on a prompt
instead of doing something risky. Edit `~/agents/allowlist.json` to change the default for new worktrees.

## Folder trust

Claude Code asks "do you trust this folder?" the first time it runs in a repo. The answer is recorded against the
**main repo path**, so it happens once per repo, not per worktree (verified: a second worktree in the same repo skipped it).
For an untrusted repo, `agent new` marks the agent `needs-you` and prints a note; attach and accept once.

## Known rough edges

- **"Last output" in `ls`** is scraped from Claude's terminal UI and is approximate. `peek` shows the real screen.
- **Some errors don't fire a hook.** An expired login left the status at `working` because `Stop` never ran. If an agent looks stuck, `peek` it.
- **No sandbox.** Fully unattended runs with no prompts need the container sandbox (see the roadmap).
- Agents share the server's single Claude login and usage limits, which is another reason to cap at 2 to 4.

## Testing

`tests/lifecycle.sh` drives a fake agent through working, needs-you and done in a temp `AGENTS_HOME`, and checks the
worktree, branch, allowlist, statuses, idle-reminder handling, event log, `peek`, and `rm` (dirty refusal and `--force`).
It makes no API calls and does not touch `~/agents` or `~/.claude`.
