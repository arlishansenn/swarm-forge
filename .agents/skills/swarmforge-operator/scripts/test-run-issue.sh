#!/usr/bin/env bash
# test-run-issue.sh — checks for run-issue.sh against stubbed gh/git/curl and
# a stubbed accept-work.sh. Run: bash scripts/test-run-issue.sh. Exits
# non-zero on any failure.
#
# Everything runs with --local, so `ssh` is never invoked and run_remote's
# `bash -c` picks the stubs up from PATH; dashboard-url, roles.tsv and the
# board TSV are real fixture files read by a real `cat`.
#
# Lane progression is driven by the stubs rather than by a background writer,
# so "how many rounds did it wait" is deterministic — which is exactly what
# the idle-but-not-done case has to assert. The POST stub creates the Board
# card in the master lane (what pack_web's create-task! does), and each
# subsequent /api/state call pops one lane off $STUB/lane-script into that
# card. A state call before the card exists pops nothing, so the pre-POST
# clarification gate does not consume a lane.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/run-issue.sh
WORK=$(mktemp -d /tmp/sf-run-issue-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] does not contain [$3]" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "[$2] must not contain [$3]" ;; *) ok "$1" ;; esac; }

[ -f "$SCRIPT" ] || { echo "  FAIL run-issue.sh missing at $SCRIPT"; exit 1; }

export STUB=$WORK/stub
mkdir -p "$WORK/bin"

# ---------- stub gh ----------
# Every invocation is logged one <arg> per line so the "no --merge/--auto/
# --fill" assertions read real argv positions instead of a re-joined string
# where a flag could hide inside the PR body text.
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
{ printf 'gh'; printf ' <%s>' "$@"; printf '\n'; } >> "$STUB/calls.log"
case "$1 $2" in
  "issue view") printf '%s\n' "${GH_ISSUE_TITLE:?}" ;;
  "pr list")    [ -n "${GH_OPEN_HEAD:-}" ] && printf '%s\n' "$GH_OPEN_HEAD"; exit 0 ;;
  "pr create")  printf '%s\n' "$*" > "$STUB/pr-create.argv"
                printf '<%s>\n' "$@" > "$STUB/pr-create.argvlines"
                [ -n "${GH_PR_FAILS:-}" ] && exit 1
                printf '%s\n' "${GH_PR_URL:-https://github.com/o/r/pull/99}" ;;
  *) exit 1 ;;
esac
EOF

# ---------- stub git ----------
cat > "$WORK/bin/git" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
{ printf 'git'; printf ' <%s>' "$@"; printf '\n'; } >> "$STUB/calls.log"
exit 0
EOF

# ---------- stub curl ----------
# /api/state serves $STUB/state.json, advances the Board card by one lane, and
# — when $STUB/state-after.json exists — swaps it in for the NEXT call, which
# is how the mid-poll clarification case appears only after polling started.
# /api/tasks creates the card and records the payload.
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
url=${!#}
data=''
while [ $# -gt 0 ]; do case $1 in --data) data=$2; shift 2 ;; *) shift ;; esac; done
case $url in
  */api/state)
    printf 'curl-state\n' >> "$STUB/calls.log"
    body=$(cat "$STUB/state.json")
    if [ -s "$STUB/lane-script" ] && grep -q "^$TASK_UNDER_TEST	" "$BOARD_FILE"; then
      lane=$(head -1 "$STUB/lane-script")
      sed '1d' "$STUB/lane-script" > "$STUB/lane-script.next"
      mv "$STUB/lane-script.next" "$STUB/lane-script"
      awk -F'\t' -v t="$TASK_UNDER_TEST" -v l="$lane" 'BEGIN{OFS="\t"}
        $1 == t { $2 = l } { print }' "$BOARD_FILE" > "$BOARD_FILE.tmp"
      mv "$BOARD_FILE.tmp" "$BOARD_FILE"
      [ -f "$STUB/state-after.json" ] && mv "$STUB/state-after.json" "$STUB/state.json"
    fi
    printf '%s\n' "$body"
    ;;
  */api/tasks)
    printf 'curl-post\n' >> "$STUB/calls.log"
    printf '%s\n' "$data" >> "$STUB/post.payloads"
    printf '%s\tcoder\t2026-08-26T00:00:00Z\t2026-08-26T00:00:00Z\n' \
      "$TASK_UNDER_TEST" >> "$BOARD_FILE"
    printf '{"ok":true}\n'
    ;;
  *) exit 1 ;;
