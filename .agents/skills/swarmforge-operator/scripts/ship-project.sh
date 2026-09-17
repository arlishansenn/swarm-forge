#!/usr/bin/env bash
# ship-project.sh — `ship project`: take what the swarm has already finished in
# a product checkout and stop at a reviewable PR.
#
# WHY THIS VERB EXISTS. The operator cuts cards in the dashboard or the chat
# rail, the lieutenant moves them through `.swarmforge/routes.tsv`, and nothing
# here created a branch or knows a task name in advance. Upstream then stops
# dead: its work lifecycle ends at "the board moves the card to Done". There is
# no `git push` and no `gh pr` anywhere in its prompts, scripts or docs, and
# `lieutenant.prompt` is explicitly denied every git verb it might otherwise
# reach for. The last mile is outside the forge by design, and this verb is
# that last mile.
#
# WHAT IT SHIPS. Whatever terminal handoffs the master worktree has accepted
# and `origin/<base>` does not already carry — `accept-work.sh`'s report, run
# as-is rather than re-derived here. Cards, not commits, are the unit a human
# reasons about, and that script already owns the two hard parts: reading the
# terminal record out of the master worktree only, and excluding a task whose
# commit already reached origin.
#
# THE GATE THAT EARNS ITS KEEP. A Done card and a merged product checkout are
# two different events. `handoffd` marks the card `done` when it DELIVERS the
# terminal handoff; the master merges it some time after that. Ship in that
# window and `git log origin/base..HEAD` quietly carries a SUBSET of the work —
# a PR that looks complete and is missing a card. So every delivery record's
# commit is checked for ancestry in HEAD, and a miss is a blocker, never a
# shrug.
#
# It never merges the PR, never force-pushes, never commits for you, and never
# pushes from a role worktree under .worktrees/.
#
# IT DOES NOT RUN YOUR TESTS (issue #170). It used to: discover an entry point,
# run it, block on red. That rested on an assumption that is false in general --
# that the host this verb happens to ssh into can meaningfully run the managed
# project's suite. It cannot: a suite needs that project's environment, and this
# verb has no business building one. On podsum it guessed `pytest -q` against a
# project whose own CI runs `python -m unittest discover -s tests` after
# installing two dependency groups, got 20 collection errors, and reported
# "tests failed" -- a claim about the swarm's code that was really a claim about
# a missing module.
#
# The check did not need to live here. The swarm's roles verify before they hand
# off, and the PR this verb opens is tested by the project's own CI on
# `pull_request`, with the right command in a prepared environment, before any
# human merges it. A managed project with no CI has a gap -- and the fix for
# that is CI, not an operator verb impersonating a test runner.
#
# TWO PASSES: the first pass reports, gates, creates
# the branch and pushes it, then stops at NEEDS_PR_BODY (exit 8) because the
# prose belongs to something that read the diff. Send a subagent with the
# `to-pr` skill, then re-run with --body-file. --dry-run stops before the push
# when you want the report alone.
#
# Exit codes / STATUS line:
#   0 PR_OPENED   0 NOTHING_TO_SHIP   0 DRY_RUN   2 USAGE   5 ERROR
#   6 BLOCKED     8 NEEDS_PR_BODY
# BLOCKED is 6 because a refusal on evidence is not a failure of the verb, and
# nothing was changed. NOTHING_TO_SHIP and
# DRY_RUN are 0 because both are the verb doing exactly what was asked; the
# STATUS word, not the code, is what tells them apart. Contract details live in
# ../SKILL.md (verb: ship project).
#
# Usage: ship-project.sh --root <product-root> \
#   [--target user@host] [--key <path>] [--local] \
#   [--branch <name>] [--base <name>] [--issue <N>]... \
#   [--body-file <path>] [--dry-run]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' LOCAL=0 BRANCH='' BASE='' BODY_FILE='' DRY_RUN=0
ISSUES=''

# Staleness thresholds (issue #17 design decision — see report). Presence
# alone in inbox/new is not stuck: handoffd's own reconciliation doesn't send
# its first retry wake until 5s have passed (SWARMFORGE_WAKE_RETRY_MS ladder
# in handoffd.bb), and a healthy chain routinely has a file sit briefly
# between delivery and pickup. 300s (5 minutes) is past the point handoffd's
# fast ladder rungs (5s/15s/60s) would have already re-sent the wake several
# times, so a file still unclaimed at that age has outlasted normal in-transit
# jitter. inbox/in_process gets a longer threshold: a role can legitimately
# work a real task for many minutes, so warning at the same 5-minute mark
# would fire on healthy in-progress work — the exact "constant warning nobody
# reads" failure mode CLAUDE.md's own governance rules warn about. 1800s
# (30 minutes) is long enough that ordinary task duration does not trip it,
# short enough to eventually flag a role that died mid-task. Both are
# overridable for tests, same trick as lib-wake-talk.sh's ARRIVAL_TRIES.
STALE_NEW_SECONDS=${SF_STALE_NEW_SECONDS:-300}
STALE_INPROCESS_SECONDS=${SF_STALE_INPROCESS_SECONDS:-1800}


# Usage text is grepped, not line-numbered: offsets rot on the first comment
# edit, and a usage message that prints the wrong lines is worse than none.
usage() { sed -n '/^# Usage: ship-project.sh/,/^set -euo/p' "$0" | sed '$d'; }

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --branch) BRANCH=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --issue) ISSUES="${ISSUES}${ISSUES:+ }${2#\#}"; shift 2 ;;
    --body-file) BODY_FILE=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || { usage; exit 2; }
