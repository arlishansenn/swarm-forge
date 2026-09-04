#!/usr/bin/env bash
# run-issue.sh — `run issue` (issue #60): put ONE GitHub issue through the
# managed swarm and stop at a reviewable PR. Until this verb existed, the
# chain "New Task in the dashboard -> read swarm until it finishes -> accept
# work -> branch -> gh pr create" was a sequence a human had to remember, and
# skipping a step raised no error. podsum lost both ways: a `git pull` was
# missed after a merge (local main diverged and stayed diverged), and a Board
# card named `验收 3 个 commit` produced a `task:` that mapped back to no
# issue at all, so the PR's `Closes` had to be reverse-engineered by hand.
#
# Effect verb: it creates one branch, posts one task, and opens one PR. It
# never merges (no --merge/--auto), never answers a clarification, and never
# re-posts a task it already posted.
#
# RESUMABLE (issues #65, #76, #115). This verb blocks for as long as the swarm
# takes, so sooner or later an agent harness kills it mid-run. A second run with
# the same --root/--issue CONTINUES the first one instead of refusing or
# crashing. What it does is derived from the observable world — the card's LANE,
# the branch, and the PR are three independent markers, and every state has an
# exit:
#
#   no card, no branch  -> fresh run
#   no card, branch     -> resume: skip the branch, POST the task that never got
#                       posted. This is the step-4-to-step-5 window, about two
#                       ssh round trips wide, and it used to be a dead end: the
#                       old code keyed the decision off the card alone, so with
#                       no card it took the fresh path and ran `git checkout -b`
#                       onto a branch that already existed — 5 ERROR on every
#                       re-run until a human deleted the branch (issue #76).
#   active lane, branch -> resume: skip the branch, skip the POST, pick up at
#                       the poll
#   active lane, none   -> not this verb's card; refuse (6 UNSAFE)
#   done, still shipping-> resume: the swarm's half is over, this verb's is not
#   done, shipped       -> that round is finished; refuse (6 UNSAFE), --round
#
# The lane is read by VALUE, not for emptiness (issue #115). CONTEXT.md makes a
# task's lane the only authority on whether that task is finished, and a
# decision that only asks whether a card exists has thrown that authority away:
# a `done` card left by a finished round was indistinguishable from an
# interrupted one. Continuing on a finished one is not harmless — `accept work`
# is keyed by task name alone, so it answers with the FINISHED round's delivery
# record, and the PR ends up carrying a commit that is not on the head it names
# (live failure on podsum #112).
#
# `done` alone is still not a stop, because the round has two halves: the swarm
# reaching `done`, and then this verb shipping it. STILL_RUNNING's own report
# promises that re-running continues the second half, and the window it points
# at — `done` on the Board, delivery record not yet visible, nothing pushed — is
# precisely a `done` card with a branch and no PR. So the third marker is the
# PR: a `done` card whose branch is present and whose head carries no PR, or an
# open one (this verb's own terminal state), is a round still being shipped and
# resumes exactly as it always did.
#
# Re-running is the recovery procedure; there is nothing else to remember. When
# a round really is finished and the issue has to go through again, --round N
# gives the re-run its own derived identity. Nothing on the Board or under
# inbox/ is ever cleared to force a re-run: the task name keys three separate
# state sources, clearing them by hand cannot be done completely, and they are
# history rather than levers.
#
# --max-wait <seconds> lets the CALLER say how long it can wait (issue #76).
# The ceilings below are the callee's own, and some harnesses kill well under
# them; being SIGKILLed instead of exiting cleanly is what lands a run in the
# table above in the first place. Semantics are `kubectl wait --timeout`'s, not
# a fourth invention: a positive value is a wall-clock budget for the WHOLE
# call and replaces both ceilings, 0 checks once and returns, and a negative
# value (the default) keeps the existing ceilings.
#
# The branch is stacked on the newest open PR's head, not on `main`. podsum's
# issues form a strict linear `blocked by` chain, so the next issue's coder
# has to see the previous issue's commits, which are not on `main` until a
# human merges; and if every branch came off `main` while none of them merged,
# each later PR's diff would carry every earlier PR's commits. BASE is looked
# up fresh from `gh pr list` on every run — this verb keeps no state between
# calls. Once a human merges the lower PR, GitHub retargets the upper one to
# `main` on its own.
#
# One issue per call, deliberately. A `--issues 28,29,30` flag would need
# exactly one piece of error handling, and the caller already has it:
#   for n in 28 29 30; do run-issue.sh --root R --issue "$n" || break; done
#
# Exit codes / STATUS line:
#   0 PR_OPENED   2 USAGE   5 ERROR   6 UNSAFE   7 STILL_RUNNING
# 7 is deliberately not 5: reaching the caller's deadline means the task is
# posted and the swarm is working, and the fix is to run the same command
# again. The `for ... || break` chain above breaks on both, but has to report
# them differently — the same reason GNU timeout exits 124 instead of reusing
# the exit code of the command it timed out.
# The report body carries `resumed: yes|no` so a caller can tell a fresh run
# from a continued one.
# Contract details live in ../SKILL.md (verb: run issue).
#
# Usage: run-issue.sh --root <project-root> --issue <N> \
#   [--target user@host] [--key <path>] [--local] [--max-wait <seconds>] \
#   [--round <N>]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' ISSUE='' LOCAL=0
MAX_WAIT=-1
# Which attempt at this issue this is. Round 1 carries no suffix, so every name
# this verb has ever produced is unchanged; a later round suffixes the task
# name (and with it the branch), which is the only supported way to run an
# issue whose earlier round finished. Derived, not invented, so a round is
# itself resumable by re-running the same command.
ROUND=1

