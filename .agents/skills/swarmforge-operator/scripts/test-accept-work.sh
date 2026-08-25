#!/usr/bin/env bash
# test-accept-work.sh — end-to-end checks for accept-work.sh against a
# stubbed git (issue #17; narrowed to master-only delivery records by issue
# #39). Run: bash scripts/test-accept-work.sh. Exits non-zero on any
# failure. Local-mode cases run --local (same convention as
# test-stop-swarm.sh), so ssh is never invoked there; find/sed run for real
# against fixture files under a temp ROOT, and only `git` is stubbed, for the
# merge-base --is-ancestor exclusion check. A remote-mode case below (issue
# #36) adds a stub ssh that actually simulates real ssh's own
# stdin-forwarding behavior — see test-read-swarm.sh's stub comment for why
# a naive argv-logging stub would not catch this bug.
#
# issue #39: accept-work.sh now requires a valid .swarmforge/roles.tsv with
# exactly one worktree-name == master row before it will report anything —
# every case below that expects STATUS=REPORTED calls mk_roles first. The
# three roles.tsv-error cases (missing / 0 master / 2 master rows) are the
# only ones that deliberately omit or misconfigure it.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ACCEPT=$HERE/accept-work.sh
WORK=$(mktemp -d /tmp/sf-accept-work-test.XXXXXX)
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stub git: accept-work.sh only ever calls
# `git -C <ROOT> merge-base --is-ancestor <commit> origin/main` — mirror the
# real command's exit-code contract (0 = ancestor/shipped, 1 = not) off a
# fixture list of "shipped" commits, so the test never touches a real repo.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'git %s\n' "$*" >> "$STUB/calls.log"
commit="" prev=""
for a in "$@"; do
  [ "$prev" = "--is-ancestor" ] && commit=$a
  prev=$a
done
grep -qxF "$commit" "$STUB/shipped-commits" 2>/dev/null && exit 0 || exit 1
EOF
chmod +x "$WORK/bin/git"

# ---------- stub ssh (issue #36) — see test-read-swarm.sh for why this must
# actually drain its own stdin when invoked without -n, not just log argv
# and run the command ----------
cat > "$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'ssh %s\n' "$*" >> "$STUB/calls.log"
has_n=0
for a in "$@"; do [ "$a" = "-n" ] && has_n=1; done
[ "$has_n" = 1 ] || cat >/dev/null
cmd=${*: -1}
bash -c "$cmd"
EOF
chmod +x "$WORK/bin/ssh"

export STUB=$WORK/stub
reset_stub() { rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls.log"; : > "$STUB/shipped-commits"; }
ship() { printf '%s\n' "$1" >> "$STUB/shipped-commits"; }  # ship <commit> — marks it already on origin/main

ROOT=$WORK/fixtures/twopack
now=$(date -u +%s)
# ts <seconds-ago> — ISO8601 UTC, GNU date first then BSD -j (macOS)
# fallback, same two-path conversion accept-work.sh's own to_epoch() uses
# for the reverse direction (still exercises both date paths on whichever
# machine runs this suite).
ts() {
  local ep=$(( now - $1 ))
  date -u -d "@$ep" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -j -f %s "$ep" +%Y-%m-%dT%H:%M:%SZ
}
# ts_frac <seconds-ago> — same as ts(), but with a fractional-second suffix
# in the real shape Instant/now() produces (issue #39's
# 2026-08-24T17:26:56.932911Z evidence timestamp), built on top of ts()'s
# own GNU/BSD dual-path second, so a fractional fixture still exercises
# both date paths, not a hand-typed string with no path coverage at all.
ts_frac() {
  local base; base=$(ts "$1")
  printf '%s' "${base%Z}.932911Z"
}

reset_fixture() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT/.swarmforge/handoffs/inbox/completed" \
           "$ROOT/.swarmforge/handoffs/inbox/new" \
           "$ROOT/.swarmforge/handoffs/inbox/in_process"
}