ROOT=${ROOT%/}

run_remote() {
  if [ "$LOCAL" = 1 ]; then bash -c "$1"
  else ssh -i "$KEY" "$TARGET" "$1"; fi
}
in_root() { run_remote "cd '$ROOT' && $1"; }

PROJECT=$(basename "$ROOT")
BLOCKERS=''
block() { BLOCKERS="${BLOCKERS}${BLOCKERS:+$'\n'}- $1"; }

# ---------- gate A: is this a product checkout at all ----------
# Three ways to point this verb at something that must never be pushed, each
# with its own message because the fix differs. A role worktree is a generated
# checkout on a `swarmforge-<name>` branch; a forge root holds projects/ and is
# not a product repo at all; a subdirectory would push the whole repo while
# reporting a path that is not its root.
case "$ROOT" in
  */.worktrees/*) die BLOCKED "$ROOT is a role worktree — .worktrees/* is generated by SwarmForge and is never the publish source; point --root at the product checkout (the master worktree)" 6 ;;
esac
if run_remote "test -d '$ROOT/projects' && test -e '$ROOT/swarm'" 2>/dev/null; then
  die BLOCKED "$ROOT looks like a forge root (it has projects/ and swarm) — the product repo is projects/<name>; point --root there" 6
fi
# Positive check, after the two negatives above so their sharper messages win.
# Without it gate A accepts ANY standalone git repo that has a .swarmforge/
# tree, which is how this verb got run against a retired pack install.
require_managed_project
TOP=$(in_root "git rev-parse --show-toplevel" 2>/dev/null) \
  || die ERROR "$ROOT is not a git work tree (or the target is unreachable)" 5
TOP=${TOP%$'\n'}
# Compared against the RESOLVED root, not the string that was typed: git
# answers with symlinks resolved (/tmp is /private/tmp on macOS), so a literal
# comparison refuses a perfectly good product root whenever any path component
# is a symlink.
ROOT_REAL=$(in_root "pwd -P" 2>/dev/null || printf '%s' "$ROOT")
ROOT_REAL=${ROOT_REAL%$'\n'}
[ "$TOP" = "$ROOT_REAL" ] \
  || die BLOCKED "$ROOT is inside a repo whose root is $TOP — run this verb at the repo root so the report and the push describe the same tree" 6

MISSION=''
if MISSION_RAW=$(read_file mission.md 2>/dev/null); then
  MISSION=$(printf '%s\n' "$MISSION_RAW" | awk 'NF { print; exit }')
fi

# ---------- gate B: the board ----------
# tasks.tsv, not the dashboard: pack_web binds a fresh port on every start and
# may not be running at all when a human decides to ship. Columns are
# name, lane, created, updated, task-id, audit-count, type (card_type.bb's
# format-row) — lane has been column 2 across every version of the board.
#
# `waiting` is reported, never blocking. A waiting card is a card the
# lieutenant has not started; the plan not being finished is not a reason to
# refuse to publish the part that is. A card in a ROLE lane is blocking: work
# is in flight and shipping now cuts it in half.
BOARD_FILE="$ROOT/.swarmforge/board/tasks.tsv"
BOARD=$(read_file .swarmforge/board/tasks.tsv 2>/dev/null || true)
LIVE=$(printf '%s\n' "$BOARD" | awk -F'\t' 'NF && $2 != "done" && $2 != "waiting" { printf "%s (%s) ", $1, $2 }')
DONE_N=$(printf '%s\n' "$BOARD" | awk -F'\t' '$2 == "done"' | wc -l | tr -d ' ')
WAIT_N=$(printf '%s\n' "$BOARD" | awk -F'\t' '$2 == "waiting"' | wc -l | tr -d ' ')
LIVE_N=$(printf '%s\n' "$BOARD" | awk -F'\t' 'NF && $2 != "done" && $2 != "waiting"' | wc -l | tr -d ' ')
[ -z "$LIVE" ] || block "board has live cards: ${LIVE% }"

# ---------- gate C: failed deliveries ----------
# A delivery that failed and stayed failed means a chain that never closed;
# publishing over one publishes a tree that is missing a hop.
#
# TWO paths are checked because the two SwarmForge lineages name this-same
# thing differently, and a gate that looks at only one of them is a gate that
# cannot fire on the other:
#
#   handoffs/*/failed/       handoffd.bb's fail! moves a permanently failed
#                            handoff here, per worktree. This is what the
#                            main-lineage code in this repository actually
#                            writes, and it is the one that fires today.
#   .swarmforge/delivery_attention/
#                            the lieutenant lineage's name for the same state.
#                            Absent here, kept so this gate keeps working after
#                            that branch is synced.
#
# Checking only delivery_attention/ was the bug: on this repository's own code
# that directory is never created, so the gate silently passed every time.
FAILED=$(run_remote "ls -1 '$ROOT'/.swarmforge/handoffs/failed '$ROOT'/.worktrees/*/.swarmforge/handoffs/failed '$ROOT/.swarmforge/delivery_attention' 2>/dev/null | grep -v '^$' | grep -v ':$' | head -20" || true)
ATTENTION_LINE=none
if [ -n "$FAILED" ]; then
  ATTENTION_LINE=$(printf '%s' "$FAILED" | tr '\n' ' ')
  block "failed deliveries are not cleared: $ATTENTION_LINE"
fi

