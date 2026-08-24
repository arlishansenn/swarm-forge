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

# parse_handoff_blocks — reads list_headers' `===FILE ...===` stream on stdin
# and prints one row per file: worktree, file, task, commit, completed_at,
# enqueued_at, dequeued_at (missing headers print empty), joined with ASCII
# unit separator (0x1F) rather than a tab. Several of these fields are
# routinely empty (a "new" row has no commit/completed_at/dequeued_at at
# all), and bash's `read` collapses RUNS of consecutive delimiters whenever
# the delimiter is tab/space/newline regardless of what IFS is set to — empty
# fields would silently disappear and shift every later column left. Unit
# separator isn't in that "IFS whitespace" special class, so `read` splits on
# it literally, one delimiter per field, same as awk's -F already does.
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
      print wt, cur, task, commit, completed_at, enqueued_at, dequeued_at
    }
    /^===FILE / {
      flush()
      cur = $0
      sub(/^===FILE /, "", cur); sub(/===$/, "", cur)
      task=""; commit=""; completed_at=""; enqueued_at=""; dequeued_at=""
      next
    }
    cur == "" { next }
    /^task:/         { sub(/^task:[ \t]*/, "");         task=$0;         next }
    /^commit:/       { sub(/^commit:[ \t]*/, "");       commit=$0;       next }
    /^completed_at:/ { sub(/^completed_at:[ \t]*/, ""); completed_at=$0; next }
    /^enqueued_at:/  { sub(/^enqueued_at:[ \t]*/, "");  enqueued_at=$0;  next }
    /^dequeued_at:/  { sub(/^dequeued_at:[ \t]*/, "");  dequeued_at=$0;  next }
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
  while IFS=$'\x1f' read -r f1 f2 f3 f4 f5 f6 f7; do
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

# ---------- terminal-handoff report (the pre-existing manual logic) ----------
# Newest-per-(worktree,task) dedup: list_headers already returns files in
# sorted (chronological, since the filename leads with priority+timestamp)
# order, so a plain "last write wins" awk fold keeps only the terminal
# handoff for a task — the same "keep only the newest completed file for a
# given task: per worktree" rule SKILL.md has always documented. The original
# manual command piped through `tail` on top of `sort`, but that was a
# human's quick-glance truncation to the last 10 lines, not part of the
# dedup/exclusion logic itself — keeping it here would silently drop
# not-yet-accepted tasks once more than 10 terminal handoffs exist, which is
# exactly the kind of report gap this ticket exists to close.
COMPLETED_ROWS=$(list_headers completed | parse_handoff_blocks)
DEDUPED=$(printf '%s\n' "$COMPLETED_ROWS" \
  | awk -v FS=$'\x1f' -v US=$'\x1f' '$1 != "" && $3 != "" {a[$1 US $3] = $0} END {for (k in a) print a[k]}' \
  | sort)

printf 'STATUS=REPORTED\n'
[ -n "$NEW_WARN" ] && printf '%s\n' "$NEW_WARN"
[ -n "$INPROCESS_WARN" ] && printf '%s\n' "$INPROCESS_WARN"

if [ -n "$DEDUPED" ]; then
  while IFS=$'\x1f' read -r _wt _file task commit completed_at _enq _deq; do
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