# Poll cadence and ceiling. A real chain hop is minutes, not seconds, so a
# tight interval buys nothing but ssh round trips; the ceiling is generous
# because a timeout here does NOT mean failure (see the ERROR below).
# Overridable for tests, same trick as accept-work.sh's staleness thresholds.
POLL_SECONDS=${SF_RUN_ISSUE_POLL_SECONDS:-15}
TIMEOUT_SECONDS=${SF_RUN_ISSUE_TIMEOUT_SECONDS:-7200}
# Separate, much shorter ceiling for the gap between the Board saying `done`
# and the delivery record becoming visible to `accept work` (issue #63). That
# is the master finishing ONE handoff, not the swarm doing a task, so it is
# minutes at most; folding it into TIMEOUT_SECONDS would let a stuck master
# look like a two-hour task.
DELIVERY_SECONDS=${SF_RUN_ISSUE_DELIVERY_SECONDS:-600}
# Overridable so tests can point step 5 at a stub instead of the real report,
# same trick as start-swarm.sh's SWARM_LAUNCHER.
ACCEPT_WORK=${ACCEPT_WORK:-$HERE/accept-work.sh}

usage() { printf 'STATUS=USAGE\n'; sed -n '2,95p' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=${2:-}; shift 2 ;;
    --issue) ISSUE=${2:-}; shift 2 ;;
    --target) TARGET=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --max-wait) MAX_WAIT=${2:-}; shift 2 ;;
    --round) ROUND=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$ROOT" ] || usage
# Digits only: $ISSUE is interpolated into remote command strings unquoted
# below, and it is also the one argument a human is most likely to fat-finger.
case $ISSUE in ''|*[!0-9]*) usage ;; esac
# One optional leading minus, then digits. Anything else is a typo, and a typo
# in a deadline is worth an exit 2 rather than a silently wrong wait.
case ${MAX_WAIT#-} in ''|*[!0-9]*) usage ;; esac
# Positive digits only. Round 0 is not "the round before the first one", it is
# a typo, and a typo in an identity would silently start a second round.
case $ROUND in ''|*[!0-9]*|0) usage ;; esac
# The caller's budget covers the whole call, branch and POST included, not just
# the polling — an agent that says "I have 300 seconds" means the command.
if [ "$MAX_WAIT" -lt 0 ]; then WAIT_DEADLINE=''
else WAIT_DEADLINE=$(( $(date -u +%s) + MAX_WAIT )); fi

