#!/usr/bin/env bash
# Lifecycle test for bin/agent using a fake agent (no API usage).
# Run on the server. Uses a temp AGENTS_HOME and a throwaway repo; it does not
# touch ~/agents or ~/.claude.
set -euo pipefail

AGENT_BIN="${AGENT_BIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/agent}"
T="$(mktemp -d)"
export AGENTS_HOME="$T/agents"
A="$AGENT_BIN"
NAME=selftest-a

cleanup() {
  "$A" rm "$NAME" --force >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   - $*"; }

status_of() { "$A" ls | awk -v n="$1" '$1 == n { print $3 }'; }
wait_status() {
  local n="$1" want="$2" i
  for i in $(seq 1 30); do
    [[ "$(status_of "$n")" == "$want" ]] && return 0
    sleep 0.5
  done
  fail "$n: wanted status '$want', got '$(status_of "$n")'"
}

# Throwaway repo with a bare origin, so base-ref detection is exercised.
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
(
  cd "$T/repo"
  git checkout -q -b main
  echo "# selftest" > README.md
  git add . && git -c user.name=t -c user.email=t@t commit -qm init
  git push -q origin main
  git remote set-head origin main >/dev/null
)

# Fake agent: walks through working -> needs-you -> done, then sends Claude's
# idle reminder, which must not mask "done".
cat > "$T/fake.sh" <<EOF
#!/usr/bin/env bash
"$A" hook working; sleep 3
echo '{"message":"Claude needs your permission to use Bash"}' | "$A" hook needs-you; sleep 3
"$A" hook done; sleep 1
echo '{"message":"Claude is waiting for your input"}' | "$A" hook needs-you
sleep 60
EOF
chmod +x "$T/fake.sh"

out="$(AGENT_CMD="$T/fake.sh" "$A" new "$T/repo" "$NAME" "do a thing" 2>&1)"
grep -q "started '$NAME'" <<<"$out" || fail "agent new: $out"
pass "agent new"

wt="$AGENTS_HOME/work/repo-$NAME"
[[ -d "$wt" ]] || fail "worktree missing: $wt"
git -C "$wt" rev-parse --abbrev-ref HEAD | grep -qx "agent/$NAME" || fail "wrong branch"
pass "worktree on branch agent/$NAME"

git -C "$T/repo" config --get "branch.agent/$NAME.remote" >/dev/null 2>&1 && fail "branch should not track origin"
pass "branch has no upstream"

[[ -f "$wt/.claude/settings.local.json" ]] || fail "allowlist not copied"
[[ -z "$(git -C "$wt" status --porcelain)" ]] || fail "allowlist should be git-excluded"
pass "allowlist copied and git-excluded"

wait_status "$NAME" working;   pass "status: working"
wait_status "$NAME" needs-you; pass "status: needs-you"
wait_status "$NAME" done;      pass "status: done"
sleep 2
[[ "$(status_of "$NAME")" == done ]] || fail "idle reminder masked 'done'"
pass "idle reminder does not mask done"

"$A" log | grep -q "needs your permission" || fail "event not logged"
pass "events logged"

"$A" peek "$NAME" >/dev/null || fail "peek failed"
pass "peek"

git -C "$wt" switch -q -c rogue
[[ "$(status_of "$NAME")" == OFF-BRANCH ]] || fail "off-branch worktree not flagged (got '$(status_of "$NAME")')"
git -C "$wt" switch -q "agent/$NAME"
[[ "$(status_of "$NAME")" == done ]] || fail "status should recover once back on its branch"
pass "agent moved off its branch is flagged OFF-BRANCH"

echo x > "$wt/dirty.txt"
if "$A" rm "$NAME" >/dev/null 2>&1; then fail "rm should refuse a dirty worktree"; fi
pass "rm refuses dirty worktree"

"$A" rm "$NAME" --force >/dev/null || fail "rm --force failed"
[[ ! -d "$wt" ]] || fail "worktree not removed"
git -C "$T/repo" show-ref --verify --quiet "refs/heads/agent/$NAME" || fail "branch should be kept"
tmux has-session -t "agent-$NAME" 2>/dev/null && fail "tmux session still alive"
pass "rm --force removes worktree and session, keeps branch"

# Start guard: if the repo's default branch is the branch an agent would use,
# refuse before creating a worktree, state or session.
git -C "$T/repo" update-ref refs/remotes/origin/agent/guardtest HEAD
git -C "$T/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/agent/guardtest
if out="$(AGENT_CMD="$T/fake.sh" "$A" new "$T/repo" guardtest "x" 2>&1)"; then fail "agent started on a protected branch"; fi
grep -q "refusing" <<<"$out" || fail "guard message missing: $out"
[[ ! -e "$AGENTS_HOME/state/guardtest.env" ]] || fail "guard left state behind"
[[ ! -d "$AGENTS_HOME/work/repo-guardtest" ]] || fail "guard left a worktree behind"
tmux has-session -t agent-guardtest 2>/dev/null && fail "guard left a tmux session behind"
git -C "$T/repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
pass "agent refuses to start on the default branch"

echo "all passed"
