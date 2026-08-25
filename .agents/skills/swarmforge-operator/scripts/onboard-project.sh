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

# This fork's Pack branches, not upstream's (issue #38, ADR-0002). The fork
# owns the complete artifact it installs: each Pack branch already carries its
# final config and a launcher pointing at this fork's `main`, so the archive is
# installed exactly as it comes out of the tarball.
URL=https://github.com/arlishansenn/swarm-forge/tarball/$PACK

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

# No post-extraction patching (issue #38). The launcher used to be rewritten
# here to repoint its ARCHIVE_URL at this fork; the fork's Pack branches now
# ship it that way already, so the extracted archive is immutable input. That
# rewrite is also what destroyed the launcher's executable mode (issue #33):
# not touching the file at all is what makes its bytes and mode survive, rather
# than a more careful way of writing it back.
#
# `update SwarmForge scripts` keeps its own, separate ARCHIVE_URL rewrite. That
# one is deliberately retained as a legacy-repair path for projects onboarded
# BEFORE this change, whose launcher may still point at upstream — a shrinking
# but real population. It is not merged with this (now removed) step, and not
# deleted.
printf 'STATUS=ONBOARDED\n'
remote "ls -1 '$ROOT'"
printf 'next: run ./swarm in %s yourself — this script never starts a swarm\n' "$ROOT"