# mk_roles <role> <worktree-name> <worktree-path> [<role> <worktree-name>
# <worktree-path> ...] — writes .swarmforge/roles.tsv with the 7
# tab-separated columns write-roles-file! produces in swarmforge.bb: role,
# worktree-name, worktree-path, session, display-name, agent, receive-mode.
# accept-work.sh only ever reads columns 2 and 3 (worktree-name,
# worktree-path); session/display-name/agent/receive-mode are fixture
# placeholders.
mk_roles() {
  : > "$ROOT/.swarmforge/roles.tsv"
  while [ $# -gt 0 ]; do
    local role=$1 wt=$2 path=$3; shift 3
    printf '%s\t%s\t%s\tsess-%s\tDisp-%s\tclaude\tpush\n' \
      "$role" "$wt" "$path" "$wt" "$wt" >> "$ROOT/.swarmforge/roles.tsv"
  done
}

# mk_completed <worktree|-> <filename> <task> <commit> <age-seconds-or-ts> [type]
# 5th arg is either a bare integer (seconds ago, passed through ts()) or an
# already-formatted ISO8601 timestamp (contains "T") for callers that need
# an exact string (e.g. a real fractional-second fixture, or a forced tie).
# 6th arg (issue #39) is the record's `type:` header, defaulting to
# git_handoff — the only type the terminal-handoff report now accepts.
mk_completed() {
  local dir=$ROOT/.swarmforge/handoffs/inbox/completed
  [ "$1" = - ] || { dir=$ROOT/.worktrees/$1/.swarmforge/handoffs/inbox/completed; mkdir -p "$dir"; }
  local when=$5
  case $when in *T*) : ;; *) when=$(ts "$when") ;; esac
  local type=${6:-git_handoff}
  cat > "$dir/$2" <<EOF
id: x
type: $type
task: $3
commit: $4
completed_at: $when

body
EOF
}
# mk_completed_raw <worktree|-> <filename> <raw-content> — for missing-field
# WARN fixtures where mk_completed's fixed field set can't express "commit
# header line absent entirely" or "no type: line at all".
mk_completed_raw() {
  local dir=$ROOT/.swarmforge/handoffs/inbox/completed
  [ "$1" = - ] || { dir=$ROOT/.worktrees/$1/.swarmforge/handoffs/inbox/completed; mkdir -p "$dir"; }
  printf '%s\n' "$3" > "$dir/$2"
}
# mk_new <worktree|-> <filename> <task> <age-seconds>
mk_new() {
  local dir=$ROOT/.swarmforge/handoffs/inbox/new
  [ "$1" = - ] || { dir=$ROOT/.worktrees/$1/.swarmforge/handoffs/inbox/new; mkdir -p "$dir"; }
  cat > "$dir/$2" <<EOF
id: x
task: $3
enqueued_at: $(ts "$4")

body
EOF
}
# mk_inprocess <worktree|-> <filename> <task> <age-seconds>
mk_inprocess() {
  local dir=$ROOT/.swarmforge/handoffs/inbox/in_process
  [ "$1" = - ] || { dir=$ROOT/.worktrees/$1/.swarmforge/handoffs/inbox/in_process; mkdir -p "$dir"; }
  cat > "$dir/$2" <<EOF
id: x
task: $3
dequeued_at: $(ts "$4")

body
EOF
}

run() {
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB bash "$ACCEPT" --local --root "$ROOT" 2>&1)
  RC=$?
}
run_remote() {  # runs against $ROOT via --target instead of --local
  OUT=$(PATH="$WORK/bin:$PATH" STUB=$STUB \
    bash "$ACCEPT" --target test-target --key /dev/null --root "$ROOT" 2>&1)
  RC=$?
}

# checksum every file under every inbox/ tree in the fixture — used to assert
# accept-work.sh never writes, moves, or deletes a handoff file.
inbox_checksum() {
  find "$ROOT" -path '*/handoffs/inbox/*' -type f -print0 \
    | sort -z | xargs -0 cksum 2>/dev/null
}

echo "== RED/GREEN suite for accept-work.sh =="

