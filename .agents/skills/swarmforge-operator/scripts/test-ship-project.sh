#!/usr/bin/env bash
# test-ship-project.sh — end-to-end checks for ship-project.sh.
# Run: bash scripts/test-ship-project.sh. Exits non-zero on any failure.
#
# Real git, stubbed gh. Every assertion here is about what the verb does to a
# repository — creates a branch or not, pushes once or twice, opens a PR or
# refuses — so a stubbed git would be testing the stub. `origin` is a local
# bare repo, which makes fetch/push/rev-list/merge-base all real. Only `gh` is
# stubbed, because it is the one command that would reach GitHub.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SHIP=$HERE/ship-project.sh
WORK=$(mktemp -d /tmp/sf-ship-test.XXXXXX)
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
has()  { printf '%s\n' "$2" | grep -q -- "$3" && ok "$1" || bad "$1" "missing [$3] in: $2"; }
hasnt(){ printf '%s\n' "$2" | grep -q -- "$3" && bad "$1" "unexpected [$3] in: $2" || ok "$1"; }

# ---------- stub gh ----------
# Logs argv and answers `pr list` from a fixture file, so a test can set up
# "this head already has an open PR" without a network.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$STUB/gh.log"
case "$1 $2" in
  "pr list") cat "$STUB/existing-pr" 2>/dev/null || true; exit 0 ;;
  "pr create")
    [ -f "$STUB/pr-create-fails" ] && { echo "boom" >&2; exit 1; }
    printf '%s\n' "$*" > "$STUB/pr-create.args"
    echo "https://github.com/x/y/pull/7"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

ts() { printf '2026-09-%02dT10:00:00.000000Z\n' "$1"; }

# ---------- fixture ----------
# One product checkout with a bare origin holding `main` at the base commit,
# plus the two state files accept-work.sh and the board gate read. $ROOT is
# ahead of origin/main by the commit the terminal handoff names.
new_project() { # $1 = case name -> sets ROOT, STUB
  ROOT=$WORK/$1/proj
  STUB=$WORK/$1/stub
  export STUB
  mkdir -p "$STUB" "$WORK/$1"
  git init --quiet --bare "$WORK/$1/origin.git"
  git clone --quiet "$WORK/$1/origin.git" "$ROOT" 2>/dev/null
  git -C "$ROOT" config user.email t@t; git -C "$ROOT" config user.name t
  echo base > "$ROOT/f"
  # The runtime ignore block SwarmForge itself installs. Without it every ship
  # would block on `?? .swarmforge/` — which is the dirty gate working, but it
  # is not the shape a managed project is ever in.
  printf '/.swarmforge/\n/.worktrees/\n' > "$ROOT/.gitignore"
  printf '# %s\nShip the thing.\n' "$1" > "$ROOT/mission.md"
  git -C "$ROOT" add f .gitignore mission.md
  git -C "$ROOT" commit --quiet -m base
  git -C "$ROOT" branch -M main
  git -C "$ROOT" push --quiet -u origin main 2>/dev/null
  mkdir -p "$ROOT/.swarmforge/board" \
           "$ROOT/.swarmforge/handoffs/inbox/completed" \
           "$ROOT/.worktrees/cleaner/.swarmforge/handoffs/inbox/completed"
  printf 'coder\tmaster\t%s\tsess\tCoder\tcodex\tpush\n' "$ROOT" \
    > "$ROOT/.swarmforge/roles.tsv"
  printf 'cleaner\tcleaner\t%s/.worktrees/cleaner\tsess2\tCleaner\tcodex\tpush\n' "$ROOT" \
    >> "$ROOT/.swarmforge/roles.tsv"
}

add_commit() { # $1 = message -> echoes the new full sha
  echo "$1" >> "$ROOT/f"
  git -C "$ROOT" add f
  git -C "$ROOT" commit --quiet -m "$1"
  git -C "$ROOT" rev-parse HEAD
}