# run_remote — executes a fixed, script-built shell snippet against ROOT's
# host, local or remote. Same shape and same rule as accept-work.sh's: the
# snippet is only ever assembled from $ROOT (a trusted CLI argument) and fixed
# flag text. Everything that came from outside this script — the issue title,
# the base branch name, the JSON payload, a commit hash — is %q-quoted at the
# call site, never hand-interpolated.
run_remote() {
  if [ "$LOCAL" = 1 ]; then bash -c "$1"
  else ssh -i "$KEY" "$TARGET" "$1"; fi
}
in_root() { run_remote "cd '$ROOT' && $1"; }

# ---------- step 0: dashboard URL, read every single time ----------
# pack_web binds a fresh port on every start, so a cached or remembered URL is
# wrong as soon as the dashboard restarts. The file is the only source of truth
# (same read open-dashboard.sh does).
URL=$(read_file .swarmforge/dashboard-url 2>/dev/null) \
  || die ERROR "$ROOT/.swarmforge/dashboard-url not found — is pack_web running? (check --root/--target/--local)" 5
URL=${URL%$'\n'}; URL=${URL%/}
[ -n "$URL" ] || die ERROR "$ROOT/.swarmforge/dashboard-url is empty" 5

# ---------- step 1: issue title -> slug -> task name and branch name ----------
# `gh` runs on the target inside $ROOT so it resolves the managed project's own
# repository from its git remote; running it here would resolve swarm-forge.
TITLE=$(in_root "gh issue view $ISSUE --json title --jq .title") \
  || die ERROR "gh issue view $ISSUE failed in $ROOT — check that gh is installed and authenticated there" 5
TITLE=${TITLE%$'\n'}
[ -n "$TITLE" ] || die ERROR "issue #$ISSUE has no title" 5

# Lowercase, every run of non-alphanumerics collapsed to one dash, trimmed,
# capped. Reproduces the `#26`/`#27` precedent exactly
# (feat/issue-27-expose-append-only-email-evidence-as-via).
SLUG=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]\{1,\}/-/g' | cut -c1-60 | sed 's/^-*//; s/-*$//')
[ -n "$SLUG" ] || die ERROR "issue #$ISSUE title yields an empty slug: $TITLE" 5
TASK_NAME="issue-$ISSUE-$SLUG"
[ "$ROUND" = 1 ] || TASK_NAME="$TASK_NAME-r$ROUND"
BRANCH="feat/$TASK_NAME"

# ---------- step 2: BASE — the newest open PR's head, else main ----------
BASE=$(in_root "gh pr list --state open --json headRefName --jq '.[].headRefName' | head -1") \
  || die ERROR "gh pr list failed in $ROOT" 5
BASE=${BASE%$'\n'}
[ -n "$BASE" ] || BASE=main

# ---------- step 3: fresh run, resume, or refuse ----------
# pack_web's create-task! validates only that the name is non-empty; posting
# the same name twice really does create two cards, and two cards mean two
# handoff notes into the master's inbox. Nothing upstream will catch that, so
# this verb owns the check — and it runs before anything is created.
#
# A card that already exists is not automatically someone else's, though
# (issue #65). This verb always creates the branch BEFORE it posts, so the
# branch is the marker of its own earlier run.
#
# Every marker is read on every run and each state is answered independently
# (issue #76). Reading the card first and only then asking about the branch
# left "branch, no card" with no answer at all: it fell through to the fresh
# path and re-ran `git checkout -b` on an existing branch, which is a hard
# failure and stayed one on every re-run. Nothing is inferred from which marker
# was noticed first; each of the two decisions this block makes — create the
# branch or not, post the task or not — comes from its own marker.
#
# The branch is checked as a ref, not by name matching, because the name alone
# is derived from the issue and would be identical for a card a human typed
# into the Dashboard by hand.
BOARD_FILE="$ROOT/.swarmforge/board/tasks.tsv"
board_lane() { # $1 = task name -> its lane, empty when the card is absent
  run_remote "cat '$BOARD_FILE' 2>/dev/null" \
    | awk -F'\t' -v t="$1" '$1 == t { print $2; exit }' || true
}
EXISTING_LANE=$(board_lane "$TASK_NAME")
BRANCH_EXISTS=0
if in_root "git rev-parse --verify --quiet $(printf '%q' "refs/heads/$BRANCH")" >/dev/null 2>&1; then
  BRANCH_EXISTS=1
