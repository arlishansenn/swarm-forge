#!/usr/bin/env bash
# test-sync-worktree-scripts.sh — proves swarmforge.bb's sync-worktree-scripts!
# makes each role's swarmforge/scripts/ a true mirror of the installed
# script-dir (deletes obsolete leftovers, not just an overlay copy), and
# that scripts-mirror-matches? correctly detects a genuine mismatch before
# a role is allowed to launch. Run: bash scripts/test-sync-worktree-scripts.sh.
# Exits non-zero on any failure.
#
# context() in swarmforge.bb binds :script-dir to (fs/parent *file*) — the
# real directory this test file itself lives in — regardless of what root
# fixture path is passed to it. So the "installed source" side of every
# scenario below is this repo's own real swarmforge/scripts/ tree, not a
# fixture the test controls; only the role worktree side (the stale
# destination copy) is built by this test. That is intentional, per the
# brief: reuse (prepare-ctx (context root)) rather than inventing a second
# context-building path.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SWARMFORGE_BB=$HERE/swarmforge.bb
SCRIPT_DIR=$HERE
WORK=$(mktemp -d /tmp/sf-sync-scripts-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

if [ ! -f "$SWARMFORGE_BB" ]; then
  echo "swarmforge.bb missing — RED confirmed, all cases fail"; exit 1
fi

echo "== RED/GREEN suite for sync-worktree-scripts! / scripts-mirror-matches? =="

# ---------- Part 1: sync-worktree-scripts! wholesale-mirror behavior ----------
ROOT=$WORK/fixtures/proj
CODER_WT=$ROOT/.worktrees/coder
CODER_SCRIPTS=$CODER_WT/swarmforge/scripts

# Minimal real fixture: a config with exactly one master row (untouched,
# same worktree as working-dir) and one coder row (mirrored role).
mkdir -p "$ROOT/swarmforge/roles"
printf 'constitution\n' > "$ROOT/swarmforge/constitution.prompt"
printf 'master prompt\n' > "$ROOT/swarmforge/roles/master.prompt"
printf 'coder prompt\n' > "$ROOT/swarmforge/roles/coder.prompt"
cat > "$ROOT/swarmforge/swarmforge.conf" <<'EOF'
window master claude master task
window coder claude coder task
EOF

# State files sync-worktree-scripts! copies into every role's .swarmforge/
# — must exist under the fixture's own .swarmforge/ (the source side of
# those copies) or the sync call throws before it ever reaches the scripts
# mirror logic under test.
mkdir -p "$ROOT/.swarmforge"
: > "$ROOT/.swarmforge/sessions.tsv"
: > "$ROOT/.swarmforge/roles.tsv"
: > "$ROOT/.swarmforge/tmux-socket"
: > "$ROOT/.swarmforge/tmux-env"

# Canary under the master/root's own swarmforge/scripts/ — the root role's
# worktree-path equals working-dir, so sync-worktree-scripts! must never
# touch it at all (case 7).
mkdir -p "$ROOT/swarmforge/scripts"
printf 'canary\n' > "$ROOT/swarmforge/scripts/canary.txt"

# Stale role worktree scripts dir: obsolete top-level file (case 1),
# stale content on a file that also exists in the real source, so the
# mirror must win over any merge (case 2), and a nested obsolete file
# under a real subdirectory name to prove deletion isn't top-level-only
# (case 4).
mkdir -p "$CODER_SCRIPTS/terminal-adapters"
printf 'obsolete leftover, no longer in the installed source\n' > "$CODER_SCRIPTS/obsolete_helper.sh"
printf 'stale pre-update content\n' > "$CODER_SCRIPTS/swarm_tool.sh"
printf 'obsolete nested leftover\n' > "$CODER_SCRIPTS/terminal-adapters/obsolete-adapter.sh"

# Stale role roles/ dir — sync-worktree-roles! territory, must still get
# synced correctly by the same sync-worktree-scripts! call (case 8).
mkdir -p "$CODER_WT/swarmforge/roles"
printf 'stale role prompt, pre-sync\n' > "$CODER_WT/swarmforge/roles/coder.prompt"

bb "$SWARMFORGE_BB" --test-sync-worktree-scripts "$ROOT" > "$WORK/sync-out.txt" 2>"$WORK/sync-err.txt"
RC=$?
check "sync exit code" 0 "$RC" || cat "$WORK/sync-err.txt"

# case 1: obsolete top-level file removed
[ ! -e "$CODER_SCRIPTS/obsolete_helper.sh" ] \
  && ok "case1: obsolete top-level leftover removed from role copy" \
  || bad "case1: obsolete top-level leftover removed" "still present"

# case 2: differing content overwritten with the source's content (mirror
# wins, not a merge)
if [ -f "$CODER_SCRIPTS/swarm_tool.sh" ] && diff -q "$SCRIPT_DIR/swarm_tool.sh" "$CODER_SCRIPTS/swarm_tool.sh" >/dev/null 2>&1; then
  ok "case2: differing file now matches source content exactly"
else
  bad "case2: differing file now matches source content exactly" "content diverged from source"
fi

# case 3: a source file the role copy never had before is now present
if [ -f "$CODER_SCRIPTS/handoff_lib.bb" ] && diff -q "$SCRIPT_DIR/handoff_lib.bb" "$CODER_SCRIPTS/handoff_lib.bb" >/dev/null 2>&1; then
  ok "case3: brand-new source file present after sync"
else
  bad "case3: brand-new source file present after sync" "missing or mismatched"
fi

# case 4: nested obsolete file removed, nested real file present — proves
# this isn't a top-level-only fs/list-dir diff
[ ! -e "$CODER_SCRIPTS/terminal-adapters/obsolete-adapter.sh" ] \
  && ok "case4: obsolete NESTED leftover removed" \
  || bad "case4: obsolete NESTED leftover removed" "still present"
if [ -f "$CODER_SCRIPTS/terminal-adapters/iterm2.sh" ] && diff -q "$SCRIPT_DIR/terminal-adapters/iterm2.sh" "$CODER_SCRIPTS/terminal-adapters/iterm2.sh" >/dev/null 2>&1; then
  ok "case4: real NESTED source file present and matches after sync"
else
  bad "case4: real NESTED source file present and matches after sync" "missing or mismatched"
fi

# case 7: root/master worktree (worktree-path == working-dir) is never
# touched by the sync
[ "$(cat "$ROOT/swarmforge/scripts/canary.txt" 2>/dev/null)" = "canary" ] \
  && ok "case7: root/master's own swarmforge/scripts/ left untouched" \
  || bad "case7: root/master's own swarmforge/scripts/ left untouched" "canary missing or changed"

# case 8: sync-worktree-roles!'s territory still gets synced correctly by
# the same call (proves the scripts-dir delete-tree didn't clobber it)
if [ -f "$CODER_WT/swarmforge/roles/coder.prompt" ] && diff -q "$ROOT/swarmforge/roles/coder.prompt" "$CODER_WT/swarmforge/roles/coder.prompt" >/dev/null 2>&1; then
  ok "case8: role's swarmforge/roles/ content synced from source, unaffected by the scripts-dir change"
else
  bad "case8: role's swarmforge/roles/ content synced from source" "missing or stale"
fi

# ---------- Part 2: scripts-mirror-matches? via --test-scripts-mirror-matches ----------
MATCH_A=$WORK/mirror/match-a
MATCH_B=$WORK/mirror/match-b
mkdir -p "$MATCH_A/sub" "$MATCH_B/sub"
printf 'one\n' > "$MATCH_A/one.txt"
printf 'one\n' > "$MATCH_B/one.txt"
printf 'two\n' > "$MATCH_A/sub/two.txt"
printf 'two\n' > "$MATCH_B/sub/two.txt"

OUT=$(bb "$SWARMFORGE_BB" --test-scripts-mirror-matches "$MATCH_A" "$MATCH_B"); RC=$?
check "case5: identical trees -> exit code" 0 "$RC"
check "case5: identical trees -> output" "MATCH" "$OUT"

MISMATCH_A=$WORK/mirror/mismatch-a
MISMATCH_B=$WORK/mirror/mismatch-b
mkdir -p "$MISMATCH_A" "$MISMATCH_B"
printf 'one\n' > "$MISMATCH_A/one.txt"
printf 'one\n' > "$MISMATCH_B/one.txt"
printf 'extra file only in B\n' > "$MISMATCH_B/extra.txt"

OUT=$(bb "$SWARMFORGE_BB" --test-scripts-mirror-matches "$MISMATCH_A" "$MISMATCH_B"); RC=$?
check "case6: differing trees -> exit code" 1 "$RC"
check "case6: differing trees -> output" "MISMATCH" "$OUT"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
