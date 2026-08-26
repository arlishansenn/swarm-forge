#!/usr/bin/env bash
# test-onboard-start-stop-e2e.sh — the public-seam E2E issue #35 asks for:
# empty target -> onboard project -> start swarm -> stop swarm -> start swarm
# again, driven only through the operator verbs, with no manual bootstrap
# step anywhere in between. Run: bash test-onboard-start-stop-e2e.sh
#
# Why this exists as its own file rather than more cases in
# test-start-swarm.sh: every other test in this directory drives ONE artifact
# with the others stubbed. The bug class #35 was opened for lives in the seam
# BETWEEN two artifacts that ship separately — the operator skill (this
# branch) and the Pack launcher (the two-pack/four-pack/six-pack branches,
# fetched by curl at onboard time). `start swarm` refusing a fresh project
# with DRIFT, and the launcher's manifest disagreeing with the digest
# `start swarm` recomputes, are both invisible to any test that stubs the
# other side. So this one runs the REAL launcher out of each Pack branch
# against the REAL operator scripts.
#
# What is genuinely exercised, and what is not:
#   real  — onboard-project.sh, start-swarm.sh, stop-swarm.sh, each Pack
#           branch's own ./swarm launcher, the whole snapshot tree from this
#           working tree's swarmforge/, both digest implementations.
#   stub  — curl (serves local git archives; nothing here touches the
#           network), tmux, close-swarm, and swarmforge.sh, the runtime
#           entrypoint the launcher execs into. swarmforge.sh needs babashka
#           and a real terminal; running it is `bb test`'s job, not this
#           file's. Everything up to and including the exec is real.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)
ONBOARD=$HERE/onboard-project.sh
START=$HERE/start-swarm.sh
STOP=$HERE/stop-swarm.sh
WORK=$(mktemp -d /tmp/sf-e2e-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }

[ -n "$REPO" ] || { echo "not inside a git checkout — cannot build fixtures"; exit 1; }
for s in "$ONBOARD" "$START" "$STOP"; do
  [ -x "$s" ] || { echo "missing $s"; exit 1; }
done

# The operator's own digest, used to check the launcher's manifest from the
# outside. Sourced the same way test-start-swarm.sh does it: scripts_digest is
# LOCAL-only and takes a bare directory, so no ROOT/TARGET machinery is needed.
compute_digest() { ( LOCAL=1; . "$HERE/lib-wake-talk.sh"; scripts_digest "$1" ); }

# ---------- fixture: the fork `main` snapshot the launcher will bootstrap ----
# Built from THIS working tree, not a canned mini-tree: the point of the
# digest assertions below is that the launcher's manifest matches what the
# operator recomputes over the real snapshot, and a two-file toy tree would
# agree by accident.
MAINSRC=$WORK/src/swarm-forge-main
mkdir -p "$MAINSRC"
git -C "$REPO" archive HEAD swarmforge | tar -x -C "$MAINSRC"
[ -d "$MAINSRC/swarmforge/scripts" ] || { echo "HEAD has no swarmforge/scripts"; exit 1; }

