#!/usr/bin/env bash
# Test for bin/agent-inbox with a fake `agent` (no podman, tmux, network or API usage).
# Uses a temp AGENTS_HOME; it does not touch ~/agents.
set -euo pipefail

BIN="${INBOX_BIN:-$(cd "$(dirname "$0")/.." && pwd)/bin/agent-inbox}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export AGENTS_HOME="$T/agents"
export INBOX_WRAPPER=""
export AGENT_BIN="$T/fake-agent"
CALLS="$T/calls"
ACTIVE="$T/active"   # number of agents the fake `agent ls` reports as working
: > "$CALLS"; echo 0 > "$ACTIVE"

cat > "$AGENT_BIN" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == ls ]]; then
  echo "NAME REPO STATUS AGE LAST"
  for i in \$(seq 1 "\$(cat "$ACTIVE")"); do echo "a\$i r[sb] working 1m x"; done
  exit 0
fi
{ echo "image=\$AGENT_IMAGE"; for a in "\$@"; do echo "arg=\$a"; done; echo "prompt=\$(cat "\${@: -3:1}" 2>/dev/null)"; echo ---; } >> "$CALLS"
[[ -n "\${FAKE_AGENT_FAIL:-}" ]] && { echo "boom" >&2; exit 3; }
exit 0
EOF
chmod +x "$AGENT_BIN"

A="$AGENTS_HOME"
mkdir -p "$A/repos/good/.git" "$A/repos/nonote/.git" "$A/repos/noconf/.git" "$A/repos/badconf/.git" \
         "$A/repos/defimg/.git" "$A/state" "$A/inbox/requests"
echo "note" > "$A/repos/good.md"; echo "IMAGE=good-image:1" > "$A/repos/good.conf"
echo "note" > "$A/repos/nonote.md"
echo "note" > "$A/repos/noconf.md"
echo "note" > "$A/repos/badconf.md"; printf 'IMAGE=x\nEXTRA=1\n' > "$A/repos/badconf.conf"
echo "note" > "$A/repos/defimg.md"; printf '# default image\n\n' > "$A/repos/defimg.conf"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   - $*"; }
P="$T/prompt.txt"; printf 'Do the thing.\nIn "quotes" and $(not run) and `ticks`.\n' > "$P"
result() { cat "$A/inbox/results/$1.result" 2>/dev/null || true; }
expect_status() { [[ "$(result "$1")" == *"status=$2"* ]] || fail "$1: wanted status=$2, got: $(result "$1")"; }
calls() { grep -c '^---$' "$CALLS" || true; }

# --- submit validation -------------------------------------------------------------------
"$BIN" submit good ok-task "$P" >/dev/null && pass "submit accepts a valid request"
[[ -f "$A/inbox/requests/ok-task.env" && -f "$A/inbox/requests/ok-task.prompt" ]] || fail "request files missing"
"$BIN" submit good ok-task "$P" 2>/dev/null && fail "duplicate task name accepted"; pass "submit refuses a duplicate task"
for bad in 'Bad' 'a b' '-x' 'x/../y' ''; do
  "$BIN" submit good "$bad" "$P" 2>/dev/null && fail "task name '$bad' accepted"
done; pass "submit refuses bad task names"
for bad in '../x' 'a/b' '-r' 'a b' ''; do
  "$BIN" submit "$bad" t-bad "$P" 2>/dev/null && fail "repo name '$bad' accepted"
done; pass "submit refuses bad repo names"
ln -s "$P" "$T/link"; "$BIN" submit good t-link "$T/link" 2>/dev/null && fail "symlink prompt accepted"
pass "submit refuses a symlinked prompt"
: > "$T/empty"; "$BIN" submit good t-empty "$T/empty" 2>/dev/null && fail "empty prompt accepted"
head -c 40000 /dev/zero | tr '\0' x > "$T/big"; "$BIN" submit good t-big "$T/big" 2>/dev/null && fail "oversized prompt accepted"
pass "submit refuses empty and oversized prompts"
[[ "$("$BIN" status ok-task)" == status=pending* ]] || fail "status of a pending request"
[[ "$("$BIN" status nope)" == status=unknown ]] || fail "status of an unknown request"
pass "status reports pending and unknown"