# ---------- gate D: git hygiene ----------
# Uncommitted changes block rather than get committed for you. What is in the
# working tree of a product checkout after a swarm run is either a role's
# leftover or a human's edit, and neither belongs in a PR nobody reviewed.
DIRTY=$(git_status "$ROOT" || true)
[ -z "$DIRTY" ] || block "uncommitted changes in $ROOT: $(printf '%s' "$DIRTY" | tr '\n' ';' )"

in_root "git fetch origin --quiet" >/dev/null 2>&1 \
  || block "git fetch origin failed — cannot compare against the remote"
if [ -z "$BASE" ]; then
  for candidate in main master; do
    if in_root "git rev-parse --verify --quiet $(printf '%q' "refs/remotes/origin/$candidate")" >/dev/null 2>&1; then
      BASE=$candidate; break
    fi
  done
fi
[ -n "$BASE" ] || die ERROR "no origin/main or origin/master in $ROOT and no --base given — add a remote first (gh repo create / git remote add)" 5

HEAD_SHA=$(in_root "git rev-parse --short HEAD") || die ERROR "cannot read HEAD in $ROOT" 5
HEAD_SHA=${HEAD_SHA%$'\n'}
BASE_SHA=$(in_root "git rev-parse --short $(printf '%q' "origin/$BASE")" 2>/dev/null || true)
BASE_SHA=${BASE_SHA%$'\n'}
AHEAD=$(in_root "git rev-list --count $(printf '%q' "origin/$BASE")..HEAD" 2>/dev/null || echo 0)
AHEAD=${AHEAD%$'\n'}
# Behind is reported, never blocking. The work is already finished, so refusing
# would strand it, and the PR is correct either way (GitHub diffs against the
# merge-base). What the operator needs to know is that the swarm built against a
# base that has since moved — the "nobody ran git pull after the merge" trap,
# arriving here through the Dashboard.
BEHIND=$(in_root "git rev-list --count HEAD..$(printf '%q' "origin/$BASE")" 2>/dev/null || echo 0)
BEHIND=${BEHIND%$'\n'}
COMMITS=$(in_root "git log --oneline $(printf '%q' "origin/$BASE")..HEAD" 2>/dev/null || true)

# ---------- what is being shipped ----------
# This was `accept work`, a separate verb until issue #158. It is inlined
# rather than shelled out to because after `run issue` was deleted this script
# became its ONLY caller, and the two halves talked through free text: the
# reader matched `index($0, "task: ") == 1` line by line, so renaming a field
# would have silently shifted every row. One adapter is a hypothetical seam.
#
# Everything from here to DEDUPED is that verb's body, moved verbatim. The
# hard parts are not obvious from the outside and are each held by a test:
# master worktree must be exactly one row, terminal delivery has two distinct
# signals, dedup compares completed_at as a width-normalised string because
# the producer omits the fraction on exact seconds, and inbox/new (5 min) and
# inbox/in_process (30 min) are deliberately different thresholds.
# Reachability/root gate: one cheap check up front means every later find/sed
# call below can safely swallow "nothing found" with `2>/dev/null` and `||
# true` without also swallowing a genuinely unreachable target or wrong
# --root — the same "check once, not once per caller" shape stop-swarm.sh
# uses for its worktree dedup.
run_remote "test -d '$ROOT/.swarmforge/handoffs'" \
  || die ERROR "$ROOT/.swarmforge/handoffs not found — check --root/--target/--local" 5

# Resolve the master worktree (issue #39): the terminal-handoff report must
# read ONLY the master Role's own inbox/completed/, never infer delivery
# from another worktree's copy of a handoff. roles.tsv's 7 tab-separated
# columns are role, worktree-name, worktree-path, session, display-name,
# agent, receive-mode (write-roles-file! in swarmforge.bb) — master is
# whichever row has worktree-name (column 2) literally "master", never the
# role name itself (role names differ per pack: coder/specifier/...), same
# $2=="master" judgment open-swarm.sh already uses for its own MASTER_N/
# MASTER_SESSION lookup. swarmforge.bb's require-master-worktree! guarantees
# exactly one master row at launch time, but that's a launch-time guarantee
# over parsed config — this script reads the already-on-disk roles.tsv, a
# separate artifact, so it re-validates rather than assuming the guarantee
# still holds.
ROLES=$(read_file .swarmforge/roles.tsv 2>/dev/null) \
  || die ERROR "$ROOT/.swarmforge/roles.tsv not found — cannot resolve the master worktree" 5
MASTER_N=$(printf '%s\n' "$ROLES" | awk -F'\t' '$2 == "master"' | wc -l | tr -d ' ')
[ "$MASTER_N" = 1 ] || die ERROR \
  "$ROOT/.swarmforge/roles.tsv has $MASTER_N rows with worktree-name == master (need exactly 1) — refusing to guess" 5
# Column 3 (worktree-path): for the literal "master" worktree-name,
# swarmforge.bb's special-worktree? logic always resolves this to the
# project root itself, but that mapping lives in swarmforge.bb, not here —
# use whatever column 3 says rather than special-casing "master path ==
# $ROOT" a second time in this script.
MASTER_PATH=$(printf '%s\n' "$ROLES" | awk -F'\t' '$2 == "master" {print $3}')