if [ ! -f "$ACCEPT" ]; then
  echo "script missing — RED confirmed, all cases fail"; exit 1
fi

# 1. clean run: nothing in new/in_process/completed anywhere, valid master
#    roles.tsv -> STATUS=REPORTED, no WARN=, exit 0. This is the "genuinely
#    no work finished yet" case the issue says must read differently from a
#    stuck chain.
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
run
check "clean exit" 0 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=REPORTED$' \
  && ok "clean status is REPORTED" || bad "clean status is REPORTED" "$OUT"
! printf '%s\n' "$OUT" | grep -q '^WARN=' \
  && ok "clean: no WARN" || bad "clean: no WARN" "$OUT"

# 2. a FRESH inbox/new file (enqueued seconds ago) must not WARN — presence
#    alone is not "stuck"; a healthy chain routinely has a file sit briefly
#    between delivery and pickup (handoffd's own retry ladder doesn't even
#    send its first re-wake until 5s have passed).
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
mk_new cleaner 01_fresh.handoff task-fresh 5
run
check "fresh new exit" 0 "$RC"
! printf '%s\n' "$OUT" | grep -q '^WARN=' \
  && ok "fresh inbox/new: no WARN" || bad "fresh inbox/new: no WARN" "$OUT"

# 3. THREE stale inbox/new files in one worktree -> WARN= with the count and
#    the worktree name, exit still 0 (a stuck chain is information the verb
#    successfully reported, not a verb failure). This stale scan (issue #17)
#    is unchanged by issue #39 and stays glob-based across every worktree
#    under .worktrees/, independent of roles.tsv.
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
mk_new cleaner 01_stale.handoff task-a 4000
mk_new cleaner 02_stale.handoff task-b 4000
mk_new cleaner 03_stale.handoff task-c 4000
run
check "stale new exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^WARN=3 handoffs are stuck in inbox/new in cleaner ' \
  && ok "stale inbox/new: WARN names count and worktree" \
  || bad "stale inbox/new: WARN names count and worktree" "$OUT"

# 4. a stale inbox/in_process file (claimed but not finishing) -> its own
#    WARN=, distinct wording from inbox/new, exit 0.
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
mk_inprocess coder2 01_stuck.handoff task-d 3600
run
check "stale in_process exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^WARN=1 handoffs are stuck in inbox/in_process in coder2 ' \
  && ok "stale inbox/in_process: WARN names count and worktree" \
  || bad "stale inbox/in_process: WARN names count and worktree" "$OUT"
# an in-progress task well under the (much longer) in_process threshold must
# not WARN, even though it would already be "stale" by inbox/new's threshold —
# ordinary task duration must not trip this one.
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
mk_inprocess coder2 01_working.handoff task-e 600
run
! printf '%s\n' "$OUT" | grep -q '^WARN=' \
  && ok "in-progress inbox/in_process: no WARN" || bad "in-progress inbox/in_process: no WARN" "$OUT"

# 5. two-pack: THE ISSUE #39 BUG SCENARIO, real values from the issue's own
#    "Live regression evidence" section. cleaner (non-master) has an
#    INTERMEDIATE inbound hop in its completed/; master (worktree-name ==
#    master, role name "coder") has the TERMINAL handoff. Only master's
#    commit may ever be reported — the cleaner copy is audit trail, not a
#    delivery record. This is the exact case the old worktree-scanning
#    implementation got wrong (it reported the cleaner intermediate commit).
reset_fixture; reset_stub
mk_roles coder master "$ROOT" cleaner cleaner "$ROOT/.worktrees/cleaner"
mk_completed cleaner 00_intermediate.handoff podsum-task eb4e6f26c9 100
mk_completed - 00_20260824T172530Z_000001_from_cleaner_to_coder.handoff \
  podsum-task 455592c671 2026-08-24T17:26:56.932911Z
run
check "two-pack exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^commit: 455592c671$' \
  && ok "two-pack: master terminal commit reported" \
  || bad "two-pack: master terminal commit reported" "$OUT"