esac
EOF

# ---------- stub accept-work.sh ----------
# Prints a WARN= line and a decoy task block before the real one: the parser
# must select by `task:` prefix, never by line offset — issue #50 gave
# accept-work.sh WARN= lines on ordinary successful runs.
cat > "$WORK/bin/fake-accept-work.sh" <<'EOF'
#!/usr/bin/env bash
printf 'STATUS=REPORTED\n'
printf 'WARN=1 handoffs are stuck in inbox/new in cleaner — the chain is not moving\n'
printf 'task: issue-11-decoy\ncommit: deadbeefdeadbeef\ncompleted_at: 2026-08-01T00:00:00Z\n\n'
printf 'task: %s\ncommit: %s\ncompleted_at: 2026-08-26T12:34:56Z\n\n' \
  "${TASK_UNDER_TEST:?}" "${FAKE_COMMIT:-abc1234}"
EOF
chmod +x "$WORK/bin"/*
export PATH=$WORK/bin:$PATH
export ACCEPT_WORK=$WORK/bin/fake-accept-work.sh
export SF_RUN_ISSUE_POLL_SECONDS=0
# Safety net, not a case: no case here is meant to reach the ceiling except
# the timeout one (which overrides it to 0). With the real 7200s default, a
# regression that stops the loop from ever finishing would hang this suite
# for two hours instead of failing.
export SF_RUN_ISSUE_TIMEOUT_SECONDS=5

ROOT=$WORK/proj
export BOARD_FILE=$ROOT/.swarmforge/board/tasks.tsv

STATE_CLEAN='{"clarifications":[{"id":"clar-old","status":"done","role":"coder","body":"answered"}],"approvals":[],"work_in_flight":[{"role":"coder","state":"idle"}]}'
STATE_PENDING_CLAR='{"clarifications":[{"id":"clar-20260826T093739982543Z","status":"pending","role":"coder","body":"Which ledger format should I use?"}],"approvals":[],"work_in_flight":[]}'
STATE_PENDING_APPROVAL='{"clarifications":[],"approvals":[{"id":"appr-77","gate":"spec → coder","task":"issue-28-x"}],"work_in_flight":[]}'

reset() { # $@ = extra board rows, each "name<TAB>lane"
  rm -rf "$ROOT" "$STUB"
  mkdir -p "$ROOT/.swarmforge/board" "$ROOT/.swarmforge/handoffs/inbox/new" "$STUB"
  printf 'http://127.0.0.1:53471\n' > "$ROOT/.swarmforge/dashboard-url"
  {
    printf 'coder\tmaster\t%s\tsess-coder\tCoder\tclaude\tdefault\n' "$ROOT"
    printf 'cleaner\tcleaner\t%s/.worktrees/cleaner\tsess-cleaner\tCleaner\tclaude\tdefault\n' "$ROOT"
  } > "$ROOT/.swarmforge/roles.tsv"
  printf 'pre-existing\tdone\t2026-01-01T00:00:00Z\t2026-01-01T00:00:00Z\n' > "$BOARD_FILE"
  local row
  for row in "$@"; do
    printf '%s\t2026-01-01T00:00:00Z\t2026-01-01T00:00:00Z\n' "$row" >> "$BOARD_FILE"
  done
  printf 'a handoff\n' > "$ROOT/.swarmforge/handoffs/inbox/new/x.handoff"
  : > "$STUB/calls.log"
  : > "$STUB/lane-script"
  printf '%s\n' "$STATE_CLEAN" > "$STUB/state.json"
}
tree_digest() {
  find "$ROOT/.swarmforge/board" "$ROOT/.swarmforge/handoffs" -type f -exec cat {} + | cksum
}
count() { grep -c "^$1\$" "$STUB/calls.log" 2>/dev/null || true; }

export GH_ISSUE_TITLE='Add evidence relations, refutation, and redaction'
TASK=issue-28-add-evidence-relations-refutation-and-redaction
export TASK_UNDER_TEST=$TASK
BRANCH=feat/$TASK
TAB=$(printf '\t')

echo "run-issue.sh"

# ---------- 1. usage ----------
reset
out=$("$SCRIPT" --issue 28 --local 2>&1); rc=$?
check "missing --root exits 2" 2 "$rc"
check "missing --root STATUS" "STATUS=USAGE" "$(printf '%s\n' "$out" | head -1)"
out=$("$SCRIPT" --root "$ROOT" --local 2>&1); rc=$?
check "missing --issue exits 2" 2 "$rc"
check "missing --issue STATUS" "STATUS=USAGE" "$(printf '%s\n' "$out" | head -1)"
out=$("$SCRIPT" --root "$ROOT" --issue twenty-eight --local 2>&1); rc=$?
check "non-numeric --issue exits 2" 2 "$rc"
check "usage path ran no command at all" "0" "$(wc -l < "$STUB/calls.log" | tr -d ' ')"

# ---------- 2. duplicate Board card ----------
# pack_web's create-task! only checks that the name is non-empty, so a second
# POST of the same name really does produce a second card. This gate is the
# verb's own responsibility.
reset "${TASK}${TAB}coder"
before=$(tree_digest)
out=$("$SCRIPT" --root "$ROOT" --issue 28 --local 2>&1); rc=$?
check "duplicate card exits 6" 6 "$rc"
check "duplicate card STATUS" "STATUS=UNSAFE" "$(printf '%s\n' "$out" | head -1)"
has "duplicate card names the card" "$out" "$TASK"
check "duplicate card posts nothing" "0" "$(count curl-post)"
check "duplicate card leaves board+handoffs byte-identical" "$before" "$(tree_digest)"
check "duplicate card creates no branch" "0" \
  "$(grep -c 'git <checkout>' "$STUB/calls.log" || true)"

# ---------- 3. pending clarification before the POST ----------
reset
printf '%s\n' "$STATE_PENDING_CLAR" > "$STUB/state.json"
before=$(tree_digest)
out=$("$SCRIPT" --root "$ROOT" --issue 28 --local 2>&1); rc=$?
check "pre-post pending clarification exits 6" 6 "$rc"
check "pre-post pending clarification STATUS" "STATUS=UNSAFE" "$(printf '%s\n' "$out" | head -1)"
has "pre-post clarification reports its id" "$out" "clar-20260826T093739982543Z"
has "pre-post clarification quotes the question" "$out" "Which ledger format"
check "pre-post clarification posts nothing" "0" "$(count curl-post)"
check "pre-post clarification writes nothing" "$before" "$(tree_digest)"

# ---------- 4. pending approval blocks the same way ----------
reset
printf '%s\n' "$STATE_PENDING_APPROVAL" > "$STUB/state.json"
out=$("$SCRIPT" --root "$ROOT" --issue 28 --local 2>&1); rc=$?
check "pending approval exits 6" 6 "$rc"
has "pending approval reports its id" "$out" "appr-77"
check "pending approval posts nothing" "0" "$(count curl-post)"

# ---------- 5. happy path with no open PR: BASE is main ----------
reset
printf 'done\n' > "$STUB/lane-script"
out=$(GH_OPEN_HEAD='' "$SCRIPT" --root "$ROOT" --issue 28 --local 2>&1); rc=$?
check "happy path exits 0" 0 "$rc"
check "happy path STATUS" "STATUS=PR_OPENED" "$(printf '%s\n' "$out" | head -1)"
has "happy path prints the PR URL" "$out" "https://github.com/o/r/pull/99"
argv=$(cat "$STUB/pr-create.argv")
lines=$(cat "$STUB/pr-create.argvlines")
has "BASE falls back to main" "$argv" "--base main"
has "checks out main before branching" "$(cat "$STUB/calls.log")" "git <checkout> <main>"
has "branch name is feat/issue-N-slug" "$(cat "$STUB/calls.log")" \
  "git <checkout> <-b> <$BRANCH>"
has "task name is issue-N-slug" "$(cat "$STUB/post.payloads")" "\"name\": \"$TASK\""
has "task body points at the issue" "$(cat "$STUB/post.payloads")" "gh issue view 28"
has "task body names the handoff chain from roles.tsv" \
  "$(cat "$STUB/post.payloads")" "coder -> cleaner -> coder"
has "pushes the branch" "$(cat "$STUB/calls.log")" "git <push> <-u> <origin> <$BRANCH>"
check "posts exactly one task" "1" "$(count curl-post)"
hasnt "gh pr create has no --merge" "$lines" "<--merge>"
hasnt "gh pr create has no --auto"  "$lines" "<--auto>"
hasnt "gh pr create has no --fill"  "$lines" "<--fill>"
has "PR body closes the issue" "$argv" "Closes #28"
has "PR body carries accept work's commit" "$argv" "commit: abc1234"
has "PR head is the new branch" "$argv" "--head $BRANCH"

# ---------- 6. an open PR exists: BASE is its head branch (stacked) ----------
reset
printf 'done\n' > "$STUB/lane-script"
out=$(GH_OPEN_HEAD='feat/issue-27-expose-append-only-email-evidence-as-via' \
  "$SCRIPT" --root "$ROOT" --issue 28 --local 2>&1); rc=$?
check "stacked run exits 0" 0 "$rc"
has "BASE is the open PR head" "$(cat "$STUB/pr-create.argv")" \
  "--base feat/issue-27-expose-append-only-email-evidence-as-via"
has "branches off the open PR head" "$(cat "$STUB/calls.log")" \
  "git <checkout> <feat/issue-27-expose-append-only-email-evidence-as-via>"

# ---------- 7. coder goes idle mid-chain, lane not done: keep waiting ----------
# The chain is coder -> cleaner -> coder, and the coder is briefly idle between
# hops. /api/state's work_in_flight[].state would read "idle" the whole time;
# only the Board lane says whether the task finished.
reset
printf 'cleaner\ncoder\ndone\n' > "$STUB/lane-script"
out=$("$SCRIPT" --root "$ROOT" --issue 28 --local 2>&1); rc=$?
check "idle-but-not-done still exits 0" 0 "$rc"
check "idle-but-not-done waited out every lane" "4" "$(count curl-state)"
check "idle-but-not-done posted once" "1" "$(count curl-post)"
# Comment lines are stripped first: the script is allowed — and expected — to
# explain in prose why work_in_flight is the wrong judge; what it must not do
# is read the field.
if grep -v '^[[:space:]]*#' "$SCRIPT" | grep -q 'work_in_flight'; then
  bad "completion never consults work_in_flight" \
    "$(grep -vn '^[[:space:]]*#' "$SCRIPT" | grep work_in_flight)"
else
  ok "completion never consults work_in_flight"
fi

# ---------- 8. clarification appears mid-poll: stop polling immediately ----------
reset
printf 'cleaner\ncoder\ndone\n' > "$STUB/lane-script"
printf '%s\n' "$STATE_PENDING_CLAR" > "$STUB/state-after.json"
out=$("$SCRIPT" --root "$ROOT" --issue 28 --local 2>&1); rc=$?
check "mid-poll clarification exits 6" 6 "$rc"
check "mid-poll clarification STATUS" "STATUS=UNSAFE" "$(printf '%s\n' "$out" | head -1)"
has "mid-poll clarification reports its id" "$out" "clar-20260826T093739982543Z"
check "mid-poll clarification stops at the round it appeared" "3" "$(count curl-state)"
check "mid-poll clarification never opens a PR" "no" \
  "$([ -f "$STUB/pr-create.argvlines" ] && echo yes || echo no)"

# ---------- 9. poll timeout: ERROR, and never a second POST ----------
reset
printf 'cleaner\ncoder\ncleaner\ncoder\n' > "$STUB/lane-script"
out=$(SF_RUN_ISSUE_TIMEOUT_SECONDS=0 "$SCRIPT" --root "$ROOT" --issue 28 --local 2>&1); rc=$?
check "timeout exits 5" 5 "$rc"
check "timeout STATUS" "STATUS=ERROR" "$(printf '%s\n' "$out" | head -1)"
check "timeout posts exactly one task" "1" "$(count curl-post)"
has "timeout says the task may still be running" "$out" "may still be running"
check "timeout never opens a PR" "no" \
  "$([ -f "$STUB/pr-create.argvlines" ] && echo yes || echo no)"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
