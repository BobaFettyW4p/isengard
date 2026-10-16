# Docs audit findings

Statements in the docs that disagree with `bin/agent` or `README.md`. `docs/server-setup.md` has none: it covers
host configuration, not `agent` or the README's claims.

1. `docs/agent-harness.md`, "What `agent new` does", step 2: says the worktree is always created on a new branch from
   the remote's default branch (`origin/HEAD`). `base_ref` falls back to the repo's current `HEAD` when there is no
   `origin` or `origin/HEAD` is unset. If `agent/<name>` already exists, `cmd_new` reuses it with
   `worktree add "$wt" "$branch"` instead of creating it.

2. `docs/agent-harness.md`, "What `agent new` does", step 3: says it copies `~/agents/allowlist.json` to the
   worktree's `.claude/settings.local.json`. The copy only happens if that file doesn't already exist
   (`[[ -e ... ]] || cp`), so an existing one is left alone.

3. `docs/agent-harness.md`, "Getting work out": says the throwaway container has "no network, only the clone mounted".
   That holds for `sb_git`. `sb_pull`, which `diff`, `push`, `pr` and `rm` use to write the bundle, also mounts the
   agent's state directory at `/out`.

4. `docs/agent-harness.md`, title "Agent harness (v0)": the document also describes v1 (`--sandbox`, tokens, image
   build), which the README lists as implemented. The "(v0)" title and the "v0 has no sandbox" line in the
   Permissions section are out of date for the tool as shipped.

5. `docs/agent-harness.md`, "Branch guard": says `agent new` refuses "before creating a worktree, state file or tmux
   session". For `--sandbox` the only pre-creation check is on `agent/<name>` itself. The post-checkout check runs
   after the host branch and clone already exist, and on failure it removes the clone but leaves the branch created
   in the host repo.

6. `docs/agent-harness.md`, Statuses table, `OFF-BRANCH` row ("checked live", set by `agent ls`): `cmd_ls` skips this
   check for sandbox agents (`if ! is_sandbox`), so sandboxed agents can never show `OFF-BRANCH`. The docs imply it
   applies to every agent.