! printf '%s\n' "$OUT" | grep -q 'eb4e6f26c9' \
  && ok "two-pack: cleaner intermediate commit NOT reported" \
  || bad "two-pack: cleaner intermediate commit NOT reported" "$OUT"
N=$(printf '%s\n' "$OUT" | grep -c '^task: podsum-task$')
check "two-pack: exactly one delivery record" 1 "$N"

# 6. four-pack: master Role's NAME is "specifier" (not "coder"), but
#    worktree-name is still literally "master" — proves the judgment is on
#    column 2 (worktree-name), never a hardcoded role name. A non-master
#    "architect" worktree's completed copy must still be ignored.
reset_fixture; reset_stub
mk_roles specifier master "$ROOT" architect architect "$ROOT/.worktrees/architect"
mk_completed architect 00_intermediate.handoff four-task aaaaaaaa01 100
mk_completed - 00_terminal.handoff four-task bbbbbbbb02 50
run
check "four-pack exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^commit: bbbbbbbb02$' \
  && ok "four-pack: master (specifier) terminal commit reported" \
  || bad "four-pack: master (specifier) terminal commit reported" "$OUT"
! printf '%s\n' "$OUT" | grep -q 'aaaaaaaa01' \
  && ok "four-pack: architect intermediate commit NOT reported" \
  || bad "four-pack: architect intermediate commit NOT reported" "$OUT"

# 7. six-pack QA broadcast: several worktrees each hold their OWN independent
#    completed copy of the same task (upstream handoffd.bb's deliver! writes
#    one file per recipient, not one shared file) — only master's copy may
#    be reported, the rest are other Roles' own audit trail.
reset_fixture; reset_stub
mk_roles specifier master "$ROOT" \
  architect architect "$ROOT/.worktrees/architect" \
  coder coder "$ROOT/.worktrees/coder" \
  tester tester "$ROOT/.worktrees/tester"
mk_completed architect 00_qa.handoff qa-broadcast-task cccccccc01 100
mk_completed coder     00_qa.handoff qa-broadcast-task cccccccc01 100
mk_completed tester    00_qa.handoff qa-broadcast-task cccccccc01 100
mk_completed -         00_qa.handoff qa-broadcast-task cccccccc01 100
run
check "six-pack exit" 0 "$RC"
N=$(printf '%s\n' "$OUT" | grep -c '^task: qa-broadcast-task$')
check "six-pack: exactly one delivery record (master's copy only)" 1 "$N"

# 8. fractional-second completed_at (issue #39's real evidence timestamp,
#    2026-08-24T17:26:56.932911Z): the report must round-trip it unchanged,
#    not fail to parse it or truncate it away. to_epoch() genuinely cannot
#    parse this shape on this platform (verified separately, see report) —
#    this proves the terminal-handoff path never depends on that broken
#    conversion.
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
mk_completed - 00_frac.handoff frac-task dddddddd03 2026-08-24T17:26:56.932911Z
run
check "fractional completed_at exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^completed_at: 2026-08-24T17:26:56.932911Z$' \
  && ok "fractional completed_at reported unchanged" \
  || bad "fractional completed_at reported unchanged" "$OUT"

# 9. same task, multiple terminal returns with DIFFERENT completed_at ->
#    newest wins, judged by the completed_at STRING (not filename): the
#    older record's filename deliberately sorts AFTER the newer record's
#    filename, so a filename-primary implementation would get this wrong.
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
mk_completed - zz_older.handoff same-task eeeeeeee04 "$(ts_frac 200)"
mk_completed - aa_newer.handoff same-task ffffffff05 "$(ts_frac 50)"
run
check "newest-wins exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^commit: ffffffff05$' \
  && ok "newest-wins: picks the later completed_at, not the earlier filename" \
  || bad "newest-wins: picks the later completed_at, not the earlier filename" "$OUT"
N=$(printf '%s\n' "$OUT" | grep -c '^task: same-task$')
check "newest-wins: exactly one entry" 1 "$N"

