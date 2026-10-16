# Agent harness (v0)

`bin/agent` runs each Claude Code agent as **a git worktree plus a tmux session**. Watching an agent and
leaving it alone are the same thing: attach to look, detach to walk away. 2 to 4 agents at once is the intended range.

## Commands

```
agent new [--sandbox] <repo> <name> [task...]
                                    new agent; task becomes the first prompt
agent ls                            status, age and last output line for every agent
agent peek <name> [lines]           print recent terminal output without attaching
agent attach <name>                 attach to the tmux session (detach: Ctrl-b d)
agent diff <name>                   commits and changes on the agent's branch
agent push <name>                   push the agent's branch using the host's GitHub login
agent pr <name> [gh args]           push, then open a PR against the default branch
agent log [n]                       recent needs-you / done events
agent rm <name> [--force]           stop it, remove the worktree, keep the branch
agent setup                         create ~/agents, default allowlist, install hooks
agent image build                   build the sandbox image
agent token set|status|rm           manage the Claude token the sandbox uses
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
| `OFF-BRANCH` | The worktree is no longer on the agent's own branch | `agent ls`, checked live |

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

## Branch guard

Agents never start on the default branch. `agent new` refuses, before creating a worktree, state file or tmux
session, if the branch it would use is `main`, `master`, or the repo's default branch (from `origin/HEAD`).
After creating the worktree it also checks what git actually checked out; if that isn't the agent's own
`agent/<name>` branch, it removes the worktree and refuses.

The guard is at start time. If an agent later switches its worktree to another branch, `agent ls` shows it as
`OFF-BRANCH` (with the branch it's on) instead of its normal status. That is a visibility flag, not prevention;
`git push` isn't on the allowlist, so a push still stops at a prompt. For a hard stop, enable branch protection on
the default branch in GitHub so direct pushes are rejected.

## Sandbox mode (v1): `agent new --sandbox`

For real fire-and-forget. The agent runs in a rootless Podman container with **no permission prompts**
(`--dangerously-skip-permissions`), because the container is the boundary instead of the allowlist.
Sandboxed agents show as `repo[sb]` in `agent ls`; `attach`, `peek`, `ls` and `log` work the same way
(the container runs in the same tmux session).

One-time setup on the server:

```bash
scripts/install-agent.sh      # also copies the image sources to ~/agents/sandbox
agent image build             # about 1 GB: node, git, uv, ripgrep, python, claude
claude setup-token            # long-lived, inference-only token (needs a Claude subscription)
agent token set               # paste it; stored as a Podman secret, never on a command line
```

Then: `agent new --sandbox owner/repo fix-it "task..."`, watch with `agent peek`/`attach`, and when it's done
`agent diff fix-it` and `agent pr fix-it`.

**What the container has:** its own single-branch clone of the repo mounted at `/work`, a per-agent state
directory at `/agent-state` (status and events), and the Claude token as an environment variable.
**What it doesn't:** your home directory, the real repo, other agents' clones, SSH keys, GitHub credentials,
any host config. It runs as your uid (`--userns=keep-id`) with all capabilities dropped,
`no-new-privileges`, and limits of 8 GB RAM, 8 CPUs and 2048 processes (`AGENT_SANDBOX_MEM`, `AGENT_SANDBOX_CPUS`).

**Commit identity.** The container has no git config of its own, so without one every `git commit` inside it fails
with "Author identity unknown" (an early run hit exactly this: the agent staged its file, never committed, and still
reported done). `agent new --sandbox` therefore passes `GIT_AUTHOR_*` and `GIT_COMMITTER_*` into the container. By
default that is the host's `git config --global user.name` plus your GitHub noreply address
(`<id>+<login>@users.noreply.github.com`, looked up with `gh api user`), so commits link to your account and no
personal email lands in a public repo. Override with `AGENT_GIT_NAME` and `AGENT_GIT_EMAIL`. If it can't work out an
identity it refuses to start rather than launching an agent that can't commit.

**Getting work out.** The host never runs git inside an agent-controlled directory, because repo-local config
(`core.fsmonitor`, filters, hooks) can execute commands. Instead:

- `agent diff`, `push`, `pr` and `rm` first run a throwaway container (no network, only the clone mounted) that
  writes a `git bundle` of the agent's branch. The host fetches that bundle with `fetch.fsckObjects` on.
  A bundle is plain data, so nothing from the clone runs on the host.
- Only `refs/heads/agent/<name>` is imported. An agent that rewrites `main` inside its own clone changes nothing
  in the real repo (verified by `tests/sandbox.sh`).
- `agent push` and `agent pr` run on the host with your `gh` login and push only the agent's branch.
  GitHub credentials never enter the container, and a PR is always opened by you.
- `agent rm` pulls committed work into the host branch first, refuses if the clone has uncommitted changes
  (`--force` discards them), then removes the clone, container and state. The branch is kept.

**Status and events** come from `agent-hook` inside the image (the same hooks as v0), writing to
`~/agents/state/<name>.d/`, which `ls` and `log` read.

**Known limits of v1:**

- **Network is open** so installs and research work. A prompt-injected agent could send out anything it can
  see: the repo contents and the Claude token. The mitigation is that nothing else is in the sandbox.
- **The token is readable by the agent** (it needs it to call the API). It is inference-only and revocable;
  replace it with `claude setup-token` and `agent token set`.
- The helper containers for git run with SELinux labeling off so they can read a clone a running agent holds under
  a private label. They have no network and run only git.
- The image pins nothing but `latest`; rebuild with `agent image build` to update Claude Code.
- The sandbox starts with onboarding and folder trust pre-accepted in the image. That was checked up to the login
  step; confirm the first real run with a token reaches the prompt without a dialog.

## Folder trust

Claude Code asks "do you trust this folder?" the first time it runs in a repo. The answer is recorded against the
**main repo path**, so it happens once per repo, not per worktree (verified: a second worktree in the same repo skipped it).
For an untrusted repo, `agent new` marks the agent `needs-you` and prints a note; attach and accept once.

## Verified live

A real agent in a throwaway repo: wrote a file (auto-accepted), ran `date` (no prompt), and ended `done`. A follow-up
that ran `mkdir` flipped it to `needs-you` with the event logged; approving it returned it to `done`.
Claude Code auto-approves a few harmless read-only commands (such as `date`) on its own, so the allowlist only needs to
cover everything beyond those. The permission prompt also offers "always allow" and an "auto mode" option; v0 doesn't
use either.

## Known rough edges

- **"Last output" in `ls`** is scraped from Claude's terminal UI and is approximate. `peek` shows the real screen.
- **Some errors don't fire a hook.** An expired login left the status at `working` because `Stop` never ran. If an agent looks stuck, `peek` it.
- **Non-sandbox agents have no sandbox.** Their safety is the allowlist; use `--sandbox` for runs with no prompts.
- Agents share the server's single Claude login and usage limits, which is another reason to cap at 2 to 4.

## Testing

`tests/sandbox.sh` runs a scripted fake agent in a real container and checks isolation, hooks, bundle pull-back,
push (to a local bare origin) and teardown. It needs the image built.

`tests/lifecycle.sh` drives a fake agent through working, needs-you and done in a temp `AGENTS_HOME`, and checks the
worktree, branch, allowlist, statuses, idle-reminder handling, event log, `peek`, and `rm` (dirty refusal and `--force`).
It makes no API calls and does not touch `~/agents` or `~/.claude`.