# list_headers <subdir> — finds every *.handoff file under the project-root
# inbox and every worktree inbox for that subdir (completed|new|in_process),
# same glob the existing manual command used (no roles.tsv lookup: a
# worktree's presence in .worktrees/ is what makes it discoverable here, same
# as the pre-existing completed-handoff command), then streams each match's
# first 15 header lines tagged with a `===FILE <path>===` marker so a single
# remote round trip can carry every file's headers instead of one ssh call
# per file.
list_headers() { # $1 = completed|new|in_process
  local cmd
  cmd="find '$ROOT/.swarmforge/handoffs/inbox/$1' '$ROOT'/.worktrees/*/.swarmforge/handoffs/inbox/$1 -name '*.handoff' 2>/dev/null | sort | while IFS= read -r f; do printf '===FILE %s===\n' \"\$f\"; sed -n '1,15p' \"\$f\"; done"
  run_remote "$cmd" || true
}

# list_master_completed — same header-streaming shape as list_headers, but
# scoped to exactly $MASTER_PATH's own inbox/completed (issue #39). Kept as
# a separate function rather than adding a "single directory" parameter to
# list_headers: stale_counts below still needs list_headers' broad
# every-worktree glob for its inbox/new and inbox/in_process WARN scan
# (issue #17, explicitly preserved by this change — see file header), and a
# second call site touching that shared function's signature/behavior would
# risk that unrelated scan for a change that has nothing to do with it. A
# thin sibling function is the smaller, safer diff.
#
# Reads the whole header block (up to the blank line) rather than list_headers'
# fixed first 15 lines. `non-forwarding` is not in render-message's `preferred`
# key order in handoffd.bb, so it is emitted after completed_at — on a delivered
# git_handoff that lands on line 15 exactly, with zero margin. One more header
# sorting before it (`remaining` is sorted alphabetically) would push it out of
# a 15-line window and the terminal check below would silently read false,
# dropping the very delivery record this verb exists to report.
list_master_completed() {
  local cmd
  cmd="find '$MASTER_PATH/.swarmforge/handoffs/inbox/completed' -name '*.handoff' 2>/dev/null | sort | while IFS= read -r f; do printf '===FILE %s===\n' \"\$f\"; sed -n '/^\$/q;p' \"\$f\"; done"
  run_remote "$cmd" || true
}

# parse_handoff_blocks — reads list_headers' `===FILE ...===` stream on stdin
# and prints one row per file: worktree, file, task, commit, completed_at,
# enqueued_at, dequeued_at, type (missing headers print empty), joined with
# ASCII unit separator (0x1F) rather than a tab. Several of these fields are
# routinely empty (a "new" row has no commit/completed_at/dequeued_at/type at
# all), and bash's `read` collapses RUNS of consecutive delimiters whenever
# the delimiter is tab/space/newline regardless of what IFS is set to — empty
# fields would silently disappear and shift every later column left. Unit
# separator isn't in that "IFS whitespace" special class, so `read` splits on
# it literally, one delimiter per field, same as awk's -F already does.
# `type` (issue #39: the terminal-handoff report now only accepts
# `type: git_handoff` records) is appended as the LAST field rather than
# inserted alongside task/commit — stale_counts below reads this same row
# shape by fixed column NUMBER (6 or 7, for enqueued_at/dequeued_at), and
# appending keeps those positions unchanged instead of shifting them.
# worktree is the directory basename under .worktrees/, or "master" for the
# project root's own inbox — the same worktree-naming the pre-existing
# completed-handoff command already relied on implicitly by listing the root
# path separately.
parse_handoff_blocks() {
  awk -v ROOT="$ROOT" -v OFS=$'\x1f' '
    function flush() {
      if (cur == "") return
      wt = "master"
      prefix = ROOT "/.worktrees/"
      if (index(cur, prefix) == 1) {
        rest = substr(cur, length(prefix) + 1)
        split(rest, parts, "/")
        wt = parts[1]
      }
      print wt, cur, task, commit, completed_at, enqueued_at, dequeued_at, type, from, to, nonfwd
    }
    /^===FILE / {
      flush()
      cur = $0
      sub(/^===FILE /, "", cur); sub(/===$/, "", cur)
      task=""; commit=""; completed_at=""; enqueued_at=""; dequeued_at=""; type=""
      from=""; to=""; nonfwd=""
      next
    }
    cur == "" { next }
    /^task:/         { sub(/^task:[ \t]*/, "");         task=$0;         next }
    /^commit:/       { sub(/^commit:[ \t]*/, "");       commit=$0;       next }
    /^completed_at:/ { sub(/^completed_at:[ \t]*/, ""); completed_at=$0; next }
    /^enqueued_at:/  { sub(/^enqueued_at:[ \t]*/, "");  enqueued_at=$0;  next }
    /^dequeued_at:/  { sub(/^dequeued_at:[ \t]*/, "");  dequeued_at=$0;  next }
    /^type:/         { sub(/^type:[ \t]*/, "");         type=$0;         next }
    /^from:/         { sub(/^from:[ \t]*/, "");         from=$0;         next }
    /^to:/           { sub(/^to:[ \t]*/, "");           to=$0;           next }
    /^non-forwarding:/ { sub(/^non-forwarding:[ \t]*/, ""); nonfwd=$0;   next }
    END { flush() }
  '
}

# to_epoch — converts a handoff header's ISO8601 UTC timestamp
# (2026-06-15T14:05:31Z) to epoch seconds, GNU date first, BSD date -j as the
# macOS fallback, so the conversion works regardless of which `date` runs
# this script (headers are this codebase's source of truth for handoff
# timing, not mtime — same reasoning handoffd.bb's own retry ladder uses).
to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}
NOW_EPOCH=$(date -u +%s)