# 10. same task, IDENTICAL completed_at strings (a real scenario: two
#     done_with_current completions in the same second on a fast
#     cleaner->coder loop) -> explicit last-resort tie-break by filename
#     lexical order, deterministic across repeated runs, not undefined
#     behavior.
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
SAME_TS=$(ts_frac 100)
mk_completed - aa_first.handoff tie-task 1111111106 "$SAME_TS"
mk_completed - bb_second.handoff tie-task 2222222207 "$SAME_TS"
run
check "tie-break exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^commit: 2222222207$' \
  && ok "tie-break: lexically-later filename wins" \
  || bad "tie-break: lexically-later filename wins" "$OUT"
FIRST_OUT=$OUT
run
check "tie-break: repeat run same exit" 0 "$RC"
check "tie-break: repeat run gives identical result" "$FIRST_OUT" "$OUT"

# 11. missing commit field -> WARN naming "commit", not reported as a
#     delivery record (and not silently dropped).
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
mk_completed_raw - 00_nocommit.handoff "id: x
type: git_handoff
task: task-nocommit
completed_at: $(ts 10)

body"
run
check "missing commit exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^WARN=.*missing commit' \
  && ok "missing commit: WARN names the field" || bad "missing commit: WARN names the field" "$OUT"
! printf '%s\n' "$OUT" | grep -q '^task: task-nocommit$' \
  && ok "missing commit: not reported as delivery record" \
  || bad "missing commit: not reported as delivery record" "$OUT"

# 12. missing/wrong `type: git_handoff` field -> WARN naming it, not
#     reported (e.g. a New Task note landing in master's completed must not
#     be mistaken for a delivery record).
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
mk_completed_raw - 00_notype.handoff "id: x
task: task-notype
commit: 3333333308
completed_at: $(ts 10)

body"
run
check "missing type exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^WARN=.*missing.*type: git_handoff' \
  && ok "missing type: WARN names the field" || bad "missing type: WARN names the field" "$OUT"
! printf '%s\n' "$OUT" | grep -q '^task: task-notype$' \
  && ok "missing type: not reported as delivery record" \
  || bad "missing type: not reported as delivery record" "$OUT"

# 13. roles.tsv missing entirely -> STATUS=ERROR exit 5, message names the
#     file, no guessing.
reset_fixture; reset_stub
run
check "roles.tsv missing exit" 5 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=ERROR$' \
  && ok "roles.tsv missing: STATUS=ERROR" || bad "roles.tsv missing: STATUS=ERROR" "$OUT"
printf '%s\n' "$OUT" | grep -q "$ROOT/.swarmforge/roles.tsv" \
  && ok "roles.tsv missing: message names the file" || bad "roles.tsv missing: message names the file" "$OUT"

# 14. roles.tsv has zero worktree-name==master rows -> STATUS=ERROR exit 5,
#     count named, no guessing.
reset_fixture; reset_stub
mk_roles coder somewt "$ROOT/.worktrees/somewt"
run
check "zero master rows exit" 5 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=ERROR$' \
  && ok "zero master rows: STATUS=ERROR" || bad "zero master rows: STATUS=ERROR" "$OUT"
printf '%s\n' "$OUT" | grep -q ' 0 rows with worktree-name == master' \
  && ok "zero master rows: message names the count" || bad "zero master rows: message names the count" "$OUT"

# 15. roles.tsv has TWO worktree-name==master rows -> STATUS=ERROR exit 5,
#     count named, no guessing/picking the first one.
reset_fixture; reset_stub
mk_roles coder master "$ROOT" architect master "$ROOT/.worktrees/architect"
run
check "two master rows exit" 5 "$RC"
printf '%s\n' "$OUT" | head -1 | grep -q '^STATUS=ERROR$' \
  && ok "two master rows: STATUS=ERROR" || bad "two master rows: STATUS=ERROR" "$OUT"
printf '%s\n' "$OUT" | grep -q ' 2 rows with worktree-name == master' \
  && ok "two master rows: message names the count" || bad "two master rows: message names the count" "$OUT"