fi
# `done` first: it is the lane saying this identity's round is over, and it
# answers before the "is this card mine" question, which cannot tell a finished
# round from a foreign card. The PR is looked up only in this branch of the
# decision, so an ordinary run costs no extra call.
if [ "$EXISTING_LANE" = done ]; then
  PRIOR_STATE='' PRIOR_URL=''
  if [ "$BRANCH_EXISTS" = 1 ]; then
    # `.[0] | .state, .url` prints two lines, and yields two nulls rather than
    # an error on an empty list — a gh hiccup therefore reads as "no PR" and
    # keeps the old resume behaviour, never as a new refusal.
    PRIOR=$(in_root "gh pr list --head $(printf '%q' "$BRANCH") --state all --json state,url --jq '.[0] | .state, .url'") || PRIOR=''
    PRIOR_STATE=$(printf '%s\n' "$PRIOR" | head -1)
    PRIOR_URL=$(printf '%s\n' "$PRIOR" | tail -1)
  fi
  FINISHED=''
  case "$BRANCH_EXISTS:$PRIOR_STATE" in
    0:*)               FINISHED="its branch $BRANCH is gone" ;;
    1:MERGED|1:CLOSED) FINISHED="its PR $PRIOR_URL is $PRIOR_STATE" ;;
  esac
  [ -z "$FINISHED" ] || die UNSAFE "$TASK_NAME is in lane done on $BOARD_FILE and $FINISHED — that round is finished, and this verb will not reuse a finished task identity: accept work is keyed by the task name alone, so it would answer with the finished round's delivery record. Nothing on the Board or under inbox/ needs clearing (both are history, not levers). To put issue #$ISSUE through again, give the re-run its own identity: --round $((ROUND + 1))" 6
fi
if [ "$BRANCH_EXISTS" = 0 ] && [ -n "$EXISTING_LANE" ]; then
  die UNSAFE "$BOARD_FILE already has a card named $TASK_NAME (lane $EXISTING_LANE) but $BRANCH does not exist in $ROOT — that card was not created by this verb; delete or rename it, or accept the work it already produced" 6
fi
RESUMING=$BRANCH_EXISTS
NEED_BRANCH=0; [ "$BRANCH_EXISTS" = 1 ] || NEED_BRANCH=1
NEED_POST=0;   [ -n "$EXISTING_LANE" ]  || NEED_POST=1