# --- run: launches a valid request -------------------------------------------------------
"$BIN" run
expect_status ok-task launched
[[ "$(calls)" == 1 ]] || fail "expected 1 agent call, got $(calls)"
grep -qx 'image=good-image:1' "$CALLS" || fail "image from repos/good.conf not passed"
grep -qx 'arg=new' "$CALLS" && grep -qx 'arg=--sandbox' "$CALLS" && grep -qx 'arg=--file' "$CALLS" || fail "wrong agent arguments"
grep -qx 'arg=good' "$CALLS" && grep -qx 'arg=ok-task' "$CALLS" || fail "repo or task not passed"
grep -q 'prompt=Do the thing\.' "$CALLS" && grep -q '\$(not run)' "$CALLS" || fail "prompt content altered"
[[ ! -e "$A/inbox/requests/ok-task.env" && -e "$A/inbox/claimed/ok-task.env" ]] || fail "request not claimed"
pass "run launches a valid request via --sandbox --file with the repo's image"
before="$(calls)"; "$BIN" run; [[ "$(calls)" == "$before" ]] || fail "run re-launched a finished request"
pass "run is idempotent"

# --- run: rejections (hand-written requests; submit would stop most of these earlier) ----
put() {  # put <task> <env-content> [prompt-content]
  printf '%s\n' "${3-Do it.}" > "$A/inbox/requests/$1.prompt"; printf '%b' "$2" > "$A/inbox/requests/$1.env"
}
put r-nonote   'REPO=nonote\n';   put r-noconf   'REPO=noconf\n'
put r-badconf  'REPO=badconf\n';  put r-norepo   'REPO=ghost\n'
put r-path     'REPO=/etc\n';     put r-dotdot   'REPO=../good\n'
put r-inject   'REPO=good$(touch '"$T"'/pwned)\n'
put r-extra    'REPO=good\nIMAGE=evil\n'
put r-noeol    'REPO=good'
put r-blank    'REPO=good\n'  '   '
ln -s "$P" "$A/inbox/requests/r-symprompt.prompt"; printf 'REPO=good\n' > "$A/inbox/requests/r-symprompt.env"
printf 'REPO=good\n' > "$A/inbox/requests/r-noprompt.env"
echo x > "$T/secret"; ln -s "$T/secret" "$A/inbox/requests/r-symenv.env"; echo p > "$A/inbox/requests/r-symenv.prompt"
printf 'REPO=good\n' > "$A/inbox/requests/Bad_Name.env"; echo p > "$A/inbox/requests/Bad_Name.prompt"
before="$(calls)"
"$BIN" run
for t in r-nonote r-noconf r-badconf r-norepo r-path r-dotdot r-inject r-extra r-noeol r-blank r-symprompt r-noprompt r-symenv; do
  expect_status "$t" rejected
done
[[ "$(calls)" == "$before" ]] || fail "a rejected request reached agent"
[[ ! -e "$T/pwned" ]] || fail "command substitution in a request was executed"
[[ ! -e "$A/inbox/requests/Bad_Name.env" && ! -e "$A/inbox/results/Bad_Name.result" ]] || fail "invalid-name request not dropped"
pass "run rejects unprepared repos, paths, injection, extra keys, symlinks and blank prompts"
[[ "$(result r-badconf)" == *"only IMAGE"* && "$(result r-noconf)" == *"not enabled"* ]] || fail "unhelpful rejection reasons"
pass "rejections say why"

# --- run: default image, name clash with a live agent, failures, cap ----------------------
"$BIN" submit defimg def-img "$P" >/dev/null; "$BIN" run
expect_status def-img launched; grep -qx 'image=isengard-agent' "$CALLS" || fail "default image not used"
pass "a conf with no IMAGE falls back to the default image"

touch "$A/state/live-agent.env"; "$BIN" submit good live-agent "$P" >/dev/null; "$BIN" run
expect_status live-agent rejected; pass "run refuses a task name that is already an agent"

FAKE_AGENT_FAIL=1 "$BIN" submit good fails "$P" >/dev/null; FAKE_AGENT_FAIL=1 "$BIN" run
expect_status fails failed; [[ "$(result fails)" == *boom* ]] || fail "agent error not recorded"
pass "run records agent new failures with its output"

echo 4 > "$ACTIVE"; "$BIN" submit good capped "$P" >/dev/null; before="$(calls)"; "$BIN" run
[[ "$(calls)" == "$before" && -e "$A/inbox/requests/capped.env" && -z "$(result capped)" ]] || fail "cap not respected"
[[ "$("$BIN" status capped)" == status=pending* ]] || fail "capped request not pending"
echo 1 > "$ACTIVE"; "$BIN" run; expect_status capped launched
pass "run leaves requests pending at the active-agent cap, then launches them"

echo "all inbox tests passed"
