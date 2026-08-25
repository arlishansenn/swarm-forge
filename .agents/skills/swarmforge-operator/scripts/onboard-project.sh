#!/usr/bin/env bash
# onboard-project.sh — install an upstream SwarmForge pack into a project dir.
#
# Exit codes / STATUS line:
#   0 ONBOARDED   2 USAGE   4 OCCUPIED   5 ERROR
# Contract details live in ../SKILL.md (verb: onboard project).
# Never starts a swarm, never runs git. Depends on bash, curl, tar.
set -euo pipefail

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' PACK='' LOCAL=0

# Under set -u, "$2" on a missing option value would die with a raw bash
# unbound-variable error instead of our documented 2/USAGE contract.
usage_error() { printf 'STATUS=USAGE\n%s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || usage_error "--root requires a value"; ROOT=$2; shift 2 ;;
    --pack) [ $# -ge 2 ] || usage_error "--pack requires a value"; PACK=$2; shift 2 ;;
    --target) [ $# -ge 2 ] || usage_error "--target requires a value"; TARGET=$2; shift 2 ;;
    --key) [ $# -ge 2 ] || usage_error "--key requires a value"; KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    *) sed -n '2,7p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] && [ -n "$PACK" ] || { sed -n '2,7p' "$0"; exit 2; }

# ROOT is interpolated into a single-quoted segment of a shell string handed to
# bash -c / ssh; a literal single quote in it would break out of that quoting.
case $ROOT in
  *"'"*) usage_error "--root must not contain a single quote" ;;
esac

# upstream README: main is the documentary branch, never a pack. Encoding that
# rule here is the whole reason this script exists instead of a pasted curl.
case $PACK in
  two-pack|four-pack|six-pack) ;;
  *) printf 'STATUS=USAGE\n%s\n' \
       "pack must be two-pack, four-pack or six-pack — never main" >&2
     exit 2 ;;
esac

URL=https://github.com/unclebob/swarm-forge/tarball/$PACK

remote() {
  if [ "$LOCAL" = 1 ]; then bash -c "$1"; else ssh -i "$KEY" "$TARGET" "$1"; fi
}

if remote "test -e '$ROOT/swarm' || test -e '$ROOT/swarmforge'"; then
  printf 'STATUS=OCCUPIED\n%s\n' \
    "$ROOT already has swarm or swarmforge/ — refusing to overwrite"
  exit 4
fi

# Download and verify into a temp dir first, so a failed transfer never leaves a
# half-extracted tree that a rerun would then refuse as OCCUPIED.
if ! remote "set -e
  tmp=\$(mktemp -d)
  trap 'rm -rf \"\$tmp\"' EXIT
  curl -fsSL '$URL' -o \"\$tmp/pack.tgz\"
  tar -tzf \"\$tmp/pack.tgz\" >/dev/null
  mkdir -p '$ROOT'
  tar -xzf \"\$tmp/pack.tgz\" --strip-components=1 -C '$ROOT'"; then
  printf 'STATUS=ERROR\n%s\n' "download or extract of $PACK failed; $ROOT unchanged" >&2
  exit 5
fi

# The pack's swarm launcher ships with ARCHIVE_URL defaulting to upstream, so a
# bare first run would silently fetch unclebob's scripts and drop this fork's
# fixes (ADR 0001). Point the default at this fork; the sed address keeps the
# edit scoped to the ARCHIVE_URL= line so it can't touch anything else the
# file happens to say, and the ${SWARMFORGE_SCRIPTS_URL:-...} wrapper around
# it is untouched since only the text inside the default is replaced.
#
# cat into the existing inode, not `mv`, so the launcher's mode and owner
# survive the rewrite. `mv` from mktemp carries the temp file's 0600 across and
# leaves an unexecutable launcher while STATUS=ONBOARDED still says success
# (issue #33; update-swarmforge-scripts.sh already writes it this way).
#
# ADR-0002 makes this whole rewrite obsolete: the fork's Pack branch will ship a
# launcher already pointing here, and onboard will install the archive as-is.
# Delete this block with issue #38, not before.
remote "if [ -f '$ROOT/swarm' ]; then
  t=\$(mktemp)
  sed '/^ARCHIVE_URL=/s#unclebob/swarm-forge#arlishansenn/swarm-forge#' '$ROOT/swarm' > \"\$t\"
  cat \"\$t\" > '$ROOT/swarm'
  rm -f \"\$t\"
fi"

printf 'STATUS=ONBOARDED\n'
remote "ls -1 '$ROOT'"
printf 'next: run ./swarm in %s yourself — this script never starts a swarm\n' "$ROOT"
