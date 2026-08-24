#!/usr/bin/env bash
# test-update-swarmforge-scripts.sh — end-to-end checks for
# update-swarmforge-scripts.sh against a stubbed tmux/ssh and real local
# filesystem operations for staging/digesting/validation/replacement (per
# issue #29's own Testing Decisions: stub only the unsafe/external boundary
# — ssh and tmux liveness — everything else runs for real). Run:
# bash scripts/test-update-swarmforge-scripts.sh. Exits non-zero on failure.
#
# SOURCE isolation: the script under test resolves its own source checkout
# from its on-disk location, but honors SF_SOURCE_ROOT as an override for
# exactly this reason — every case below points it at a small, disposable
# fixture git repo built from a real copy of THIS repo's own
# swarmforge/scripts/, never at this repo's own live git state (which the
# dirty-source case in particular must not depend on).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/update-swarmforge-scripts.sh
START=$HERE/start-swarm.sh
REPO_ROOT=$(cd "$HERE/../../../.." && pwd)
REAL_SCRIPTS=$REPO_ROOT/swarmforge/scripts
WORK=$(mktemp -d /tmp/sf-update-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

# ---------- stub tmux/ssh: byte-identical shape to test-start-swarm.sh's —
# a "live" flag file under $STUB gates list-sessions; ssh actually runs the
# shipped remote command string via `bash -c`, inheriting stdin (so a
# tar-piped invocation is exercised for real, not just logged). ----------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'tmux %s\n' "$*" >> "$STUB/calls.log"
[ -f "$STUB/live" ] || exit 1
shift 2  # drop -S <sock>
[ "$1" = list-sessions ] && exit 0
exit 1
EOF
chmod +x "$WORK/bin/tmux"

cat > "$WORK/bin/ssh" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
printf 'ssh %s\n' "$*" >> "$STUB/calls.log"
cmd=${*: -1}
# SSH_REMAP_FROM/TO (unset by default, a no-op for every other test): lets a
# single test simulate a genuinely SEPARATE remote filesystem by rewriting
# any occurrence of the local sentinel path in the shipped remote command
# string to a different local directory before executing it — instead of
# every "remote" call landing back on the exact same $ROOT path the local
# side uses, which would hide a script that wrongly touches a local path
# matching $ROOT directly (never through this ssh stub at all).
if [ -n "${SSH_REMAP_FROM:-}" ]; then
  cmd=${cmd//$SSH_REMAP_FROM/$SSH_REMAP_TO}
fi
bash -c "$cmd"
EOF
chmod +x "$WORK/bin/ssh"

export STUB=$WORK/stub
reset_stub() { rm -rf "$STUB"; mkdir -p "$STUB"; : > "$STUB/calls.log"; }

# ---------- source fixtures: disposable git repos, never this repo's own
# live checkout. GITC wraps every git call with a throwaway identity so
# this doesn't depend on (or pollute) any real git config. ----------
GITC() { git -c user.email=t@t.test -c user.name=test "$@"; }

build_fixture() { # $1 = dest dir; fresh git repo, swarmforge/scripts copied
                   # from THIS repo's real (known-good) tree, committed clean
  local dest=$1
  rm -rf "$dest"
  mkdir -p "$dest/swarmforge"
  cp -R "$REAL_SCRIPTS" "$dest/swarmforge/scripts"
  GITC -C "$dest" init -q
  GITC -C "$dest" add -A
  GITC -C "$dest" commit -q -m init >/dev/null
  GITC -C "$dest" remote add origin https://example.invalid/fixture.git
}

SRC_GOOD=$WORK/src-good
build_fixture "$SRC_GOOD"

SRC_MISSING_HELPER=$WORK/src-missing-helper
build_fixture "$SRC_MISSING_HELPER"
rm "$SRC_MISSING_HELPER/swarmforge/scripts/swarm_handoff.sh"
GITC -C "$SRC_MISSING_HELPER" commit -q -am "break: drop required helper" >/dev/null

SRC_MISSING_ADAPTER=$WORK/src-missing-adapter
build_fixture "$SRC_MISSING_ADAPTER"
rm "$SRC_MISSING_ADAPTER/swarmforge/scripts/terminal-adapters/iterm2.sh"
GITC -C "$SRC_MISSING_ADAPTER" commit -q -am "break: drop terminal adapter" >/dev/null

SRC_DIRTY=$WORK/src-dirty
build_fixture "$SRC_DIRTY"
printf '\n# dirty edit, never committed\n' >> "$SRC_DIRTY/swarmforge/scripts/swarm_handoff.sh"

compute_digest() { # $1 = dir; same trick test-start-swarm.sh uses
  ( LOCAL=1
    . "$HERE/lib-wake-talk.sh"
    scripts_digest "$1" )
}

# ---------- managed-project ($ROOT) fixture ----------
ROOT=$WORK/proj
reset_root() {
  rm -rf "$ROOT"
  mkdir -p "$ROOT/swarmforge/scripts" "$ROOT/swarmforge/roles" "$ROOT/.swarmforge"
  printf '#!/bin/sh\necho old\n' > "$ROOT/swarmforge/scripts/old-file.sh"
  chmod +x "$ROOT/swarmforge/scripts/old-file.sh"
  printf 'window coder codex coder\n' > "$ROOT/swarmforge/swarmforge.conf"
  printf 'coder role prompt\n' > "$ROOT/swarmforge/roles/coder.prompt"
  printf 'constitution text\n' > "$ROOT/swarmforge/constitution.prompt"
  printf '1\tcoder\tsess\tCoder\tcodex\n' > "$ROOT/.swarmforge/sessions.tsv"
}
write_good_launcher() {
  cat > "$ROOT/swarm" <<'EOF'
#!/bin/sh
MAIN_BRANCH="${SWARMFORGE_SCRIPTS_BRANCH:-main}"
ARCHIVE_URL="${SWARMFORGE_SCRIPTS_URL:-https://github.com/unclebob/swarm-forge/archive/refs/heads/${MAIN_BRANCH}.tar.gz}"
EOF
  # A real legacy launcher is executable — issue #29 review round 4 finding:
  # a fixture that starts non-executable can never catch a rewrite that
  # destroys the executable bit.
  chmod 755 "$ROOT/swarm"
}
write_legacy_launcher() { # a genuinely hand-edited launcher, the podsum case
  cat > "$ROOT/swarm" <<'EOF'
#!/bin/sh
ARCHIVE_URL="https://example.com/hand-edited/never-matches.tar.gz"
EOF
  chmod 755 "$ROOT/swarm"
}

# Same layout as reset_root/write_good_launcher, parametrized by path — used
# to stand up a "managed project" fixture at an arbitrary directory, for the
# test below that needs a project fixture living somewhere OTHER than $ROOT
# (simulating a genuinely separate remote filesystem, per SSH_REMAP above).
build_project_fixture() { # $1 = root dir
  local r=$1
  rm -rf "$r"
  mkdir -p "$r/swarmforge/scripts" "$r/swarmforge/roles" "$r/.swarmforge"
  printf '#!/bin/sh\necho old\n' > "$r/swarmforge/scripts/old-file.sh"
  chmod +x "$r/swarmforge/scripts/old-file.sh"
  printf 'window coder codex coder\n' > "$r/swarmforge/swarmforge.conf"
  printf 'coder role prompt\n' > "$r/swarmforge/roles/coder.prompt"
  printf 'constitution text\n' > "$r/swarmforge/constitution.prompt"
  printf '1\tcoder\tsess\tCoder\tcodex\n' > "$r/.swarmforge/sessions.tsv"
  cat > "$r/swarm" <<'EOF'
#!/bin/sh
MAIN_BRANCH="${SWARMFORGE_SCRIPTS_BRANCH:-main}"
ARCHIVE_URL="${SWARMFORGE_SCRIPTS_URL:-https://github.com/unclebob/swarm-forge/archive/refs/heads/${MAIN_BRANCH}.tar.gz}"
EOF
  chmod 755 "$r/swarm"
}

# Sorted "relpath sha256" listing for every file under $ROOT — used for
# both "zero filesystem changes" (whole-tree) and "these specific files are
# byte-for-byte preserved" (scoped to a path list) assertions.
snapshot() { # $@ = paths (relative to $ROOT) to include; default: everything
  local paths=("$@")
  if [ ${#paths[@]} -eq 0 ]; then
    find "$ROOT" -type f 2>/dev/null | sort
  else
    local p
    for p in "${paths[@]}"; do
      [ -f "$ROOT/$p" ] && printf '%s\n' "$ROOT/$p"
    done | sort
  fi | while IFS= read -r f; do
    printf '%s %s\n' "${f#"$ROOT"/}" "$(shasum -a 256 "$f" | awk '{print $1}')"
  done
}

SRC=$SRC_GOOD
OUTFILE=$WORK/out.txt
run() { # run [args...]  (SRC/STUB set by caller env)
  PATH="$WORK/bin:$PATH" STUB=$STUB SF_SOURCE_ROOT=$SRC TARGET=testhost KEY=/dev/null \
    bash "$SCRIPT" "$@" > "$OUTFILE" 2>&1
  RC=$?
  OUT=$(cat "$OUTFILE")
}
status_line() { printf '%s\n' "$OUT" | head -1; }

echo "== RED/GREEN suite for update-swarmforge-scripts.sh =="

if [ ! -f "$SCRIPT" ]; then
  echo "script missing — RED confirmed, all cases fail"; exit 1
fi

# 1. missing --root -> 2 USAGE
reset_stub; reset_root
run --local
check "missing --root exit" 2 "$RC"
check "missing --root status" "STATUS=USAGE" "$(status_line)"

# 2. swarm running (live socket) -> 6 UNSAFE, no override even with
#    --force, zero filesystem changes at $ROOT, lock never created
reset_stub; reset_root; write_good_launcher
printf '%s\n' "$STUB/fake.sock" > "$ROOT/.swarmforge/tmux-socket"
touch "$STUB/live"
BEFORE=$(snapshot)
run --local --root "$ROOT"
check "running exit" 6 "$RC"
check "running status" "STATUS=UNSAFE" "$(status_line)"
AFTER=$(snapshot)
[ "$BEFORE" = "$AFTER" ] && ok "running: zero filesystem changes" \
  || bad "running: zero filesystem changes" "tree differs"
[ ! -d "$ROOT/.swarmforge/update-lock" ] && ok "running: lock never created" \
  || bad "running: lock never created" "lock dir exists"
run --local --root "$ROOT" --force
check "running with --force still refused" 6 "$RC"

# 3. lock contention (pre-created holder 'start') -> 6 UNSAFE naming the
#    holder; --force steals it and the update proceeds to success
reset_stub; reset_root; write_good_launcher
mkdir -p "$ROOT/.swarmforge/update-lock"
printf 'start\n' > "$ROOT/.swarmforge/update-lock/holder"
run --local --root "$ROOT"
check "lock contention exit" 6 "$RC"
printf '%s\n' "$OUT" | grep -q "'start'" \
  && ok "lock contention names holder" || bad "lock contention names holder" "$OUT"
[ -f "$ROOT/.swarmforge/update-lock/holder" ] && ok "lock left untouched without --force" \
  || bad "lock left untouched without --force" "lock dir gone"
run --local --root "$ROOT" --force
check "lock contention with --force succeeds" 0 "$RC"
check "lock contention with --force status" "STATUS=UPDATED" "$(status_line)"

# 4. dirty source checkout -> 5 ERROR, no staging, no swap attempted,
#    isolated via SF_SOURCE_ROOT pointed at the disposable dirty fixture
reset_stub; reset_root; write_good_launcher
SRC=$SRC_DIRTY
run --local --root "$ROOT"
check "dirty source exit" 5 "$RC"
printf '%s\n' "$OUT" | grep -qi "uncommitted" \
  && ok "dirty source names uncommitted changes" || bad "dirty source names uncommitted changes" "$OUT"
[ -f "$ROOT/swarmforge/scripts/old-file.sh" ] && ok "dirty source: old tree untouched" \
  || bad "dirty source: old tree untouched" "old-file.sh missing"
[ ! -f "$ROOT/.swarmforge/scripts-manifest" ] && ok "dirty source: no manifest written" \
  || bad "dirty source: no manifest written" "manifest exists"
SRC=$SRC_GOOD

# 5. missing required helper in the staged tree -> 5 ERROR naming the
#    file, $ROOT untouched
reset_stub; reset_root; write_good_launcher
SRC=$SRC_MISSING_HELPER
run --local --root "$ROOT"
check "missing helper exit" 5 "$RC"
printf '%s\n' "$OUT" | grep -q "swarm_handoff.sh" \
  && ok "missing helper names the file" || bad "missing helper names the file" "$OUT"
[ -f "$ROOT/swarmforge/scripts/old-file.sh" ] && ok "missing helper: ROOT untouched" \
  || bad "missing helper: ROOT untouched" "old-file.sh missing"
SRC=$SRC_GOOD

# 6. missing terminal adapter -> 5 ERROR naming the file, $ROOT untouched
reset_stub; reset_root; write_good_launcher
SRC=$SRC_MISSING_ADAPTER
run --local --root "$ROOT"
check "missing adapter exit" 5 "$RC"
printf '%s\n' "$OUT" | grep -q "iterm2.sh" \
  && ok "missing adapter names the file" || bad "missing adapter names the file" "$OUT"
[ -f "$ROOT/swarmforge/scripts/old-file.sh" ] && ok "missing adapter: ROOT untouched" \
  || bad "missing adapter: ROOT untouched" "old-file.sh missing"
SRC=$SRC_GOOD

# 6b. `bb` unavailable on PATH -> 5 ERROR, required-helper validation must
#     refuse rather than silently skip every check (issue #29 review round 4
#     finding: a process-substitution read of a failing/missing `bb` reads
#     zero lines and previously reported STATUS=UPDATED as if nothing were
#     wrong). PATH is narrowed to exclude bb's real directory while keeping
#     a real `git` (via a symlink) and the plain POSIX toolset the script
#     itself depends on.
mkdir -p "$WORK/bin-nobb"
ln -sf "$(command -v git)" "$WORK/bin-nobb/git"
reset_stub; reset_root; write_good_launcher
PATH="$WORK/bin:$WORK/bin-nobb:/usr/bin:/bin" STUB=$STUB SF_SOURCE_ROOT=$SRC_GOOD \
  TARGET=testhost KEY=/dev/null bash "$SCRIPT" --local --root "$ROOT" > "$OUTFILE" 2>&1
RC=$?; OUT=$(cat "$OUTFILE")
check "bb missing exit" 5 "$RC"
check "bb missing status" "STATUS=ERROR" "$(status_line)"
printf '%s\n' "$OUT" | grep -qi "bb" \
  && ok "bb missing: message mentions bb" || bad "bb missing: message mentions bb" "$OUT"
[ -f "$ROOT/swarmforge/scripts/old-file.sh" ] && ok "bb missing: ROOT untouched" \
  || bad "bb missing: ROOT untouched" "old-file.sh missing"
[ ! -f "$ROOT/.swarmforge/scripts-manifest" ] && ok "bb missing: no manifest written" \
  || bad "bb missing: no manifest written" "manifest exists"

# 7. successful update (local): STATUS=UPDATED/0, manifest correct, old
#    tree gone, new tree present, legacy launcher rewritten + verified
reset_stub; reset_root; write_good_launcher
PRESERVE_BEFORE=$(snapshot swarmforge/swarmforge.conf swarmforge/roles/coder.prompt \
  swarmforge/constitution.prompt .swarmforge/sessions.tsv)
run --local --root "$ROOT"
check "success exit" 0 "$RC"
check "success status" "STATUS=UPDATED" "$(status_line)"
EXPECT_DIGEST=$(compute_digest "$SRC_GOOD/swarmforge/scripts")
EXPECT_COMMIT=$(GITC -C "$SRC_GOOD" rev-parse HEAD)
GOT_DIGEST=$(grep '^DIGEST=' "$ROOT/.swarmforge/scripts-manifest" | cut -d= -f2)
GOT_COMMIT=$(grep '^SOURCE_COMMIT=' "$ROOT/.swarmforge/scripts-manifest" | cut -d= -f2)
GOT_REPO=$(grep '^SOURCE_REPO=' "$ROOT/.swarmforge/scripts-manifest" | cut -d= -f2)
check "manifest DIGEST matches staged tree" "$EXPECT_DIGEST" "$GOT_DIGEST"
check "manifest SOURCE_COMMIT matches fixture HEAD" "$EXPECT_COMMIT" "$GOT_COMMIT"
check "manifest SOURCE_REPO" "https://example.invalid/fixture.git" "$GOT_REPO"
[ ! -f "$ROOT/swarmforge/scripts/old-file.sh" ] && ok "old scripts tree gone" \
  || bad "old scripts tree gone" "old-file.sh still present"
[ -x "$ROOT/swarmforge/scripts/swarmforge.bb" ] && ok "new scripts tree present" \
  || bad "new scripts tree present" "swarmforge.bb missing"
grep -q '^ARCHIVE_URL=.*arlishansenn/swarm-forge' "$ROOT/swarm" \
  && ok "legacy launcher rewritten and verified" || bad "legacy launcher rewritten and verified" "$(cat "$ROOT/swarm")"
[ -x "$ROOT/swarm" ] && ok "legacy launcher still executable after rewrite" \
  || bad "legacy launcher still executable after rewrite" "$(stat -f '%Lp' "$ROOT/swarm" 2>/dev/null || stat -c '%a' "$ROOT/swarm")"
compgen -G "$ROOT/swarmforge/scripts.old.*" > /dev/null \
  && bad "backup dir removed on success" "backup still present" \
  || ok "backup dir removed on success"
compgen -G "$ROOT/.swarmforge/scripts-manifest.old.*" > /dev/null \
  && bad "manifest backup removed on success" "manifest backup still present" \
  || ok "manifest backup removed on success"
PRESERVE_AFTER=$(snapshot swarmforge/swarmforge.conf swarmforge/roles/coder.prompt \
  swarmforge/constitution.prompt .swarmforge/sessions.tsv)
[ "$PRESERVE_BEFORE" = "$PRESERVE_AFTER" ] && ok "preservation: conf/roles/constitution/sessions.tsv byte-identical" \
  || bad "preservation: conf/roles/constitution/sessions.tsv byte-identical" "differs"

# 7b. cross-verb integration (required, issue #29): update succeeds
#     locally, then start-swarm.sh --local with no --force must proceed to
#     launch, NOT report DRIFT — proving the digest this script wrote and
#     start-swarm.sh's own read of it genuinely agree.
cat > "$WORK/bin/fake-launcher.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$STUB/fake.sock" > .swarmforge/tmux-socket
touch "$STUB/live"
EOF
chmod +x "$WORK/bin/fake-launcher.sh"
rm -f "$STUB/live" "$ROOT/.swarmforge/tmux-socket"
PATH="$WORK/bin:$PATH" STUB=$STUB SWARM_LAUNCHER="$WORK/bin/fake-launcher.sh" \
  SF_START_READY_TRIES=20 SF_START_READY_INTERVAL=0.2 \
  bash "$START" --local --root "$ROOT" --terminal none > "$WORK/start-out.txt" 2>&1
START_RC=$?
START_OUT=$(cat "$WORK/start-out.txt")
check "cross-verb: start-swarm exit" 0 "$START_RC"
check "cross-verb: start-swarm status is STARTED, not DRIFT" "STATUS=STARTED" "$(printf '%s\n' "$START_OUT" | head -1)"

# 8. legacy launcher whose ARCHIVE_URL doesn't match the expected pattern
#    -> 5 ERROR naming $ROOT/swarm, scripts swap + manifest write rolled
#    back (old tree restored, manifest absent since none pre-existed), and
#    the launcher itself stays executable (issue #29 review round 4 finding
#    — the mode-clobbering `mv` from mktemp happens on this path too).
reset_stub; reset_root; write_legacy_launcher
run --local --root "$ROOT"
check "launcher mismatch exit" 5 "$RC"
printf '%s\n' "$OUT" | grep -qF "$ROOT/swarm" \
  && ok "launcher mismatch names \$ROOT/swarm" || bad "launcher mismatch names \$ROOT/swarm" "$OUT"
[ -f "$ROOT/swarmforge/scripts/old-file.sh" ] && ok "launcher mismatch: old tree restored" \
  || bad "launcher mismatch: old tree restored" "old-file.sh missing"
[ ! -x "$ROOT/swarmforge/scripts/swarmforge.bb" ] && ok "launcher mismatch: new tree not left behind" \
  || bad "launcher mismatch: new tree not left behind" "swarmforge.bb present"
[ ! -f "$ROOT/.swarmforge/scripts-manifest" ] && ok "launcher mismatch: manifest absent" \
  || bad "launcher mismatch: manifest absent" "manifest present"
compgen -G "$ROOT/swarmforge/scripts.old.*" > /dev/null \
  && bad "launcher mismatch: backup cleaned up" "backup dir left behind" \
  || ok "launcher mismatch: backup cleaned up"
compgen -G "$ROOT/.swarmforge/scripts-manifest.old.*" > /dev/null \
  && bad "launcher mismatch: manifest backup cleaned up" "manifest backup left behind" \
  || ok "launcher mismatch: manifest backup cleaned up"
[ -x "$ROOT/swarm" ] && ok "launcher mismatch: launcher still executable" \
  || bad "launcher mismatch: launcher still executable" "$(stat -f '%Lp' "$ROOT/swarm" 2>/dev/null || stat -c '%a' "$ROOT/swarm")"

# 8b. same launcher-mismatch rollback, but with a real PRE-EXISTING manifest
#     (as a project that had already been updated once would have) — the
#     rollback must restore that old manifest byte-for-byte, not just leave
#     it deleted (issue #29 review round 4 Important finding: a missing
#     manifest over an intact old scripts tree reports DRIFT on the next
#     `start swarm` even though the tree itself is fine).
reset_stub; reset_root; write_legacy_launcher
printf 'SOURCE_COMMIT=preexisting\nSOURCE_REPO=preexisting\nDIGEST=preexisting\n' \
  > "$ROOT/.swarmforge/scripts-manifest"
PRE_MANIFEST=$(cat "$ROOT/.swarmforge/scripts-manifest")
run --local --root "$ROOT"
check "launcher mismatch w/ prior manifest: exit" 5 "$RC"
[ -f "$ROOT/.swarmforge/scripts-manifest" ] && ok "launcher mismatch w/ prior manifest: manifest present after rollback" \
  || bad "launcher mismatch w/ prior manifest: manifest present after rollback" "manifest missing"
check "launcher mismatch w/ prior manifest: byte-identical to before" \
  "$PRE_MANIFEST" "$(cat "$ROOT/.swarmforge/scripts-manifest" 2>/dev/null)"
compgen -G "$ROOT/.swarmforge/scripts-manifest.old.*" > /dev/null \
  && bad "launcher mismatch w/ prior manifest: backup cleaned up" "manifest backup left behind" \
  || ok "launcher mismatch w/ prior manifest: backup cleaned up"

# 9. manifest write failure -> 5 ERROR, old scripts tree restored. Forced
#    deterministically by pre-creating a READ-ONLY scripts-manifest file
#    (parent .swarmforge/ dir stays writable so the lock can still be
#    acquired) rather than making the whole directory unwritable, which
#    would also break lock acquisition before reaching the manifest step.
reset_stub; reset_root; write_good_launcher
printf 'SOURCE_COMMIT=old\nSOURCE_REPO=old\nDIGEST=old\n' > "$ROOT/.swarmforge/scripts-manifest"
chmod 444 "$ROOT/.swarmforge/scripts-manifest"
run --local --root "$ROOT"
check "manifest write failure exit" 5 "$RC"
printf '%s\n' "$OUT" | grep -qi "manifest" \
  && ok "manifest write failure names manifest" || bad "manifest write failure names manifest" "$OUT"
[ -f "$ROOT/swarmforge/scripts/old-file.sh" ] && ok "manifest write failure: old tree restored" \
  || bad "manifest write failure: old tree restored" "old-file.sh missing"
chmod 644 "$ROOT/.swarmforge/scripts-manifest"
check "manifest write failure: manifest content unchanged" "SOURCE_COMMIT=old" \
  "$(head -1 "$ROOT/.swarmforge/scripts-manifest")"

# 10. $ROOT/swarm doesn't exist at all -> launcher-rewrite step skipped,
#     not an error, update still succeeds
reset_stub; reset_root
[ ! -e "$ROOT/swarm" ] || rm -f "$ROOT/swarm"
run --local --root "$ROOT"
check "no launcher: update still succeeds" 0 "$RC"
check "no launcher: status" "STATUS=UPDATED" "$(status_line)"
[ ! -e "$ROOT/swarm" ] && ok "no launcher: still doesn't exist, not an error" \
  || bad "no launcher: still doesn't exist" "\$ROOT/swarm was created"

# 11. remote mode: a full successful update over the stub-ssh/tar-pipe
#     path, exercised for real (not skipped/TODO'd) — the ssh stub runs
#     the shipped remote command strings via bash -c, so this proves the
#     tar-over-ssh transfer + single-round-trip swap script actually work.
reset_stub; reset_root; write_good_launcher
run --root "$ROOT" --target testhost --key /dev/null
check "remote success exit" 0 "$RC"
check "remote success status" "STATUS=UPDATED" "$(status_line)"
GOT_DIGEST_REMOTE=$(grep '^DIGEST=' "$ROOT/.swarmforge/scripts-manifest" | cut -d= -f2)
check "remote manifest DIGEST matches staged tree" "$EXPECT_DIGEST" "$GOT_DIGEST_REMOTE"
[ ! -f "$ROOT/swarmforge/scripts/old-file.sh" ] && ok "remote: old scripts tree gone" \
  || bad "remote: old scripts tree gone" "old-file.sh still present"
[ -x "$ROOT/swarmforge/scripts/swarmforge.bb" ] && ok "remote: new scripts tree present" \
  || bad "remote: new scripts tree present" "swarmforge.bb missing"
grep -q '^ARCHIVE_URL=.*arlishansenn/swarm-forge' "$ROOT/swarm" \
  && ok "remote: legacy launcher rewritten" || bad "remote: legacy launcher rewritten" "$(cat "$ROOT/swarm")"
TAR_CALLS=$(grep -c '^ssh .*tar -C' "$STUB/calls.log" || true)
[ "${TAR_CALLS:-0}" -ge 1 ] && ok "remote: tar-over-ssh transfer actually invoked" \
  || bad "remote: tar-over-ssh transfer actually invoked" "$(cat "$STUB/calls.log")"

# 12. default source resolution (no SF_SOURCE_ROOT set): every case above
#     isolates via SF_SOURCE_ROOT, so the actual production fallback path —
#     SOURCE_ROOT=${SF_SOURCE_ROOT:-$(cd "$HERE/../../../.." && pwd)}, the
#     four-`..` arithmetic from the script's own on-disk location — is
#     otherwise never exercised. This real worktree's own swarmforge/scripts
#     IS what that arithmetic resolves to, and should be clean right now, so
#     run against it directly instead of faking anything. Skip (not fail) if
#     it's unexpectedly dirty at test time — that would prove nothing about
#     the resolution arithmetic itself and isn't this suite's concern.
reset_stub; reset_root; write_good_launcher
if [ -n "$(git -C "$REPO_ROOT" status --porcelain -- swarmforge/scripts)" ]; then
  echo "  SKIP default source resolution -- $REPO_ROOT/swarmforge/scripts is dirty at test time"
else
  PATH="$WORK/bin:$PATH" STUB=$STUB TARGET=testhost KEY=/dev/null \
    bash "$SCRIPT" --local --root "$ROOT" > "$OUTFILE" 2>&1
  RC=$?
  OUT=$(cat "$OUTFILE")
  check "default source resolution exit" 0 "$RC"
  check "default source resolution status" "STATUS=UPDATED" "$(status_line)"
fi

# 13. staging location (issue #29 review round 2 finding 1, refined by
#     review round 3): the path that actually gets `mv`'d into the final
#     destination must live under that destination's own $ROOT/swarmforge/,
#     never mktemp -d's default $TMPDIR — which is commonly a separate
#     filesystem/mount, making the swap `mv` fall back to a non-atomic
#     copy+delete. For LOCAL=1 that's $STAGED itself (mv'd straight into
#     $ROOT/swarmforge/scripts locally); for remote mode it's REMOTE_STAGE
#     on $TARGET (mv'd there by the remote swap script) — the LOCAL-side
#     $STAGED in remote mode is only ever read from (cp -R/tar), never
#     mv'd, so it belongs in system temp instead (see test 14 for why it
#     must NOT be under a local path matching $ROOT). Confirmed by tracing
#     the script's own variable assignments via `bash -x`, not by
#     inference from side effects.
# 13a. local
reset_stub; reset_root; write_good_launcher
PATH="$WORK/bin:$PATH" STUB=$STUB SF_SOURCE_ROOT=$SRC_GOOD TARGET=testhost KEY=/dev/null \
  bash -x "$SCRIPT" --local --root "$ROOT" > "$WORK/trace-out.txt" 2> "$WORK/trace-err.txt"
TRACE_RC=$?
check "staging location (local): run still succeeds under trace" 0 "$TRACE_RC"
grep -qF "STAGED=$ROOT/swarmforge/.stage." "$WORK/trace-err.txt" \
  && ok "staging location (local): STAGED under \$ROOT/swarmforge/, not system temp dir" \
  || bad "staging location (local): STAGED under \$ROOT/swarmforge/, not system temp dir" \
       "$(grep 'STAGED=' "$WORK/trace-err.txt" | head -3)"

# 13b. remote
reset_stub; reset_root; write_good_launcher
PATH="$WORK/bin:$PATH" STUB=$STUB SF_SOURCE_ROOT=$SRC_GOOD TARGET=testhost KEY=/dev/null \
  bash -x "$SCRIPT" --root "$ROOT" --target testhost --key /dev/null \
  > "$WORK/trace-out.txt" 2> "$WORK/trace-err.txt"
TRACE_RC=$?
check "staging location (remote): run still succeeds under trace" 0 "$TRACE_RC"
grep -qF "REMOTE_STAGE=$ROOT/swarmforge/.stage-remote." "$WORK/trace-err.txt" \
  && ok "staging location (remote): REMOTE_STAGE under \$ROOT/swarmforge/, not /tmp" \
  || bad "staging location (remote): REMOTE_STAGE under \$ROOT/swarmforge/, not /tmp" \
       "$(grep 'REMOTE_STAGE=' "$WORK/trace-err.txt" | head -3)"
grep -qF "STAGED=$ROOT/swarmforge/.stage." "$WORK/trace-err.txt" \
  && bad "staging location (remote): LOCAL-side STAGED must NOT be under \$ROOT/swarmforge/" \
       "$(grep '^+ STAGED=' "$WORK/trace-err.txt" | head -3)" \
  || ok "staging location (remote): LOCAL-side STAGED not under \$ROOT/swarmforge/ (system temp instead)"

# 14. remote mode must never touch a literal $ROOT-prefixed path on the
#     OPERATOR's own local machine (issue #29 review round 3 regression:
#     the round-2 same-filesystem fix made the shared staging step —
#     $STAGED="$ROOT/swarmforge/.stage.$$", mkdir -p "$ROOT/swarmforge",
#     cp -R into it — run unconditionally before the LOCAL/remote branch
#     split, so a --target run created and left behind $ROOT/swarmforge/ on
#     the operator's own machine even though $ROOT is a path on $TARGET).
#     A fixture sharing one $ROOT string between "local" and "simulated
#     remote" (test 11 above) can never catch this — every ssh call loops
#     back to the SAME local $ROOT either way. Uses SSH_REMAP (see the ssh
#     stub above) to point every ssh-routed call at a genuinely different
#     local directory, so this test can tell "touched via ssh, i.e. really
#     on the target host" apart from "touched directly by this script's own
#     process, i.e. actually on the operator's machine" — and asserts the
#     project-root path this run was invoked with is never created directly.
ROOT_NOTLOCAL=$WORK/root-not-on-this-machine
REMOTE_ONLY=$WORK/remote-only-proj
rm -rf "$ROOT_NOTLOCAL"
build_project_fixture "$REMOTE_ONLY"
reset_stub
PATH="$WORK/bin:$PATH" STUB=$STUB SF_SOURCE_ROOT=$SRC_GOOD TARGET=testhost KEY=/dev/null \
  SSH_REMAP_FROM=$ROOT_NOTLOCAL SSH_REMAP_TO=$REMOTE_ONLY \
  bash "$SCRIPT" --root "$ROOT_NOTLOCAL" --target testhost --key /dev/null \
  > "$OUTFILE" 2>&1
RC=$?; OUT=$(cat "$OUTFILE")
check "remote-only \$ROOT: update still succeeds" 0 "$RC"
check "remote-only \$ROOT: status" "STATUS=UPDATED" "$(status_line)"
[ ! -e "$ROOT_NOTLOCAL" ] && ok "remote-only \$ROOT: no \$ROOT-prefixed path created on the operator's own machine" \
  || bad "remote-only \$ROOT: no \$ROOT-prefixed path created on the operator's own machine" \
       "$(find "$ROOT_NOTLOCAL" 2>&1)"
[ -x "$REMOTE_ONLY/swarmforge/scripts/swarmforge.bb" ] && ok "remote-only \$ROOT: simulated remote host actually updated" \
  || bad "remote-only \$ROOT: simulated remote host actually updated" "swarmforge.bb missing under $REMOTE_ONLY"
[ ! -f "$REMOTE_ONLY/swarmforge/scripts/old-file.sh" ] && ok "remote-only \$ROOT: old tree gone on simulated remote host" \
  || bad "remote-only \$ROOT: old tree gone on simulated remote host" "old-file.sh still present"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