# stale_counts <subdir> <ts-col:6|7> <threshold-seconds> <warn-suffix> —
# tallies, per worktree, how many files in <subdir> have their timestamp
# header older than the threshold, and prints one WARN= line per worktree
# that has at least one. A missing/unparseable timestamp is skipped rather
# than guessed at (never treated as either fresh or stale).
stale_counts() {
  local subdir=$1 col=$2 threshold=$3 suffix=$4
  local rows w ts ep age stale=''
  rows=$(list_headers "$subdir" | parse_handoff_blocks)
  [ -n "$rows" ] || return 0
  # 8 read vars, not 7: parse_handoff_blocks' row now ends with a type
  # field (issue #39). Without an f8 to catch it, bash's `read` would fold
  # the extra field (and its leading unit-separator byte) into f7 — the very
  # column this loop reads as the timestamp for inbox/in_process — silently
  # corrupting to_epoch's input. f8 itself is unused here.
  while IFS=$'\x1f' read -r f1 f2 f3 f4 f5 f6 f7 f8; do
    [ -n "$f1" ] || continue
    w=$f1
    case $col in 6) ts=$f6 ;; 7) ts=$f7 ;; esac
    [ -n "$ts" ] || continue
    ep=$(to_epoch "$ts") || continue
    age=$(( NOW_EPOCH - ep ))
    [ "$age" -ge "$threshold" ] && stale="${stale}${w}"$'\n'
  done <<< "$rows"
  [ -n "$stale" ] || return 0
  printf '%s' "$stale" | awk -v dir="$subdir" -v suf="$suffix" \
    '{c[$0]++} END{for (w in c) print "WARN=" c[w] " handoffs are stuck in inbox/" dir " in " w " — " suf}'
}

NEW_WARN=$(stale_counts new 6 "$STALE_NEW_SECONDS" "the chain is not moving")
INPROCESS_WARN=$(stale_counts in_process 7 "$STALE_INPROCESS_SECONDS" "claimed but not finishing")

# ---------- terminal-handoff report (issue #39: master-only, not inferred
# across worktrees) ----------
# Only the master worktree's own inbox/completed/ is a delivery record — see
# the file header and issue #39 for why scanning every worktree's completed/
# to infer the terminal hop was the bug (an intermediate chain hop got
# reported as the final result). stale_counts above is UNCHANGED and still
# scans every worktree via list_headers — that WARN scan (issue #17) is a
# separate, preserved concern.
COMPLETED_ROWS=$(list_master_completed | parse_handoff_blocks)

# ---------- terminal criterion (issue #39, corrected by
# docs/research/upstream-task-completion-protocol.md) ----------
# task/commit/completed_at only prove "this recipient merged the work and
# closed its queue item". The master completes non-terminal inbound handoffs
# too, and those carry all three fields and sit in the same inbox/completed/.
# Terminal is a property of the SENDING event, and there are two signals:
#
#   1. non-forwarding: true — swarm_handoff.bb stamps it when the sender is the
#      pack's last role. It is also enforced: holding a stamped inbound handoff
#      makes swarm_handoff.sh refuse to send another git_handoff.
#   2. the `to:` recipient SET equals every role except the sender — the
#      compatibility path for records written before the stamp existed.
#
# (2) is set equality, NOT a recipient count. In a two-pack "every role except
# cleaner" is just `coder`, so a terminal return looks like a single recipient
# and a count-based check would miss it — that is the bug this replaces.
ALL_ROLES=$(printf '%s\n' "$ROLES" | awk -F'\t' 'NF { print $1 }' | grep -v '^$' || true)

# Sorted, de-duplicated, comma-joined — so the two sides compare as sets and
# not as whatever order the sender happened to write `to:` in.
as_role_set() {
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' | sort -u | paste -sd, - || true
}

terminal_handoff() { # $1=from $2=to $3=non-forwarding
  local from=$1 to=$2 nonfwd=$3 expected actual
  if [ "$nonfwd" = true ]; then return 0; fi
  if [ -z "$from" ] || [ -z "$to" ]; then return 1; fi
  expected=$(as_role_set "$(printf '%s\n' "$ALL_ROLES" | grep -vxF "$from" || true)")
  actual=$(as_role_set "$to")
  if [ -z "$expected" ] || [ -z "$actual" ]; then return 1; fi
  [ "$expected" = "$actual" ]
}