# ---------- the pending gate ----------
# A blocked agent does not fail: it writes a clarification request or a
# pending approval and waits, so its task never reaches `done` and a poller
# with no gate would simply spin until the timeout. This is the only thing in
# the loop that stops it on purpose, and it is what makes a `for ... || break`
# chain safe — without it the loop moves on to the next issue and stacks the
# next branch on top of work nobody has looked at.
#
# Checked once before anything is created (a stale request from an earlier run
# blocks a new one, which is the point) and again on every poll round.
refuse_if_blocked() {
  local state blockers
  state=$(run_remote "curl -sS --max-time 10 $(printf '%q' "$URL/api/state")") \
    || die ERROR "cannot read $URL/api/state on the target — is pack_web still running?" 5
  blockers=$(printf '%s' "$state" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    out = []
    for c in d.get("clarifications") or []:
        if c.get("status") == "pending":
            q = " ".join((c.get("body") or "").split())
            out.append("clarification %s (role %s): %s" % (c.get("id"), c.get("role"), q[:300]))
    for a in d.get("approvals") or []:
        out.append("approval %s (%s) for task %s" % (a.get("id"), a.get("gate"), a.get("task")))
except Exception:
    sys.exit(1)
sys.stdout.write("\n".join(out))
') || die ERROR "unparseable response from $URL/api/state" 5
  [ -z "$blockers" ] || die UNSAFE \
    "$(printf 'the swarm is waiting on a human, so no task can finish — resolve it in the dashboard, then re-run:\n%s' "$blockers")" 6
}
refuse_if_blocked

# ---------- steps 4 and 5: the branch, then the task ----------
# Gated separately rather than as one resume/fresh block (issue #76): the two
# steps are two writes with a window between them, so a run can legitimately
# need the second without the first. Everything from step 6 down is shared by
# every path, so no two of them can drift apart.

# ---------- step 4: the branch ----------
# Created before the task is posted: the swarm commits onto whatever HEAD the
# master worktree is on, and merge_and_process.bb never names a branch, so the
# branch simply has to exist first. It is also what a later run reads as
# "this card is mine".
if [ "$NEED_BRANCH" = 1 ]; then
in_root "git checkout $(printf '%q' "$BASE") && git checkout -b $(printf '%q' "$BRANCH")" \
  || die ERROR "could not create $BRANCH from $BASE in $ROOT" 5
fi

# ---------- step 5: post the task ----------
# Minimal handoff, the shape `#26`/`#27` already proved: point at the issue,
# require an inventory pass first, and name the chain. The whole issue body is
# deliberately not copied — the coder can read it, and a copy goes stale.
# The chain comes from roles.tsv rather than being written out, because role
# names differ per pack (coder/cleaner in a two-pack, specifier/... in a
# four-pack) and SKILL.md's contract is to derive topology, never to branch on
# role names.
if [ "$NEED_POST" = 1 ]; then
ROLES=$(read_file .swarmforge/roles.tsv 2>/dev/null) \
  || die ERROR "$ROOT/.swarmforge/roles.tsv not found — cannot name the handoff chain" 5
CHAIN=$(printf '%s\n' "$ROLES" | awk -F'\t' '
  NF { r[++n] = $1 }
  END { if (!n) exit 1; s = r[1]; for (i = 2; i <= n; i++) s = s " -> " r[i]; print s " -> " r[1] }') \
  || die ERROR "$ROOT/.swarmforge/roles.tsv has no roles" 5

# ---------- OpenSpec, only if the TARGET project uses it (issue #94) ----------
# A managed project that installs OpenSpec gets nothing out of it if the task
# body never mentions it: podsum merged its schema and the very next run of
# this verb produced 4 commits, +414 lines and 22 green tests with ZERO output
# under openspec/changes/ — the coder went straight to code+TDD and the new
# section in that project's AGENTS.md was a dead letter.
#
# Derived from the target's runtime state, never hardcoded, for the same reason
# CHAIN is derived from roles.tsv: this verb serves any managed project and
# plenty of them do not use OpenSpec, so an unconditional paragraph would be a
# wrong instruction for those.
#
# The artifact ORDER is deliberately not written here. It is a property of the
# schema; naming the schema and letting the coder read
# openspec/schemas/<name>/schema.yaml keeps one source of that knowledge.
# A copy here would be a second one, and it would drift the first time a schema
# gains or reorders an artifact.
OPENSPEC_NOTE=''
if OS_CFG=$(read_file openspec/config.yaml 2>/dev/null); then
  OS_SCHEMA=$(printf '%s\n' "$OS_CFG" \
    | sed -n 's/^schema:[[:space:]]*//p' | head -1 | tr -d "\"' \r")
  if [ -n "$OS_SCHEMA" ]; then
    OPENSPEC_NOTE="

本项目用 OpenSpec，schema 是 ${OS_SCHEMA}。这次变更走该 schema 的 artifact 周期，产出落在 openspec/changes/ 下。artifact 有哪些、顺序如何、每个的要求是什么，读 openspec/schemas/${OS_SCHEMA}/schema.yaml，不要凭记忆。"
  fi
fi

TASK_TEXT="读 gh issue view ${ISSUE}，按它的 Acceptance criteria 逐条做。

先盘点相关代码、测试与既有实现，再动手；先说明哪些判据已满足、哪些没有。所有 OpenProse source 必须通过 skill:open-prose authoring semantics；按 TDD 实现，完成后走 $CHAIN handoff。${OPENSPEC_NOTE}"

PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "text": sys.argv[2]}))' \
  "$TASK_NAME" "$TASK_TEXT")
