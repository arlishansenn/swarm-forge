#!/usr/bin/env bash
# test-swarm-launcher.sh — checks for this Pack's ./swarm first-run bootstrap
# (issue #35). Run: bash test-swarm-launcher.sh. Exits non-zero on any failure.
#
# Drives the real launcher against a stubbed curl serving a fixture archive, so
# nothing here reaches the network, and asserts on real filesystem state. The
# handoff target (swarmforge.sh) is part of the fixture and only records that it
# was reached — a bootstrap that fails must never get that far.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LAUNCHER=$HERE/swarm
WORK=$(mktemp -d /tmp/sf-launcher-test.XXXXXX)
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
trap 'rm -rf "$WORK"' EXIT

# ---------- fixture archive: a miniature swarm-forge tree ----------
SRC=$WORK/src/swarm-forge-main
mkdir -p "$SRC/swarmforge/scripts/terminal-adapters" \
         "$SRC/swarmforge/constitution/articles"
cat > "$SRC/swarmforge/scripts/swarmforge.sh" <<'EOF'
#!/usr/bin/env bash
printf 'handed-off %s\n' "$*" >> "${LAUNCH_MARKER:?}"
EOF
chmod +x "$SRC/swarmforge/scripts/swarmforge.sh"
printf 'helper\n' > "$SRC/swarmforge/scripts/lib.sh"
printf '#!/bin/sh\n' > "$SRC/swarmforge/scripts/terminal-adapters/none.sh"
chmod +x "$SRC/swarmforge/scripts/terminal-adapters/none.sh"
printf 'article body\n' > "$SRC/swarmforge/constitution/articles/engineering.prompt"
tar -czf "$WORK/pack.tgz" -C "$WORK/src" swarm-forge-main

# ---------- stub curl: -o is unused by the launcher (it pipes), so this just
# writes the fixture to stdout, or fails / stalls on demand ----------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${CURL_FAILS:-}" ] && exit 22
if [ -n "${CURL_TRUNCATED:-}" ]; then
  # a tarball that unpacks to a tree with no swarmforge/scripts at all
  printf 'not a tarball' | gzip
  exit 0
fi
cat "$FIXTURE"
EOF
chmod +x "$WORK/bin/curl"
export PATH=$WORK/bin:$PATH FIXTURE=$WORK/pack.tgz

