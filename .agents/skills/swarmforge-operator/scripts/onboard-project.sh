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

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --pack) PACK=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    *) sed -n '2,7p' "$0"; exit 2 ;;
  esac
done
[ -n "$ROOT" ] && [ -n "$PACK" ] || { sed -n '2,7p' "$0"; exit 2; }

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

printf 'STATUS=ONBOARDED\n'
remote "ls -1 '$ROOT'"
printf 'next: run ./swarm in %s yourself — this script never starts a swarm\n' "$ROOT"