POST_OUT=$(run_remote "curl -sS -X POST -H 'Content-Type: application/json' --max-time 30 --data $(printf '%q' "$PAYLOAD") $(printf '%q' "$URL/api/tasks")") \
  || die ERROR "POST $URL/api/tasks failed — $BRANCH exists but no task was created; re-run the same command once the dashboard answers, and it will post the task without rebuilding the branch" 5
case $POST_OUT in
  *'"ok":true'*) ;;
  *) die ERROR "POST $URL/api/tasks did not return {\"ok\":true}: $POST_OUT" 5 ;;
esac
fi

# ---------- the caller's deadline ----------
# Not a failure and not this verb's ceiling: the task is on the Board, the
# swarm is working, and re-running the same command continues from here. So it
# reports what it saw and gets out — no push, no PR, and above all no re-post,
# which would create a second card and a second chain.
still_running() { # $1 = lane as last seen, $2 = what it was waiting for
  printf 'STATUS=STILL_RUNNING\nissue: %s\ntask: %s\nbranch: %s\nbase: %s\nlane: %s\nresumed: %s\nwaiting_for: %s\nreached --max-wait of %ss; re-run the same command to continue — nothing was pushed, no PR was opened, and the task was NOT re-posted\n' \
    "$ISSUE" "$TASK_NAME" "$BRANCH" "$BASE" "${1:-<no card>}" \
    "$([ "$RESUMING" = 1 ] && echo yes || echo no)" "$2" "$MAX_WAIT"
  exit 7
}
past_deadline() { [ "$(date -u +%s)" -ge "$WAIT_DEADLINE" ]; }

# ---------- step 6: poll the Board lane ----------
# The Board lane is the ONLY completion judge. /api/state's work_in_flight
# reports a role idle between hops of a coder -> cleaner -> coder chain, so a
# role-state check calls a half-finished task done.
DEADLINE=$(( $(date -u +%s) + TIMEOUT_SECONDS ))
while :; do
  refuse_if_blocked
  LANE=$(board_lane "$TASK_NAME")
  [ "$LANE" = done ] && break
  if [ -n "$WAIT_DEADLINE" ]; then
    past_deadline && still_running "$LANE" "the Board lane to reach done"
  elif [ "$(date -u +%s)" -ge "$DEADLINE" ]; then
    # Not a failure either — the swarm may still be working. Re-posting would
    # create a second card and a second chain, so this verb stops and says so.
    die ERROR "$TASK_NAME is in lane '${LANE:-<no card>}' after ${TIMEOUT_SECONDS}s and may still be running — check the dashboard; the task was NOT re-posted" 5
  fi
  sleep "$POLL_SECONDS"
done

# ---------- step 7: the commit, from accept work ----------
# accept-work.sh's report is a STATUS line, then zero or more WARN= lines
# (issue #50's Board cross-check WARNs on ordinary runs), then one
# task/commit/completed_at block per unshipped task. Read it by prefix and by
# task name; line offsets are wrong the moment a WARN appears.
#
# Retried, not read once (issue #63, found by #60's live run on podsum #30).
# The Board lane and this report are two DIFFERENT lifecycle events with a
# normal processing window between them: handoffd marks the card `done` the
# moment it DELIVERS a terminal-shaped handoff, while `accept work` reads only
# the master's inbox/completed/ — so while the master is still working that
# file in inbox/in_process/, the task is `done` on the Board and invisible to
# this report. Reading once turned that window into a hard ERROR/5 that pushed
# nothing and opened no PR, on a run that had in fact succeeded.
AW_ARGS=(--root "$ROOT")
if [ "$LOCAL" = 1 ]; then AW_ARGS+=(--local); else AW_ARGS+=(--target "$TARGET" --key "$KEY"); fi

