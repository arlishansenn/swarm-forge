#!/usr/bin/env bash
# accept-work.sh — human-acceptance report (issue #17). Ports the terminal-
# handoff report `accept work` has only ever documented as manual SKILL.md
# shell steps, and adds the report that was missing: a handoff stuck in
# inbox/new (nobody claimed it — the chain is broken) used to read identically
# to "no work finished yet", because the old command only ever looked at
# inbox/completed. This script also scans inbox/new and inbox/in_process for
# handoffs stuck past a staleness threshold and WARNs about them.
#
# Report verb (CONTEXT.md "## Operator verbs"): it only reads. It never
# modifies, moves, or deletes anything under inbox/ — completed/ is an audit
# trail, new/ and in_process/ are live queue state owned by the daemon and the
# ready_for_next/done_with_current helpers, not by a human-facing report.
#
# Exit codes / STATUS line:
#   0 REPORTED   2 USAGE   5 ERROR
# A stuck-chain WARN does not change the exit code — see the Verb contract in
# ../SKILL.md ("Success can also speak"): a stuck chain is information this
# verb successfully reported, not a failure of the verb itself.
# Contract details live in ../SKILL.md (verb: accept work).
#
# Usage: accept-work.sh --root <project-root> \
#   [--target user@host] [--key <path>] [--local]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' LOCAL=0

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

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    *) sed -n '2,20p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] || { sed -n '2,20p' "$0"; exit 2; }

# run_remote — executes a fixed, script-built shell snippet against ROOT's
# host, local or remote. Only ever built from ROOT itself (a trusted CLI
# argument, single-quoted the same way read_file/do_stop already interpolate
# ROOT elsewhere in this skill) and fixed glob/flag text — never from content
# parsed out of a handoff file. That untrusted case (a commit hash) goes
# through git_merge_base_ancestor's %q-quoting instead, never through here.
run_remote() {
  if [ "$LOCAL" = 1 ]; then bash -c "$1"
  else ssh -i "$KEY" "$TARGET" "$1"; fi
}

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
list_master_completed() {
  local cmd
  cmd="find '$MASTER_PATH/.swarmforge/handoffs/inbox/completed' -name '*.handoff' 2>/dev/null | sort | while IFS= read -r f; do printf '===FILE %s===\n' \"\$f\"; sed -n '1,15p' \"\$f\"; done"
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
      print wt, cur, task, commit, completed_at, enqueued_at, dequeued_at, type
    }
    /^===FILE / {
      flush()
      cur = $0
      sub(/^===FILE /, "", cur); sub(/===$/, "", cur)
      task=""; commit=""; completed_at=""; enqueued_at=""; dequeued_at=""; type=""
      next
    }
    cur == "" { next }
    /^task:/         { sub(/^task:[ \t]*/, "");         task=$0;         next }
    /^commit:/       { sub(/^commit:[ \t]*/, "");       commit=$0;       next }
    /^completed_at:/ { sub(/^completed_at:[ \t]*/, ""); completed_at=$0; next }
    /^enqueued_at:/  { sub(/^enqueued_at:[ \t]*/, "");  enqueued_at=$0;  next }
    /^dequeued_at:/  { sub(/^dequeued_at:[ \t]*/, "");  dequeued_at=$0;  next }
    /^type:/         { sub(/^type:[ \t]*/, "");         type=$0;         next }
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
  while IFS=$'\x1f' read -r wt file task commit completed_at _enq _deq type; do
    [ -n "$file" ] || continue
    missing=""
    [ "$type" = git_handoff ] || missing="${missing}type: git_handoff, "
    [ -n "$task" ] || missing="${missing}task, "
    [ -n "$commit" ] || missing="${missing}commit, "
    [ -n "$completed_at" ] || missing="${missing}completed_at, "
    if [ -n "$missing" ]; then
      printf 'WARN=%s missing %s — not reported as a delivery record\n' "$file" "${missing%, }"
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

printf 'STATUS=REPORTED\n'
[ -n "$NEW_WARN" ] && printf '%s\n' "$NEW_WARN"
[ -n "$INPROCESS_WARN" ] && printf '%s\n' "$INPROCESS_WARN"
[ -n "$FIELD_WARN" ] && printf '%s\n' "$FIELD_WARN"

if [ -n "$DEDUPED" ]; then
  while IFS=$'\x1f' read -r _wt _file task commit completed_at _type; do
    [ -n "$task" ] || continue
    # Exclude already-shipped tasks: a completed handoff whose commit is
    # already an ancestor of the MANAGED PROJECT's own origin/main (not
    # swarm-forge's) has been accepted and merged, so it must not be
    # reported again. A check that errors (no commit, not a git repo, no
    # origin/main) is NOT confirmed shipped, so it still gets reported —
    # never silently drop a task because the ancestor check itself failed.
    if [ -n "$commit" ] && git_merge_base_ancestor "$commit" >/dev/null 2>&1; then
      continue
    fi
    printf 'task: %s\ncommit: %s\ncompleted_at: %s\n\n' "$task" "$commit" "$completed_at"
  done <<< "$DEDUPED"
fi

exit 0