# Field validation (issue #39): a record must be `type: git_handoff` with
# non-empty task/commit/completed_at to be a delivery-record candidate.
# Anything short of that is reported via WARN= naming the missing field(s),
# never silently dropped — the same "uncertain, so report it" philosophy
# git_merge_base_ancestor's own comment documents for a failed ancestor
# check (an error there means "not confirmed shipped", not "shipped"; here
# it means "not confirmed a delivery record", not "not worth mentioning").
# Emits one FILTERED line per completed file, tagged ROW or WARN so a single
# pass can be split into the WARN= lines to print and the rows that go on to
# dedup, without a second list_master_completed/parse_handoff_blocks call.
FILTERED=$(
  [ -n "$COMPLETED_ROWS" ] || exit 0
  while IFS=$'\x1f' read -r wt file task commit completed_at _enq _deq type from to nonfwd; do
    [ -n "$file" ] || continue
    # A record that declares some OTHER type is not a malformed delivery, it
    # is a different kind of message. Every New Task injection is a
    # `type: note`, so warning here printed one line per card on every run --
    # 37 of them on podsum's first real run, burying the one real blocker.
    # Same reasoning as the non-terminal skip below: always-true warnings get
    # ignored. An EMPTY type is still malformed and still warns.
    if [ -n "$type" ] && [ "$type" != git_handoff ]; then continue; fi
    missing=""
    [ "$type" = git_handoff ] || missing="${missing}type: git_handoff, "
    [ -n "$task" ] || missing="${missing}task, "
    [ -n "$commit" ] || missing="${missing}commit, "
    [ -n "$completed_at" ] || missing="${missing}completed_at, "
    if [ -n "$missing" ]; then
      printf 'WARN=%s missing %s — not reported as a delivery record\n' "$file" "${missing%, }"
      continue
    fi
    # A well-formed non-terminal record is not uncertain, it is simply an
    # intermediate hop the master merged and closed. Skipping it quietly is
    # deliberate: WARNing here would print a line on every ordinary run, and a
    # warning that is always true gets ignored. The WARN= lines above stay
    # reserved for records that are malformed.
    if ! terminal_handoff "$from" "$to" "$nonfwd"; then
      continue
    fi
    printf 'ROW\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$wt" "$file" "$task" "$commit" "$completed_at" "$type"
  done <<< "$COMPLETED_ROWS"
)
# `|| true` on both: under `set -o pipefail`, grep matching nothing (no
# WARN lines, or no ROW lines — both normal, common outcomes) makes the
# pipeline's exit status non-zero even though every other stage in it
# succeeded, which would otherwise abort this whole `set -e` script.
FIELD_WARN=$(printf '%s\n' "$FILTERED" | grep '^WARN=' || true)
VALID_ROWS=$(printf '%s\n' "$FILTERED" | { grep '^ROW' || true; } | cut -d $'\x1f' -f2-)