aw_field() { # $1 = header name -> its value inside $TASK_NAME's block
  printf '%s\n' "$AW" | awk -v t="$TASK_NAME" -v f="$1: " '
    index($0, "task: ") == 1 { cur = substr($0, 7); next }
    cur == t && index($0, f) == 1 { print substr($0, length(f) + 1); exit }'
}

DELIVERY_DEADLINE=$(( $(date -u +%s) + DELIVERY_SECONDS ))
while :; do
  AW=$("$ACCEPT_WORK" "${AW_ARGS[@]}") \
    || die ERROR "accept work failed for $ROOT — cannot resolve the commit for $TASK_NAME" 5
  COMMIT=$(aw_field commit)
  COMPLETED=$(aw_field completed_at)
  [ -n "$COMMIT" ] && break
  # Nothing is pushed and no PR exists yet at this point, so waiting repeats
  # nothing; the task is never re-posted here either.
  if [ -n "$WAIT_DEADLINE" ]; then
    past_deadline && still_running done "accept work to see the delivery record"
  elif [ "$(date -u +%s)" -ge "$DELIVERY_DEADLINE" ]; then
    die ERROR "$TASK_NAME is done on the Board but its delivery record is still invisible to accept work after ${DELIVERY_SECONDS}s — the terminal handoff is probably still in $ROOT/.swarmforge/handoffs/inbox/in_process/, or its commit already reached origin/main; nothing was pushed and the task was NOT re-posted" 5
  fi
  sleep "$POLL_SECONDS"
done

# ---------- step 8: push, then open the PR ----------
in_root "git push -u origin $(printf '%q' "$BRANCH")" \
  || die ERROR "could not push $BRANCH from $ROOT" 5

# Explicit --title/--body, never --fill: --fill would use the swarm's own
# commit messages, which do not carry `Closes #N` — that is precisely how a PR
# ended up needing a human to reverse-engineer which issue it closed. The body
# carries pointers, not a diff copy.
PR_BODY=$(printf 'Closes #%s\n\ntask: %s\ncommit: %s\ncompleted_at: %s\n' \
  "$ISSUE" "$TASK_NAME" "$COMMIT" "$COMPLETED")
# A run killed between the push and the PR would otherwise try to open a
# second PR for the same head on the next attempt, and `gh pr create` would
# fail with a message about the existing one. Resuming has to be idempotent at
# every step, not only at the POST.
PR_URL=$(in_root "gh pr list --head $(printf '%q' "$BRANCH") --state open --json url --jq '.[].url' | head -1") \
  || PR_URL=''
PR_URL=${PR_URL%$'\n'}
if [ -z "$PR_URL" ]; then
  PR_OUT=$(in_root "gh pr create --base $(printf '%q' "$BASE") --head $(printf '%q' "$BRANCH") --title $(printf '%q' "$TITLE") --body $(printf '%q' "$PR_BODY")") \
    || die ERROR "gh pr create failed for $BRANCH -> $BASE in $ROOT" 5
  PR_URL=$(printf '%s\n' "$PR_OUT" | grep -o 'https://[^[:space:]]*' | tail -1 || true)
  [ -n "$PR_URL" ] || die ERROR "gh pr create returned no PR URL: $PR_OUT" 5
fi

printf 'STATUS=PR_OPENED\nissue: %s\ntask: %s\nbranch: %s\nbase: %s\ncommit: %s\nresumed: %s\nurl: %s\n' \
  "$ISSUE" "$TASK_NAME" "$BRANCH" "$BASE" "$COMMIT" \
  "$([ "$RESUMING" = 1 ] && echo yes || echo no)" "$PR_URL"
exit 0