add_card() { # $1 = name, $2 = lane, $3 = card text (optional)
  printf '%s\t%s\t%s\t%s\t%s\t0\tutility\n' "$1" "$2" "$(ts 1)" "$(ts 1)" "$1" \
    >> "$ROOT/.swarmforge/board/tasks.tsv"
  # pack_board's write-body! puts the New Task text here, under the card's own
  # name. This is where the operator's `#N` lives.
  [ $# -lt 3 ] || printf '%s\n' "$3" > "$ROOT/.swarmforge/board/$1.txt"
}

# A terminal delivery record in the MASTER inbox, stamped non-forwarding so
# accept-work.sh reports it without depending on the recipient-set fallback
# (which upstream's typed routes changed the meaning of).
add_delivery() { # $1 = task, $2 = commit
  cat > "$ROOT/.swarmforge/handoffs/inbox/completed/$1.handoff" <<EOF
id: x
from: cleaner
to: coder
type: git_handoff
task: $1
commit: $2
completed_at: $(ts 2)
non-forwarding: true

body
EOF
}

# The default happy fixture: one done card, delivered, commit in HEAD, clean.
happy() { # $1 = case name
  new_project "$1"
  C=$(add_commit work)
  add_card issue-42-thing done
  add_delivery issue-42-thing "$C"
}

run_ship() { OUT=$("$SHIP" --root "$ROOT" --local "$@" 2>&1); RC=$?; }

echo "== ship-project.sh =="

# 1. Happy path: reports, creates the branch, pushes exactly once, and stops
#    at NEEDS_PR_BODY without opening a PR.
happy happy
run_ship
check "happy exit" 8 "$RC"
has "happy STATUS" "$OUT" 'STATUS=NEEDS_PR_BODY'
has "happy names the card" "$OUT" 'issue-42-thing'
has "happy names the branch" "$OUT" "feat/swarm-proj-$(date -u +%Y%m%d)"
has "happy reports mission" "$OUT" '# happy'
has "happy reports board" "$OUT" 'board: done 1 / waiting 0 / live 0'
has "happy reports tests skipped" "$OUT" 'skipped (no test entry point found)'
BR=$(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/remotes/origin/ | grep swarm || true)
has "happy pushed the branch to origin" "$BR" 'feat/swarm-proj-'
hasnt "happy opened no PR" "$(cat "$STUB/gh.log")" 'pr create'

# 2. Second pass with a body: exactly one `gh pr create`, and the body carries
#    the card list and a Closes line derived from the card NAME.
echo 'Some prose about the diff.' > "$WORK/body.md"
run_ship --body-file "$WORK/body.md"
check "body pass exit" 0 "$RC"
has "body pass STATUS" "$OUT" 'STATUS=PR_OPENED'
has "body pass url" "$OUT" 'https://github.com/x/y/pull/7'
check "exactly one pr create" 1 "$(grep -c 'pr create' "$STUB/gh.log")"
ARGS=$(cat "$STUB/pr-create.args")
has "body carries the prose" "$ARGS" 'Some prose about the diff.'
has "body carries Closes" "$ARGS" 'Closes #42'
has "body carries the card" "$ARGS" '- issue-42-thing'
has "body names the base" "$ARGS" "\-\-base main"

# 3. Re-running after the PR exists returns the same URL and creates nothing.
printf 'https://github.com/x/y/pull/7\n' > "$STUB/existing-pr"
run_ship --body-file "$WORK/body.md"
check "idempotent exit" 0 "$RC"
check "still exactly one pr create" 1 "$(grep -c 'pr create' "$STUB/gh.log")"
has "idempotent url" "$OUT" 'pull/7'

# 4. A card in a role lane blocks: work is in flight.
happy live
add_card other-card coder
run_ship
check "live card exit" 6 "$RC"
has "live card STATUS" "$OUT" 'STATUS=BLOCKED'
has "live card named" "$OUT" 'other-card (coder)'
hasnt "live card did not push" "$(cat "$STUB/gh.log")" 'pr'

# 5. A waiting card does NOT block — the plan being unfinished is not a reason
#    to refuse to publish the finished part.
happy waiting
add_card later-card waiting
run_ship
check "waiting card exit" 8 "$RC"
has "waiting counted" "$OUT" 'board: done 1 / waiting 1 / live 0'

# 6. Uncommitted changes block and are named.
happy dirty
echo scratch > "$ROOT/leftover.txt"
git -C "$ROOT" add leftover.txt
run_ship
check "dirty exit" 6 "$RC"
has "dirty names the file" "$OUT" 'leftover.txt'

# 7. A permanently failed delivery blocks. This repository's own handoffd
#    (fail! -> handoffs/failed/) is the path that fires here; the lieutenant
#    lineage's delivery_attention/ is checked too so the gate survives that
#    sync. Checking only the latter was a gate that could never fire.
happy failedroot
mkdir -p "$ROOT/.swarmforge/handoffs/failed"
touch "$ROOT/.swarmforge/handoffs/failed/50_stuck.handoff"
run_ship
check "failed at root exit" 6 "$RC"
has "failed at root named" "$OUT" '50_stuck.handoff'

happy failedworktree
mkdir -p "$ROOT/.worktrees/cleaner/.swarmforge/handoffs/failed"
touch "$ROOT/.worktrees/cleaner/.swarmforge/handoffs/failed/51_stuck.handoff"
run_ship
check "failed in worktree exit" 6 "$RC"
has "failed in worktree named" "$OUT" '51_stuck.handoff'

happy attention
mkdir -p "$ROOT/.swarmforge/delivery_attention"
touch "$ROOT/.swarmforge/delivery_attention/failed-delivery"
run_ship
check "attention exit" 6 "$RC"
has "attention named" "$OUT" 'failed-delivery'

# 7b. An EMPTY failed/ tree must not block. prepare-handoff-dirs! creates these
#     directories for every worktree the moment a swarm first starts, so a gate
#     that fired on their existence would refuse every managed project forever.
happy failedempty
mkdir -p "$ROOT/.swarmforge/handoffs/failed" "$ROOT/.worktrees/cleaner/.swarmforge/handoffs/failed"
run_ship
check "empty failed dirs do not block" 8 "$RC"
has "empty failed dirs report none" "$OUT" 'failed deliveries: none'

# 8. THE window this verb exists for: the board says done and the delivery
#    record exists, but the commit is not an ancestor of HEAD because the
#    master has not merged it yet. Shipping here would open a PR that silently
#    omits that card.
new_project notmerged
_=$(add_commit work)
add_card issue-9-pending done
add_delivery issue-9-pending 0000000000000000000000000000000000000000
run_ship
check "unmerged delivery exit" 6 "$RC"
has "unmerged delivery STATUS" "$OUT" 'STATUS=BLOCKED'
has "unmerged delivery named" "$OUT" 'issue-9-pending'
has "unmerged delivery explains" "$OUT" 'still merging'

# 9. Failing tests block, with no override flag anywhere.
happy redtests
run_ship --test-cmd false
check "red tests exit" 6 "$RC"
has "red tests STATUS" "$OUT" 'STATUS=BLOCKED'
has "red tests named" "$OUT" 'tests failed: false'
hasnt "red tests did not push" "$(cat "$STUB/gh.log")" 'pr'

# 10. Passing tests are reported as pass.
happy greentests
run_ship --test-cmd true
check "green tests exit" 8 "$RC"
has "green tests reported" "$OUT" 'tests: true -> pass'

# 11. Nothing unshipped -> NOTHING_TO_SHIP, no branch, no push.
new_project nothing
run_ship
check "nothing exit" 0 "$RC"
has "nothing STATUS" "$OUT" 'STATUS=NOTHING_TO_SHIP'
check "nothing created no branch" "" "$(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads/ | grep swarm || true)"

# 12. A role worktree is refused outright, before anything is read.
happy wt
OUT=$("$SHIP" --root "$ROOT/.worktrees/cleaner" --local 2>&1); RC=$?
check "worktree exit" 6 "$RC"
has "worktree STATUS" "$OUT" 'STATUS=BLOCKED'
has "worktree explains" "$OUT" '.worktrees'

# 13. A forge root is refused and points at projects/<name>.
mkdir -p "$WORK/forge/projects"; touch "$WORK/forge/swarm"
OUT=$("$SHIP" --root "$WORK/forge" --local 2>&1); RC=$?
check "forge root exit" 6 "$RC"
has "forge root explains" "$OUT" 'projects/<name>'

# 14. An empty body file refuses rather than opening a PR that says nothing.
happy emptybody
: > "$WORK/empty.md"
run_ship --body-file "$WORK/empty.md"
check "empty body exit" 5 "$RC"
has "empty body STATUS" "$OUT" 'STATUS=ERROR'
hasnt "empty body opened no PR" "$(cat "$STUB/gh.log")" 'pr create'

# 15. A missing body file refuses the same way.
happy nobody
run_ship --body-file "$WORK/does-not-exist.md"
check "missing body exit" 5 "$RC"
has "missing body names the path" "$OUT" 'does-not-exist.md'

# 16. --dry-run reports and stops before creating or pushing a branch.
happy dry
run_ship --dry-run
check "dry-run exit" 0 "$RC"
has "dry-run STATUS" "$OUT" 'STATUS=DRY_RUN'
check "dry-run created no branch" "" "$(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads/ | grep swarm || true)"

# 17. A card whose name is not issue-<N>-<slug> produces NO Closes line.
#     Lieutenant-cut cards are named by a human; guessing an issue number from
#     one would close the wrong issue.
new_project lieutenantcard
C=$(add_commit work)
add_card "harden the importer" done
add_delivery "harden the importer" "$C"
run_ship --body-file "$WORK/body.md"
check "lieutenant card exit" 0 "$RC"
ARGS=$(cat "$STUB/pr-create.args")
hasnt "lieutenant card emits no Closes" "$ARGS" 'Closes #'
has "lieutenant card still listed" "$ARGS" 'harden the importer'

# 18. --issue puts Closes lines in the body for a card nobody named after an
#     issue. This is the path that matters: most cards are cut in the Dashboard
#     by the operator or the lieutenant, so the card name carries no issue
#     number and the caller is the only one who knows it.
new_project issueflag
C=$(add_commit work)
add_card "harden the importer" done
add_delivery "harden the importer" "$C"
run_ship --issue 41 --issue '#42' --body-file "$WORK/body.md"
check "--issue exit" 0 "$RC"
ARGS=$(cat "$STUB/pr-create.args")
has "--issue emits Closes" "$ARGS" 'Closes #41'
has "--issue strips a leading hash" "$ARGS" 'Closes #42'

# 19. A base that moved under the swarm is reported, never blocking: the work
#     is already done, so refusing would strand it. run issue blocks on the
#     same condition because it is about to START work on that base.
happy behind
OTHER=$WORK/behind/other
# -b main is load-bearing: `git init --bare` leaves HEAD on `master`, so a
# plain clone of this origin lands on an unborn branch and the push below
# silently does nothing — which would make this case pass against code that
# never counts `behind` at all.
git clone --quiet -b main "$WORK/behind/origin.git" "$OTHER" 2>/dev/null
git -C "$OTHER" config user.email t@t; git -C "$OTHER" config user.name t
echo moved >> "$OTHER/f"; git -C "$OTHER" add f
git -C "$OTHER" commit --quiet -m 'someone merged a PR'
git -C "$OTHER" push --quiet origin main 2>/dev/null
run_ship --body-file "$WORK/body.md"
check "behind base still ships" 0 "$RC"
has "behind base counted" "$OUT" 'behind 1'
has "behind base warns" "$OUT" 'WARN=the swarm built on a base that has moved'
has "behind base noted in the PR body" "$(cat "$STUB/pr-create.args")" 'NOTE: this work was built on a base that has since moved'

# 20. The card text carries `#N`, which is how a Dashboard-cut card maps back
#     to its issue. Only the cards BEING SHIPPED are read: a #N sitting in some
#     other card's text must not end up in this PR.
new_project cardtext
C=$(add_commit work)
add_card "harden the importer" done "按 #77 做，另见 #78"
add_delivery "harden the importer" "$C"
add_card "not in this ship" waiting "这张卡提到 #999"
run_ship
check "card text pass 1 exit" 8 "$RC"
has "card text previewed before the PR" "$OUT" 'will close: 77 78'
hasnt "other cards contribute nothing" "$OUT" '999'
run_ship --body-file "$WORK/body.md"
ARGS=$(cat "$STUB/pr-create.args")
has "card text emits first Closes" "$ARGS" 'Closes #77'
has "card text emits second Closes" "$ARGS" 'Closes #78'
hasnt "no Closes from an unshipped card" "$ARGS" 'Closes #999'

# 21. --issue and the card text merge and deduplicate rather than fight.
new_project cardtextmerge
C=$(add_commit work)
add_card "harden the importer" done "按 #77 做"
add_delivery "harden the importer" "$C"
run_ship --issue 77 --issue 80 --body-file "$WORK/body.md"
check "merge exit" 0 "$RC"
ARGS=$(cat "$STUB/pr-create.args")
check "77 appears exactly once" 1 "$(printf '%s' "$ARGS" | grep -c 'Closes #77')"
has "--issue still adds its own" "$ARGS" 'Closes #80'

# 22. A card with no text at all is not an error.
new_project cardnotext
C=$(add_commit work)
add_card "silent card" done
add_delivery "silent card" "$C"
run_ship
check "no card text exit" 8 "$RC"
has "no card text reports none" "$OUT" 'will close: none'

# 23. Missing --root is a usage error, not a crash.
OUT=$("$SHIP" --local 2>&1); RC=$?
check "no --root exit" 2 "$RC"
has "no --root prints usage" "$OUT" 'Usage: ship-project.sh'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
rm -rf "$WORK"
