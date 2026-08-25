#!/usr/bin/env bash
# test-onboard-project.sh — checks for onboard-project.sh against a stubbed curl.
# Run: bash scripts/test-onboard-project.sh. Exits non-zero on any failure.
# Only the two guards worth encoding are tested: the pack whitelist and refusing
# a non-empty target. The happy path is one curl | tar; the stub proves it lands.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/onboard-project.sh
WORK=$(mktemp -d /tmp/sf-onboard-test.XXXXXX)
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1  -- $2"; }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ---------- fixture tarball: one dir holding a swarm launcher + swarmforge/ ----
mkdir -p "$WORK/bin" "$WORK/src/pack-root/swarmforge"
# A fork Pack launcher as the branches now ship it (issue #38): already
# pointing at this fork, executable, and never patched after extraction.
cat > "$WORK/src/pack-root/swarm" <<'EOF'
#!/bin/sh
MAIN_BRANCH="${SWARMFORGE_SCRIPTS_BRANCH:-main}"
ARCHIVE_URL="${SWARMFORGE_SCRIPTS_URL:-https://github.com/arlishansenn/swarm-forge/archive/refs/heads/${MAIN_BRANCH}.tar.gz}"
EOF
chmod 755 "$WORK/src/pack-root/swarm"
echo 'roles' > "$WORK/src/pack-root/swarmforge/roles.txt"
tar -czf "$WORK/pack.tgz" -C "$WORK/src" pack-root

# ---------- stub curl: -o <file> gets the fixture, or fails on demand ---------
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${CURL_FAILS:-}" ] && exit 22
out=''
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift 2 ;; *) shift ;; esac; done
cp "$FIXTURE" "$out"
EOF
chmod +x "$WORK/bin/curl"
export PATH=$WORK/bin:$PATH FIXTURE=$WORK/pack.tgz

echo "onboard-project.sh"

# 1. happy path lands the pack
T=$WORK/proj-ok
out=$("$SCRIPT" --root "$T" --pack six-pack --local 2>&1); rc=$?
check "six-pack exits 0" 0 "$rc"
check "six-pack STATUS" "STATUS=ONBOARDED" "$(echo "$out" | head -1)"
check "swarm launcher landed" "yes" "$([ -f "$T/swarm" ] && echo yes || echo no)"
check "swarmforge/ landed" "yes" "$([ -d "$T/swarmforge" ] && echo yes || echo no)"
check "launcher ARCHIVE_URL points at the fork, override structure intact" \
  'ARCHIVE_URL="${SWARMFORGE_SCRIPTS_URL:-https://github.com/arlishansenn/swarm-forge/archive/refs/heads/${MAIN_BRANCH}.tar.gz}"' \
  "$(grep '^ARCHIVE_URL=' "$T/swarm")"
check "MAIN_BRANCH line untouched" \
  'MAIN_BRANCH="${SWARMFORGE_SCRIPTS_BRANCH:-main}"' \
  "$(grep '^MAIN_BRANCH=' "$T/swarm")"
# Issue #38: the archive is immutable input. Not "rewritten correctly" — not
# rewritten at all. Byte-identical to what came out of the tarball is the
# assertion that actually forbids a future post-install patch step.
check "launcher bytes preserved from the archive, not patched" \
  "$(sha256_of "$WORK/src/pack-root/swarm")" "$(sha256_of "$T/swarm")"
# Onboarding downloads from THIS fork's Pack branches now, not upstream's.
grep -q "arlishansenn/swarm-forge/tarball/" "$SCRIPT" \
  && ok "onboard downloads the pack from the fork" \
  || bad "onboard downloads the pack from the fork" "$(grep -n '^URL=' "$SCRIPT")"
! grep -q "unclebob/swarm-forge" "$SCRIPT" \
  && ok "no upstream URL left in onboard-project.sh" \
  || bad "no upstream URL left in onboard-project.sh" "$(grep -n unclebob "$SCRIPT")"
# Issue #33's criterion, absorbed by #38: STATUS=ONBOARDED must mean the
# installed launcher is still runnable. It used to be rewritten through
# mktemp + mv, which carried 0600 across and left an unexecutable launcher
# while still reporting success. Nothing rewrites it now, so this holds by
# construction rather than by writing it back carefully.
[ -x "$T/swarm" ] && ok "launcher still executable after onboarding" \
  || bad "launcher still executable after onboarding" \
    "$(stat -f '%Lp' "$T/swarm" 2>/dev/null || stat -c '%a' "$T/swarm")"
check "launcher mode preserved from the archive" "755" \
  "$(stat -f '%Lp' "$T/swarm" 2>/dev/null || stat -c '%a' "$T/swarm")"
check "stdout has no WARN" "no" "$(echo "$out" | grep -q '^WARN=' && echo yes || echo no)"

# 2. main is refused
T=$WORK/proj-main
"$SCRIPT" --root "$T" --pack main --local >/dev/null 2>&1; rc=$?
check "main exits 2" 2 "$rc"
check "main writes nothing" "no" "$([ -e "$T" ] && echo yes || echo no)"

# 3. unknown pack is refused
T=$WORK/proj-bogus
"$SCRIPT" --root "$T" --pack seven-pack --local >/dev/null 2>&1; rc=$?
check "unknown pack exits 2" 2 "$rc"

# 4. occupied target is refused with zero writes
T=$WORK/proj-occupied; mkdir -p "$T"; echo keepme > "$T/swarm"
out=$("$SCRIPT" --root "$T" --pack six-pack --local 2>&1); rc=$?
check "occupied exits 4" 4 "$rc"
check "occupied STATUS" "STATUS=OCCUPIED" "$(echo "$out" | head -1)"
check "occupied file untouched" "keepme" "$(cat "$T/swarm")"

# 5. download failure leaves no half-installed tree
T=$WORK/proj-netfail
CURL_FAILS=1 "$SCRIPT" --root "$T" --pack six-pack --local >/dev/null 2>&1; rc=$?
check "download failure exits 5" 5 "$rc"
check "download failure leaves nothing" "0" "$(ls -A "$T" 2>/dev/null | wc -l | tr -d ' ')"

# 6. a --root containing a single quote is refused
T="$WORK/proj-quote'oops"
out=$("$SCRIPT" --root "$T" --pack six-pack --local 2>&1); rc=$?
check "quoted root exits 2" 2 "$rc"
check "quoted root STATUS" "STATUS=USAGE" "$(echo "$out" | head -1)"

# 7. a missing option value takes the USAGE path instead of a raw bash error
out=$("$SCRIPT" --root 2>&1); rc=$?
check "missing --root value exits 2" 2 "$rc"
check "missing --root value STATUS" "STATUS=USAGE" "$(echo "$out" | head -1)"

echo "  $PASS passed, $FAIL failed"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
