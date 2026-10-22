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

# Task from stdin ("-"): arrives intact however long or oddly quoted; empty is refused.
cat > "$T/argv.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" > "$T/argv.out"
sleep 60
EOF
chmod +x "$T/argv.sh"
prompt=$'multi-line "quoted" $HOME `ticks` \'single\'\nsecond line'
printf '%s\n' "$prompt" | AGENT_CMD="$T/argv.sh" "$A" new "$T/repo" stdintest - >/dev/null 2>&1 || fail "agent new with stdin task"
for i in $(seq 1 30); do [[ -s "$T/argv.out" ]] && break; sleep 0.5; done
[[ "$(cat "$T/argv.out")" == "$prompt" ]] || fail "stdin task mangled: $(cat "$T/argv.out")"
"$A" rm stdintest --force >/dev/null 2>&1 || true
if out="$(printf '  \n' | AGENT_CMD="$T/argv.sh" "$A" new "$T/repo" emptytest - 2>&1)"; then fail "empty stdin task accepted"; fi
grep -q "empty task" <<<"$out" || fail "empty-task message missing: $out"
[[ ! -e "$AGENTS_HOME/state/emptytest.env" ]] || fail "empty task left state behind"
pass "agent new - reads the task from stdin"

# --file: same payload from a file; --edit: from an editor (needs a tty, so run under a pty).
rm -f "$T/argv.out"
printf '%s\n' "$prompt" > "$T/prompt.md"
AGENT_CMD="$T/argv.sh" "$A" new --file "$T/prompt.md" "$T/repo" filetest >/dev/null 2>&1 || fail "agent new --file"
for i in $(seq 1 30); do [[ -s "$T/argv.out" ]] && break; sleep 0.5; done
[[ "$(cat "$T/argv.out")" == "$prompt" ]] || fail "--file task mangled: $(cat "$T/argv.out")"
"$A" rm filetest --force >/dev/null 2>&1 || true
pass "agent new --file reads the task from a file"

if command -v python3 >/dev/null 2>&1; then
  rm -f "$T/argv.out"
  printf '#!/usr/bin/env bash\ncp %q "$1"\n' "$T/prompt.md" > "$T/editor.sh"; chmod +x "$T/editor.sh"
  EDITOR="$T/editor.sh" AGENT_CMD="$T/argv.sh" python3 -c 'import pty,sys,os; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$A" new --edit "$T/repo" edittest >/dev/null 2>&1 || fail "agent new --edit"
  for i in $(seq 1 30); do [[ -s "$T/argv.out" ]] && break; sleep 0.5; done
  [[ "$(cat "$T/argv.out")" == "$prompt" ]] || fail "--edit task mangled: $(cat "$T/argv.out")"
  "$A" rm edittest --force >/dev/null 2>&1 || true
  pass "agent new --edit runs the editor and uses its result"
fi

# clean: only agents whose merged PR ends exactly at the branch tip are removed.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--state merged"* && -n "${GH_FAKE_SHA:-}" ]]; then echo "$GH_FAKE_SHA"; fi
exit 0
EOF
chmod +x "$T/bin/gh"
for n in cleana cleanb; do AGENT_CMD="$T/argv.sh" "$A" new "$T/repo" "$n" x >/dev/null 2>&1 || fail "agent new $n"; done
git -C "$AGENTS_HOME/work/repo-cleana" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
tip_a="$(git -C "$T/repo" rev-parse refs/heads/agent/cleana)"
out="$(PATH="$T/bin:$PATH" "$A" clean 2>&1)"
grep -q "keep  cleana" <<<"$out" || fail "clean should keep unmerged cleana: $out"
[[ -e "$AGENTS_HOME/state/cleana.env" ]] || fail "clean removed an unmerged agent"
pass "clean keeps agents with no merged PR"
out="$(GH_FAKE_SHA="$tip_a" PATH="$T/bin:$PATH" "$A" clean -n 2>&1)"
grep -q "would clean cleana" <<<"$out" || fail "dry run: $out"
grep -q "keep  cleanb" <<<"$out" || fail "dry run should keep cleanb: $out"
[[ -e "$AGENTS_HOME/state/cleana.env" ]] || fail "dry run removed an agent"
pass "clean -n changes nothing"
out="$(GH_FAKE_SHA="$tip_a" PATH="$T/bin:$PATH" "$A" clean 2>&1)"
grep -q "cleaned cleana" <<<"$out" || fail "clean: $out"
[[ ! -e "$AGENTS_HOME/state/cleana.env" && ! -d "$AGENTS_HOME/work/repo-cleana" ]] || fail "cleana not removed"
git -C "$T/repo" show-ref --verify --quiet refs/heads/agent/cleana && fail "cleana branch not deleted"
[[ -e "$AGENTS_HOME/state/cleanb.env" ]] || fail "clean removed cleanb, whose PR does not match its tip"
"$A" rm cleanb --force >/dev/null 2>&1 || true
pass "clean removes merged agents and their branch, keeps the rest"

echo "all passed"