# digest_of <dir> — the reference implementation, copied from the operator
# skill's scripts_digest. The launcher has its own copy by necessity (it ships
# in a Pack branch and cannot source the skill); this test is what proves the
# two agree, because a disagreement shows up as DRIFT on the first start swarm.
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@" | awk '{print $1}'
  else shasum -a 256 "$@" | awk '{print $1}'; fi
}
digest_of() {
  local dir=${1%/} f rel x
  { find "$dir" -type f 2>/dev/null || true; } | LC_ALL=C sort | while IFS= read -r f; do
    rel=${f#"$dir"/}
    [ -x "$f" ] && x=x || x=-
    printf '%s %s %s\n' "$rel" "$x" "$(sha256_hex "$f")"
  done | sha256_hex || true
}

fresh_project() { PROJ=$WORK/proj; rm -rf "$PROJ"; mkdir -p "$PROJ"; cp "$LAUNCHER" "$PROJ/swarm"; }
run_launcher() {
  OUT=$(cd "$PROJ" && LAUNCH_MARKER=$WORK/marker env "$@" ./swarm --flag 2>&1)
  RC=$?
}

echo "swarm launcher bootstrap"

# 1. first run: bootstraps, installs everything, writes a manifest, hands off
fresh_project; : > "$WORK/marker"
run_launcher
check "fresh bootstrap exit" 0 "$RC"
[ -x "$PROJ/swarmforge/scripts/swarmforge.sh" ] \
  && ok "fresh: helpers installed and executable" \
  || bad "fresh: helpers installed and executable" "$(ls -l "$PROJ/swarmforge/scripts" 2>&1)"
[ -x "$PROJ/swarmforge/scripts/terminal-adapters/none.sh" ] \
  && ok "fresh: terminal adapters installed" || bad "fresh: terminal adapters installed" "missing"
[ -f "$PROJ/swarmforge/scripts/shared-articles/engineering.prompt" ] \
  && ok "fresh: shared constitution articles installed" \
  || bad "fresh: shared constitution articles installed" "missing"
grep -q '^handed-off --flag$' "$WORK/marker" \
  && ok "fresh: handed off to swarmforge.sh with argv intact" \
  || bad "fresh: handed off to swarmforge.sh" "$(cat "$WORK/marker")"

# 2. the manifest digest must equal what start swarm recomputes. If these two
#    implementations ever drift, every first start after a bootstrap reports
#    DRIFT — this is the case that catches it at the source.
EXPECTED=$(digest_of "$PROJ/swarmforge/scripts")
WRITTEN=$(grep '^DIGEST=' "$PROJ/.swarmforge/scripts-manifest" | sed 's/^DIGEST=//')
check "manifest digest matches the installed tree" "$EXPECTED" "$WRITTEN"
grep -q '^SOURCE_REPO=.*arlishansenn/swarm-forge' "$PROJ/.swarmforge/scripts-manifest" \
  && ok "manifest records the fork as the source" \
  || bad "manifest records the fork as the source" "$(cat "$PROJ/.swarmforge/scripts-manifest")"

# 3. second run reuses the snapshot: no download, straight to handoff
: > "$WORK/marker"
CURL_FAILS=1 run_launcher CURL_FAILS=1
check "second run exit (no download attempted)" 0 "$RC"
grep -q '^handed-off' "$WORK/marker" \
  && ok "second run: reuses the snapshot and hands off" \
  || bad "second run: reuses the snapshot" "$OUT"

# 4. download failure leaves NOTHING behind and never hands off. This is the
#    invariant upstream's rm -rf + cp -R could not provide.
fresh_project; : > "$WORK/marker"
run_launcher CURL_FAILS=1
[ "$RC" != 0 ] && ok "download failure exits non-zero" \
  || bad "download failure exits non-zero" "got 0"
[ ! -d "$PROJ/swarmforge/scripts" ] \
  && ok "download failure: no half-installed snapshot" \
  || bad "download failure: no half-installed snapshot" "$(ls -R "$PROJ/swarmforge" 2>&1)"
[ ! -f "$PROJ/.swarmforge/scripts-manifest" ] \
  && ok "download failure: no manifest" || bad "download failure: no manifest" "manifest exists"
[ ! -s "$WORK/marker" ] \
  && ok "download failure: roles never started" || bad "download failure: roles never started" "$(cat "$WORK/marker")"

# 5. an archive that unpacks without swarmforge/scripts is refused outright
#    rather than installing an empty tree that the next run would treat as
#    present.
fresh_project; : > "$WORK/marker"
run_launcher CURL_TRUNCATED=1
[ "$RC" != 0 ] && ok "bad archive exits non-zero" || bad "bad archive exits non-zero" "got 0"
[ ! -d "$PROJ/swarmforge/scripts" ] \
  && ok "bad archive: nothing installed" || bad "bad archive: nothing installed" "scripts dir exists"
[ ! -s "$WORK/marker" ] \
  && ok "bad archive: roles never started" || bad "bad archive: roles never started" "handed off anyway"

# 6. no staging or displaced directory survives any of the runs above — a
#    leftover would be picked up as part of the tree by the next digest and
#    silently change it.
fresh_project; : > "$WORK/marker"
run_launcher
compgen -G "$PROJ/swarmforge/.scripts.staging.*" > /dev/null \
  && bad "no staging leftovers" "staging dir survived" || ok "no staging leftovers"
compgen -G "$PROJ/swarmforge/.scripts.displaced.*" > /dev/null \
  && bad "no displaced leftovers" "displaced dir survived" || ok "no displaced leftovers"

# 7. a snapshot present but no manifest (the Incomplete state, e.g. a crash
#    between install and manifest write) re-bootstraps and completes it,
#    rather than handing off to a project start swarm would refuse as DRIFT.
fresh_project; : > "$WORK/marker"
run_launcher
rm -f "$PROJ/.swarmforge/scripts-manifest"
: > "$WORK/marker"
run_launcher
check "incomplete-state exit" 0 "$RC"
[ -f "$PROJ/.swarmforge/scripts-manifest" ] \
  && ok "incomplete state: manifest completed on the next run" \
  || bad "incomplete state: manifest completed" "still missing"
AFTER=$(digest_of "$PROJ/swarmforge/scripts")
WRITTEN2=$(grep '^DIGEST=' "$PROJ/.swarmforge/scripts-manifest" | sed 's/^DIGEST=//')
check "incomplete state: repaired manifest matches the tree" "$AFTER" "$WRITTEN2"

# 8. the shipped launcher points at the fork by default, and both override
#    variables still work.
grep -q 'SWARMFORGE_SCRIPTS_URL' "$LAUNCHER" \
  && ok "URL override preserved" || bad "URL override preserved" "missing"
grep -q 'SWARMFORGE_SCRIPTS_BRANCH' "$LAUNCHER" \
  && ok "branch override preserved" || bad "branch override preserved" "missing"
grep -q 'arlishansenn/swarm-forge' "$LAUNCHER" \
  && ok "default archive URL points at the fork" \
  || bad "default archive URL points at the fork" "$(grep ARCHIVE_URL= "$LAUNCHER")"
! grep -q 'unclebob/swarm-forge' "$LAUNCHER" \
  && ok "no upstream URL left in the launcher" \
  || bad "no upstream URL left in the launcher" "$(grep -n unclebob "$LAUNCHER")"
[ -x "$LAUNCHER" ] && ok "launcher is executable in the branch artifact" \
  || bad "launcher is executable in the branch artifact" "$(ls -l "$LAUNCHER")"

# 9. KILLED MID-INSTALL: the acceptance criterion this design exists for.
#    Bootstrap once so a real snapshot is in place, drop the manifest so the
#    launcher re-bootstraps, then SIGKILL it while the download is still
#    streaming. The already-installed destination must be byte-identical
#    afterwards. Upstream's `rm -rf` destination + `cp -R` could not hold this:
#    it deleted the live tree before it had a replacement.
#
#    SIGKILL, not SIGTERM, on purpose — a trap can clean up after TERM, so TERM
#    would test the trap rather than the design. Nothing runs after KILL, so
#    whatever is on disk is what the layout alone guarantees.
fresh_project; : > "$WORK/marker"
run_launcher
BEFORE=$(digest_of "$PROJ/swarmforge/scripts")
rm -f "$PROJ/.swarmforge/scripts-manifest"
# The stall has to land INSIDE the install window, not the download window.
# Stalling curl instead would kill the launcher before it ever touched the
# destination, and the case would pass for both designs — verified: with a
# slow curl, an upstream-style `rm -rf` + `cp -R` install passes this too, so
# that version of the test proved nothing. A slow `cp` is what separates them:
# upstream deletes the destination and THEN copies, so a kill in between
# leaves nothing; staging copies first and only renames at the end.
cat > "$WORK/bin/cp" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$WORK/bin/cp"
: > "$WORK/marker"
( cd "$PROJ" && LAUNCH_MARKER=$WORK/marker ./swarm >/dev/null 2>&1 ) &
KILLPID=$!
sleep 1
pkill -KILL -P $KILLPID 2>/dev/null
kill -KILL $KILLPID 2>/dev/null
wait $KILLPID 2>/dev/null
AFTER_KILL=$(digest_of "$PROJ/swarmforge/scripts")
check "killed mid-install: destination tree untouched" "$BEFORE" "$AFTER_KILL"
[ ! -s "$WORK/marker" ] \
  && ok "killed mid-install: roles never started" \
  || bad "killed mid-install: roles never started" "$(cat "$WORK/marker")"
[ ! -f "$PROJ/.swarmforge/scripts-manifest" ] \
  && ok "killed mid-install: no manifest written for an install that never finished" \
  || bad "killed mid-install: no manifest written" "manifest exists"
rm -f "$WORK/bin/cp"   # back to the real cp for anything after this case

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