# Newest-per-task selection (issue #39). Primary judge is completed_at's RAW
# STRING, not an epoch conversion: to_epoch() (still used unmodified by
# stale_counts above) cannot parse this system's real fractional-second
# timestamps on this exact platform (GNU `date -d` doesn't exist on BSD/
# macOS; BSD `date -j -f '%Y-%m-%dT%H:%M:%SZ'` rejects the decimal point —
# empirically reproduced here with the issue's own
# `2026-08-24T17:26:56.932911Z`). Rather than patch a truncate-then-parse
# epoch helper into this path, this sidesteps date parsing entirely: these
# are fixed-width ISO8601 UTC strings from one producer (Instant/now()), so
# byte-lexical order equals chronological order ONCE the strings are the
# same width, with no epoch arithmetic needed at all — the "epoch only when
# something needs arithmetic with another time" case never arises here.
# The strings are NOT naturally the same width: Java's Instant.toString()
# (ISO_INSTANT, what done_with_current_task.bb emits) truncates trailing
# zeros and drops the fractional part entirely when the nanos land exactly
# on a second boundary, so one producer legitimately emits both
# `...:55Z` and `...:55.000001Z`. Raw bytes compare 'Z' > '.', which would
# pick the EARLIER record. So norm() below pads/truncates the fraction to a
# fixed 9 digits (Instant's max precision) FOR COMPARISON ONLY; the row
# kept and printed still carries the original completed_at verbatim.
# Only when two rows' NORMALIZED completed_at strings are identical (the same
# second, two terminal returns in a fast cleaner->coder loop) does this fall
# back to filename lexical order — an explicit, declared LAST-RESORT
# tie-break (filenames already carry a priority+timestamp prefix, this
# codebase's existing convention for ordering same-second files), never the
# primary judge.
DEDUPED=""
if [ -n "$VALID_ROWS" ]; then
  DEDUPED=$(printf '%s\n' "$VALID_ROWS" | LC_ALL=C awk -v FS=$'\x1f' -v OFS=$'\x1f' '
    # Fixed-width form of an ISO8601 UTC instant, comparison-only: the
    # fraction is zero-padded (or truncated) to 9 digits, so a no-fraction
    # timestamp becomes .000000000 and sorts before any fraction in the
    # same second instead of after it.
    function norm(t,   p, head, frac) {
      sub(/Z$/, "", t)
      p = index(t, ".")
      if (p) { head = substr(t, 1, p - 1); frac = substr(t, p + 1) }
      else   { head = t; frac = "" }
      return head "." substr(frac "000000000", 1, 9) "Z"
    }
    $3 != "" {
      k = $3; n = norm($5)
      if (!(k in seen) || n > best[k] || (n == best[k] && $2 > bestfile[k])) {
        seen[k] = 1; best[k] = n; bestfile[k] = $2; row[k] = $0
      }
    }
    END { for (k in row) print row[k] }
  ' | LC_ALL=C sort)
fi

# ---------- Board cross-check ----------
# The Board is corroboration, never the judge. handoffd writes a card to `done`
# at the moment it DELIVERS a terminal-shaped handoff — before any recipient has
# touched it — so `done` proves "the daemon read this delivery as terminal", not
# "the master processed it". A disagreement WARNs; it never suppresses a record.
#
# Nothing here assumes one delivery maps to one task name: handoffd's
# terminal-task-names can mark several cards done in a single delivery, so each
# reported task is looked up on its own.
board_lane() { # $1 = task name -> its lane, or empty if the card is absent
  printf '%s\n' "$BOARD" | awk -F'\t' -v t="$1" '$1 == t { print $2; exit }'
}

# CARDS and AW_WARN are what the rest of this script consumes, exactly the two
# things the old text interface carried — now as shell values, not as a report
# to re-parse.
AW_WARN=$(
  [ -z "$NEW_WARN" ] || printf '%s\n' "$NEW_WARN"
  [ -z "$INPROCESS_WARN" ] || printf '%s\n' "$INPROCESS_WARN"
  [ -z "$FIELD_WARN" ] || printf '%s\n' "$FIELD_WARN"
  if [ -z "$BOARD" ] && [ -n "$DEDUPED" ]; then
    printf 'WARN=no Board at %s — reporting from terminal handoffs alone (legacy/non-dashboard intake)\n' \
      "$BOARD_FILE"
  fi
)
CARDS=$(
  [ -n "$DEDUPED" ] || exit 0
  while IFS=$'\x1f' read -r _wt _file task commit completed_at _type; do
    [ -n "$task" ] || continue
    # Exclude already-shipped tasks: a completed handoff whose commit is
    # already an ancestor of the MANAGED PROJECT's own origin/main has been
    # accepted and merged, so it must not be reported again. A check that
    # errors (no commit, not a git repo, no origin/main) is NOT confirmed
    # shipped, so it still gets reported — never silently drop a task because
    # the ancestor check itself failed.
    if [ -n "$commit" ] && git_merge_base_ancestor "$commit" >/dev/null 2>&1; then
      continue
    fi
    printf '%s\t%s\n' "$task" "$commit"
  done <<< "$DEDUPED"
)
AW_WARN=$(
  printf '%s\n' "$AW_WARN"
  [ -z "$BOARD" ] || while IFS=$'\t' read -r task _commit; do
    [ -n "$task" ] || continue
    lane=$(board_lane "$task")
    if [ -z "$lane" ]; then
      printf 'WARN=%s has no Board card — reported from its terminal handoff alone\n' "$task"
    elif [ "$lane" != done ]; then
      printf 'WARN=%s is in Board lane %s, not done, but its handoff is terminal\n' "$task" "$lane"
    fi
  done <<< "$CARDS"
)
AW_WARN=$(printf '%s\n' "$AW_WARN" | grep -v '^$' || true)

# The window this verb exists to refuse: the board says done, the delivery
# record exists, and the commit has not reached the product HEAD yet because
# the master is still merging it. Shipping here loses a card silently.
MISSING='' CARD_ISSUES=''
while IFS=$'\t' read -r task commit; do
  [ -n "${commit:-}" ] || continue
  in_root "git merge-base --is-ancestor $(printf '%q' "$commit") HEAD" >/dev/null 2>&1 \
    || MISSING="${MISSING}${MISSING:+, }$task ($commit)"
  # The card text is what the operator typed into New Task, and it carries the
  # issue number. Only the cards BEING SHIPPED are read, never the whole board:
  # a card that is not in this PR must not put a Closes line in it.
  CARD_ISSUES="$CARD_ISSUES $(run_remote "grep -o '#[0-9][0-9]*' $(printf '%q' "$ROOT/.swarmforge/board/$task.txt") 2>/dev/null" | tr -d '#' | tr '\n' ' ' || true)"
done <<< "$CARDS"
CARD_ISSUES=$(printf '%s\n' $CARD_ISSUES | sort -un | tr '\n' ' ')
CARD_ISSUES=${CARD_ISSUES% }
[ -z "$MISSING" ] || block "delivered but not in HEAD yet — the master is still merging, re-run in a moment: $MISSING"

# Two sources, neither of them a guess, merged and deduplicated:
#   card text        `#<digits>` in what the operator typed into New Task.
#   --issue N        the caller says it, when the card text did not.
# The card text is typed by a human who is looking at the issue, which is what
# makes scanning it fair game. Nothing is inferred from the card NAME: a card
# cut in the Dashboard is named by a human or a model and carries no reliable
# issue number, and closing the wrong issue is worse than closing none.
closes_numbers() {
  printf '%s\n' $CARD_ISSUES $ISSUES \
    | { grep -E '^[0-9]+$' || true; } | sort -un
}

[ -n "$BRANCH" ] || BRANCH="feat/swarm-$PROJECT-$(date -u +%Y%m%d)"
TITLE="[swarm] $PROJECT: $(printf '%s\n' "$CARDS" | awk -F'\t' 'NF { print $1; exit }')"
[ "$TITLE" != "[swarm] $PROJECT: " ] || TITLE="[swarm] $PROJECT: ${MISSION:-published from the swarm board}"

# ---------- the report ----------
# Printed on every path, including the blocked one: the reason to refuse is
# only useful next to the state it was read from.
report() {
  printf 'project: %s\npath: %s\nmission: %s\nboard: done %s / waiting %s / live %s\nfailed deliveries: %s\nbase: origin/%s @ %s\nhead: %s (ahead %s, behind %s)\n' \
    "$PROJECT" "$ROOT" "${MISSION:-<no mission.md>}" "$DONE_N" "$WAIT_N" "$LIVE_N" \
    "$ATTENTION_LINE" "$BASE" "${BASE_SHA:-<unknown>}" "$HEAD_SHA" "$AHEAD" "$BEHIND"
  [ "${BEHIND:-0}" = 0 ] \
    || printf 'WARN=the swarm built on a base that has moved: HEAD is %s commits behind origin/%s\n' \
         "$BEHIND" "$BASE"
  printf 'cards to ship:\n'
  if [ -n "$CARDS" ]; then
    printf '%s\n' "$CARDS" | awk -F'\t' 'NF { printf "  %s  %s\n", $2, $1 }'
  else
    printf '  (none)\n'
  fi
  printf 'commits to ship:\n'
  if [ -n "$COMMITS" ]; then printf '%s\n' "$COMMITS" | sed 's/^/  /'
  else printf '  (none)\n'; fi
  # Printed BEFORE the PR is opened, on the pass that stops at NEEDS_PR_BODY,
  # so the operator sees exactly which issues are about to be closed while
  # there is still a pass left to drop a wrong one with --branch/--issue.
  WILL_CLOSE=$(closes_numbers | tr '\n' ' '); WILL_CLOSE=${WILL_CLOSE% }
  printf 'will close: %s\n' "${WILL_CLOSE:-none}"
  printf 'branch: %s\ntitle: %s\n' "$BRANCH" "$TITLE"
  [ -z "$AW_WARN" ] || printf '%s\n' "$AW_WARN"
}

if [ -n "$BLOCKERS" ]; then
  printf 'STATUS=BLOCKED\n'
  report
  printf 'blockers:\n%s\n' "$BLOCKERS"
  exit 6
fi

if [ -z "$CARDS" ] || [ "$AHEAD" = 0 ]; then
  printf 'STATUS=NOTHING_TO_SHIP\n'
  report
  printf 'nothing was pushed: %s\n' \
    "$([ -z "$CARDS" ] && echo 'accept work reports no unshipped delivery record' || echo "HEAD is not ahead of origin/$BASE")"
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  printf 'STATUS=DRY_RUN\n'
  report
  printf 'nothing was pushed and no branch was created; re-run without --dry-run\n'
  exit 0
fi

# ---------- push ----------
# The branch is created AT HEAD without checking it out. The product checkout
# stays on the branch the swarm left it on, and the role worktrees under
# .worktrees/ keep their own `swarmforge-<name>` branches — a checkout here
# would move the tree under running agents.
in_root "git rev-parse --verify --quiet $(printf '%q' "refs/heads/$BRANCH")" >/dev/null 2>&1 \
  || in_root "git branch $(printf '%q' "$BRANCH") HEAD" \
  || die ERROR "could not create $BRANCH at HEAD in $ROOT" 5
in_root "git push -u origin $(printf '%q' "$BRANCH")" \
  || die ERROR "could not push $BRANCH from $ROOT — the branch exists locally; re-run to continue" 5

# A run killed between the push and the PR must not open a second PR for the
# same head. The check runs BEFORE the body is required so a resume never costs
# a model call.
PR_URL=$(in_root "gh pr list --head $(printf '%q' "$BRANCH") --state open --json url --jq '.[].url' | head -1") \
  || PR_URL=''
PR_URL=${PR_URL%$'\n'}

if [ -z "$PR_URL" ]; then
  if [ -z "$BODY_FILE" ]; then
    printf 'STATUS=NEEDS_PR_BODY\n'
    report
    printf 'the branch is pushed and no PR is open. Write the body for origin/%s..%s, then re-run the same command with --body-file <path>. Send a subagent with the to-pr skill: the diff belongs in that subagent, not in yours. Do not write the card list or Closes lines — this verb appends them.\n' \
      "$BASE" "$BRANCH"
    exit 8
  fi
  [ -f "$BODY_FILE" ] \
    || die ERROR "--body-file $BODY_FILE does not exist; $BRANCH is pushed and no PR was opened" 5
  PR_PROSE=$(cat "$BODY_FILE")
  [ -n "$(printf '%s' "$PR_PROSE" | tr -d '[:space:]')" ] \
    || die ERROR "--body-file $BODY_FILE is empty; refusing to open a PR with no body. $BRANCH is pushed, no PR was opened" 5

  CLOSES=$(closes_numbers | sed 's/^/Closes #/')
  CARD_LINES=$(printf '%s\n' "$CARDS" | awk -F'\t' 'NF { printf "- %s (%s)\n", $1, $2 }')
  STALE_LINE=''
  [ "${BEHIND:-0}" = 0 ] || STALE_LINE=$(printf -- '- NOTE: this work was built on a base that has since moved; HEAD is %s commits behind origin/%s\n' "$BEHIND" "$BASE")
  PR_BODY=$(printf '%s%s\n\n---\n\n## Cards shipped\n%s\n\n## Verification\n- board: done %s / waiting %s / live %s, no failed deliveries outstanding\n- published from the managed project checkout %s at %s; no role worktree was used as the push source\n%s' \
    "${CLOSES:+$CLOSES$'\n\n'}" "$PR_PROSE" "$CARD_LINES" \
    "$DONE_N" "$WAIT_N" "$LIVE_N" "$ROOT" "$HEAD_SHA" \
    "$STALE_LINE")

  PR_OUT=$(in_root "gh pr create --base $(printf '%q' "$BASE") --head $(printf '%q' "$BRANCH") --title $(printf '%q' "$TITLE") --body $(printf '%q' "$PR_BODY")") \
    || die ERROR "gh pr create failed for $BRANCH -> $BASE in $ROOT" 5
  PR_URL=$(printf '%s\n' "$PR_OUT" | grep -o 'https://[^[:space:]]*' | tail -1 || true)
  [ -n "$PR_URL" ] || die ERROR "gh pr create returned no PR URL: $PR_OUT" 5
fi

printf 'STATUS=PR_OPENED\n'
report
printf 'url: %s\n' "$PR_URL"
exit 0