# 16. pre-existing exclusion, now master-only: a completed handoff whose
#     commit is already on origin/main must not be reported again; a
#     sibling not-yet-shipped completed handoff still is. This is the manual
#     logic being preserved, not new behavior.
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
ship aaaaaaaaaa
mk_completed - 00_shipped.handoff task-shipped aaaaaaaaaa 100
mk_completed - 00_unshipped.handoff task-unshipped bbbbbbbbbb 50
run
check "exclusion exit" 0 "$RC"
! printf '%s\n' "$OUT" | grep -q 'task: task-shipped' \
  && ok "already-shipped commit excluded" || bad "already-shipped commit excluded" "$OUT"
printf '%s\n' "$OUT" | grep -q 'task: task-unshipped' \
  && ok "not-yet-shipped commit still reported" || bad "not-yet-shipped commit still reported" "$OUT"
printf '%s\n' "$OUT" | grep -q 'commit: bbbbbbbbbb' \
  && ok "unshipped report carries its commit" || bad "unshipped report carries its commit" "$OUT"

# 17. never writes: a fixture combining every kind of file (master completed,
#     a non-master worktree's completed, stale new, stale in_process) is
#     checksummed before and after two runs; every file must be
#     byte-for-byte and file-for-file unchanged.
reset_fixture; reset_stub
mk_roles coder master "$ROOT" cleaner cleaner "$ROOT/.worktrees/cleaner"
mk_completed - 00_a.handoff task-a aaaaaaaaaa 100
mk_completed cleaner 00_b.handoff task-b cccccccccc 90
mk_new cleaner 01_stale.handoff task-c 4000
mk_new cleaner 02_fresh.handoff task-d 5
mk_inprocess coder2 01_stuck.handoff task-e 3600
BEFORE=$(inbox_checksum)
run; run
AFTER=$(inbox_checksum)
check "no writes under inbox/ across two runs" "$BEFORE" "$AFTER"

# 18. remote mode, master-only, 2+ completed records, one already shipped
#     (issue #36 regression): the DEDUPED report loop's git_merge_base_ancestor
#     call must not drain the loop's here-string and silently drop every row
#     past the first — both rows must still be correctly handled.
reset_fixture; reset_stub
mk_roles coder master "$ROOT"
ship cccccccccc
mk_completed - 01_a.handoff task-a aaaaaaaaaa 100
mk_completed - 02_b.handoff task-b bbbbbbbbbb 90
mk_completed - 03_c.handoff task-c cccccccccc 80
run_remote
check "remote 3-row exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q 'task: task-a' \
  && ok "remote: first row (unshipped) reported" || bad "remote: first row (unshipped) reported" "$OUT"
printf '%s\n' "$OUT" | grep -q 'task: task-b' \
  && ok "remote: second row (unshipped) reported" || bad "remote: second row (unshipped) reported" "$OUT"
! printf '%s\n' "$OUT" | grep -q 'task: task-c' \
  && ok "remote: third row (already-shipped) correctly excluded" \
  || bad "remote: third row (already-shipped) correctly excluded" "$OUT"

# 19. stale WARN scan and master-only delivery records coexist without
#     interfering (regression guard for the riskiest part of this change):
#     a stuck inbox/new file in a non-master worktree still WARNs, and
#     master's own completed record is still correctly reported, in the
#     same run.
reset_fixture; reset_stub
mk_roles coder master "$ROOT" cleaner cleaner "$ROOT/.worktrees/cleaner"
mk_new cleaner 01_stale.handoff task-stuck 4000
mk_completed - 00_done.handoff task-done 4444444409 50
run
check "coexist exit" 0 "$RC"
printf '%s\n' "$OUT" | grep -q '^WARN=1 handoffs are stuck in inbox/new in cleaner ' \
  && ok "coexist: stale WARN still fires" || bad "coexist: stale WARN still fires" "$OUT"
printf '%s\n' "$OUT" | grep -q '^commit: 4444444409$' \
  && ok "coexist: master completed record still reported" \
  || bad "coexist: master completed record still reported" "$OUT"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