# Only the runtime entrypoint is replaced. It stands in for the babashka
# swarm: produce the runtime files the operator verbs read, and derive the
# role rows from the Pack's own swarmforge/roles/*.prompt so nothing here
# branches on Role names (#35 acceptance criterion) or on pack size.
cat > "$MAINSRC/swarmforge/scripts/swarmforge.sh" <<'EOF'
#!/usr/bin/env bash
# stub runtime — see test-onboard-start-stop-e2e.sh
set -eu
ROOT=$(pwd)
mkdir -p "$ROOT/.swarmforge"
printf '%s\n' "$ROOT/.swarmforge/tmux.sock" > "$ROOT/.swarmforge/tmux-socket"
: > "$ROOT/.swarmforge/sessions.tsv"
: > "$ROOT/.swarmforge/roles.tsv"
i=0
for p in "$ROOT"/swarmforge/roles/*.prompt; do
  [ -e "$p" ] || continue
  r=$(basename "$p" .prompt)
  i=$((i+1))
  printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$r" "sf-$r" "$r" grok >> "$ROOT/.swarmforge/sessions.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$r" "$r" "$ROOT" "sf-$r" "$r" grok 0 >> "$ROOT/.swarmforge/roles.tsv"
done
touch "${STUB:?}/live"
EOF
chmod +x "$MAINSRC/swarmforge/scripts/swarmforge.sh"
tar -czf "$WORK/main.tgz" -C "$WORK/src" swarm-forge-main

# ---------- stubs on PATH ----------
mkdir -p "$WORK/bin"

# curl serves two different fixtures. Which one is decided by the URL, exactly
# as the two real callers differ: onboard fetches a Pack branch tarball with
# -o, the launcher pipes a `main` archive to tar.
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
url='' out=''
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case $url in
  *"/tarball/"*) src=${FIXTURE_PACK:?} ;;
  *) src=${FIXTURE_MAIN:?} ;;
esac
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
EOF
chmod +x "$WORK/bin/curl"

# tmux, gated by a flag file the stub runtime creates and close-swarm removes,
# same shape as test-start-swarm.sh's. capture-pane answers with an IDLE line
# so stop swarm's preflight has no BUSY/UNKNOWN role to refuse over.
cat > "$WORK/bin/tmux" <<'EOF'
#!/usr/bin/env bash
STUB=${STUB:?}
[ -f "$STUB/live" ] || exit 1
shift 2  # drop -S <sock>
case ${1:-} in
  list-sessions) exit 0 ;;
  capture-pane) printf '\xe2\x9d\xaf\n'; exit 0 ;;
esac
exit 1
EOF
chmod +x "$WORK/bin/tmux"

cat > "$WORK/bin/close-swarm" <<'EOF'
#!/usr/bin/env bash
rm -f "${STUB:?}/live"
rm -f "$1/.swarmforge/tmux-socket" "$1/.swarmforge/sessions.tsv" "$1/.swarmforge/roles.tsv"
EOF
chmod +x "$WORK/bin/close-swarm"

export PATH=$WORK/bin:$PATH FIXTURE_MAIN=$WORK/main.tgz
export CLOSE_SWARM=$WORK/bin/close-swarm
# The readiness poll is sized for a real multi-process launch; the stub is
# instant, so shrink the budget rather than sit through 60s per pack.
export SF_START_READY_TRIES=40 SF_START_READY_INTERVAL=0.1

run_start() { # sets OUT/RC
  OUT=$("$START" --root "$PROJ" --terminal none --local 2>&1); RC=$?
}

# ---------- one full lifecycle per pack ----------
for PACK in two-pack four-pack six-pack; do
  echo "$PACK: empty target -> onboard -> start -> stop -> start"

  REF=''
  for cand in "origin/$PACK" "$PACK"; do
    git -C "$REPO" rev-parse --verify -q "$cand^{commit}" >/dev/null && { REF=$cand; break; }
  done
  if [ -z "$REF" ]; then
    bad "$PACK: branch available to build the pack fixture from" \
      "neither origin/$PACK nor $PACK resolves — fetch the pack branches"
    continue
  fi
  git -C "$REPO" archive --prefix=pack-root/ "$REF" | gzip > "$WORK/$PACK.tgz"
  export FIXTURE_PACK=$WORK/$PACK.tgz

  export STUB=$WORK/stub-$PACK; rm -rf "$STUB"; mkdir -p "$STUB"
  PROJ=$WORK/proj-$PACK; rm -rf "$PROJ"

  # 1. empty target -> onboard project
  OUT=$("$ONBOARD" --root "$PROJ" --pack "$PACK" --local 2>&1); RC=$?
  check "$PACK: onboard exits 0" 0 "$RC"
  check "$PACK: onboard STATUS" "STATUS=ONBOARDED" "$(printf '%s\n' "$OUT" | head -1)"
  [ -x "$PROJ/swarm" ] && ok "$PACK: launcher installed and executable" \
    || bad "$PACK: launcher installed and executable" \
      "$(stat -f '%Lp' "$PROJ/swarm" 2>/dev/null || stat -c '%a' "$PROJ/swarm" 2>/dev/null || echo absent)"
  # Onboarding deliberately leaves the project in the FRESH state: no
  # snapshot, no manifest. If it ever installed either, the launcher's
  # bootstrap would be dead code and this whole E2E would prove nothing.
  [ ! -d "$PROJ/swarmforge/scripts" ] && ok "$PACK: onboard installs no script snapshot" \
    || bad "$PACK: onboard installs no script snapshot" "swarmforge/scripts exists"
  [ ! -e "$PROJ/.swarmforge/scripts-manifest" ] && ok "$PACK: onboard writes no manifest" \
    || bad "$PACK: onboard writes no manifest" "manifest exists"

  # A real onboarded project is a git checkout; stop swarm's preflight reads
  # `git status` per worktree and treats an unreadable one as DIRTY. The
  # pack's own .gitignore covers .swarmforge/ and swarmforge/scripts/, so
  # committing here stays clean across the bootstrap that follows.
  git -C "$PROJ" init -q && git -C "$PROJ" add -A \
    && git -C "$PROJ" -c user.email=e2e@test -c user.name=e2e commit -qm init

  # 2. start swarm on a fresh project — the #35 bug: this used to be DRIFT/4
  #    because the manifest preflight ran before the launcher ever got to
  #    bootstrap, leaving no unforced way to start a just-onboarded project.
  run_start
  check "$PACK: first start exits 0" 0 "$RC"
  check "$PACK: first start STATUS" "STATUS=STARTED" "$(printf '%s\n' "$OUT" | head -1)"
  printf '%s\n' "$OUT" | grep -q 'STATUS=DRIFT' \
    && bad "$PACK: fresh start is not refused as drift" "$OUT" \
    || ok "$PACK: fresh start is not refused as drift"

  # 3. the launcher — not onboard, not start — is what installed the snapshot
  [ -f "$PROJ/swarmforge/scripts/swarmforge.sh" ] \
    && ok "$PACK: launcher bootstrapped the script snapshot" \
    || bad "$PACK: launcher bootstrapped the script snapshot" "missing"
  [ -d "$PROJ/swarmforge/scripts/shared-articles" ] \
    && ok "$PACK: bootstrap installed shared constitution articles" \
    || bad "$PACK: bootstrap installed shared constitution articles" "missing"
  # The cross-artifact agreement this E2E exists for: the launcher ships its
  # own from-scratch copy of scripts_digest (it cannot source the operator
  # skill), so a drift between the two implementations would surface as a
  # DRIFT on the SECOND start and nowhere earlier. Compare them directly.
  MANIFEST_DIGEST=$(sed -n 's/^DIGEST=//p' "$PROJ/.swarmforge/scripts-manifest")
  check "$PACK: launcher manifest digest matches the operator's recomputation" \
    "$(compute_digest "$PROJ/swarmforge/scripts")" "$MANIFEST_DIGEST"

  # 4. stop swarm
  OUT=$("$STOP" --root "$PROJ" --local 2>&1); RC=$?
  check "$PACK: stop exits 0" 0 "$RC"
  check "$PACK: stop STATUS" "STATUS=STOPPED" "$(printf '%s\n' "$OUT" | head -1)"

  # 5. second start — now a MANAGED project: both identity artifacts present,
  #    digest verified before launch. No manual bootstrap workaround anywhere
  #    in this loop; the only commands run were the three verbs and a git init.
  run_start
  check "$PACK: second start exits 0" 0 "$RC"
  check "$PACK: second start STATUS" "STATUS=STARTED" "$(printf '%s\n' "$OUT" | head -1)"
  check "$PACK: second start reuses the snapshot, does not re-bootstrap" \
    "$MANIFEST_DIGEST" "$(sed -n 's/^DIGEST=//p' "$PROJ/.swarmforge/scripts-manifest")"

  "$STOP" --root "$PROJ" --local >/dev/null 2>&1
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
