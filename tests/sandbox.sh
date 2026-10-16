#!/usr/bin/env bash
# Sandbox test for bin/agent: runs a scripted fake agent inside a real container.
# Covers isolation, status hooks, pulling work back via bundle, push, and teardown.
# No API calls. Needs the image (agent image build); run on the server.
set -euo pipefail

AGENT_BIN="${AGENT_BIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/agent}"
T="$(mktemp -d)"
export AGENTS_HOME="$T/agents"
export AGENT_TOKEN_SECRET="isengard-test-token-$$"
export AGENT_SANDBOX_CMD="bash -c"
# The fake agent gets no git identity of its own: it must come from the sandbox setup.
export AGENT_GIT_NAME="Test Agent" AGENT_GIT_EMAIL="test-agent@example.invalid"
A="$AGENT_BIN"
NAME=sbtest
IMAGE="${AGENT_IMAGE:-isengard-agent}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   - $*"; }

podman image exists "$IMAGE" || fail "image '$IMAGE' not found; build it first (agent image build)"
printf dummy | podman secret create "$AGENT_TOKEN_SECRET" - >/dev/null

cleanup() {
  "$A" rm "$NAME" --force >/dev/null 2>&1 || true
  podman secret rm "$AGENT_TOKEN_SECRET" >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

status_of() { "$A" ls | awk -v n="$1" '$1 == n { print $3 }'; }
wait_status() {
  local n="$1" want="$2" i
  for i in $(seq 1 40); do
    [[ "$(status_of "$n")" == "$want" ]] && return 0
    sleep 0.5
  done
  fail "$n: wanted status '$want', got '$(status_of "$n")'"
}

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
ORIG_MAIN="$(git -C "$T/repo" rev-parse main)"

# The "agent": records what it can see, commits, tampers with a local ref, then
# walks through needs-you and done via the in-container hook.
read -r -d '' SCRIPT <<'EOF' || true
agent-hook working
{
  id -u
  echo "ssh:$(command -v ssh || echo none)"
  echo "ghdir:$(ls -d $HOME/.config/gh 2>/dev/null || echo none)"
  if [ -e @T@/repo ]; then echo "hostrepo:visible"; else echo "hostrepo:hidden"; fi
  echo "token:${CLAUDE_CODE_OAUTH_TOKEN:+set}"
  echo "origin:$(git config --get remote.origin.url)"
  echo "branch:$(git rev-parse --abbrev-ref HEAD)"
} > /agent-state/evidence
echo data > out.txt && git add out.txt && git commit -qm "agent work"
git branch -f main HEAD
echo '{"message":"Claude needs your permission to use Bash"}' | agent-hook needs-you
sleep 4
agent-hook done
sleep 120
EOF
SCRIPT="${SCRIPT//@T@/$T}"

out="$("$A" new --sandbox "$T/repo" "$NAME" "$SCRIPT" 2>&1)" || fail "agent new --sandbox: $out"
grep -q "started '$NAME' in a sandbox" <<<"$out" || fail "unexpected output: $out"
pass "agent new --sandbox"

clone="$AGENTS_HOME/work/repo-$NAME"
[[ -d "$clone/.git" ]] || fail "no clone at $clone"
[[ "$(stat -c %u "$clone")" == "$(id -u)" ]] || fail "clone not owned by the host user"
[[ ! -e "$clone/.claude" ]] || fail "allowlist should not be used in a sandbox"
pass "private clone owned by the host user"

wait_status "$NAME" needs-you; pass "status: needs-you (from in-container hook)"
wait_status "$NAME" done;      pass "status: done (from in-container hook)"
"$A" ls | grep -q "repo\[sb\]" || fail "ls should mark sandboxed agents"
pass "ls marks sandbox agents [sb]"

ev="$AGENTS_HOME/state/$NAME.d/evidence"
[[ -f "$ev" ]] || fail "no evidence file"
[[ "$(sed -n 1p "$ev")" == "$(id -u)" ]] || fail "container uid != host uid"
grep -qx "ssh:none" "$ev"           || fail "ssh client visible in sandbox"
grep -qx "ghdir:none" "$ev"         || fail "gh config visible in sandbox"
grep -qx "hostrepo:hidden" "$ev"    || fail "host repo path visible in sandbox"
grep -qx "token:set" "$ev"          || fail "Claude token not delivered"
grep -qx "origin:$T/origin.git" "$ev" || fail "origin not set to upstream: $(grep origin: "$ev")"
grep -qx "branch:agent/$NAME" "$ev" || fail "wrong branch in sandbox: $(grep branch: "$ev")"
pass "isolation: same uid, no ssh/gh, host repo hidden, token delivered, own branch"

"$A" log | grep -q "needs your permission" || fail "sandbox event not in log"
pass "events from the sandbox appear in agent log"

d="$("$A" diff "$NAME")"
grep -q "agent work" <<<"$d" || fail "diff missing commit: $d"
grep -q "out.txt" <<<"$d"    || fail "diff missing file: $d"
[[ "$(git -C "$T/repo" log -1 --format=%s "agent/$NAME")" == "agent work" ]] || fail "work not pulled into host branch"
want_id="Test Agent <test-agent@example.invalid>"
[[ "$(git -C "$T/repo" log -1 --format='%an <%ae>' "agent/$NAME")" == "$want_id" ]] || fail "commit author is not the sandbox identity"
[[ "$(git -C "$T/repo" log -1 --format='%cn <%ce>' "agent/$NAME")" == "$want_id" ]] || fail "committer is not the sandbox identity"
[[ "$(git -C "$T/repo" rev-parse main)" == "$ORIG_MAIN" ]] || fail "host main was changed"
pass "work pulled back as host branch; host main untouched despite tampering in the clone"

"$A" push "$NAME" >/dev/null 2>&1 || fail "agent push failed"
[[ "$(git -C "$T/origin.git" rev-parse "agent/$NAME")" == "$(git -C "$T/repo" rev-parse "agent/$NAME")" ]] || fail "branch not on origin"
[[ "$(git -C "$T/origin.git" rev-parse main)" == "$ORIG_MAIN" ]] || fail "push changed origin main"
pass "agent push sends only the agent branch"

echo x > "$clone/dirty.txt"
if "$A" rm "$NAME" >/dev/null 2>&1; then fail "rm should refuse a dirty sandbox clone"; fi
pass "rm refuses a dirty sandbox clone"

"$A" rm "$NAME" --force >/dev/null || fail "rm --force failed"
[[ ! -d "$clone" ]] || fail "clone not removed"
[[ ! -e "$AGENTS_HOME/state/$NAME.d" ]] || fail "state dir not removed"
podman container exists "agent-$NAME" && fail "container still exists"
tmux has-session -t "agent-$NAME" 2>/dev/null && fail "tmux session still alive"
git -C "$T/repo" show-ref --verify --quiet "refs/heads/agent/$NAME" || fail "branch should be kept"
pass "rm --force removes clone, container and session; keeps the branch"

echo "all passed"
