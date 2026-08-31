#!/usr/bin/env bash
# onboard-project.sh — install an upstream SwarmForge pack into a project dir.
#
# Exit codes / STATUS line:
#   0 ONBOARDED   2 USAGE   4 OCCUPIED   5 ERROR
# Contract details live in ../SKILL.md (verb: onboard project).
# Never starts a swarm, never runs git. Depends on bash, curl, tar.
#
# It does write one line-set into $ROOT/.gitignore (issue #87). That is the
# only project-owned file this verb touches, and it is appended to, never
# replaced. The reason: everything this verb installs arrives UNTRACKED in the
# managed project, so `stop swarm`'s preflight — which cannot tell "SwarmForge
# installed this" from "you forgot to commit this" — reports DIRTY forever and
# `--force` becomes the only way to stop anything. A gate that fires every
# single time is a gate nobody reads; issue #58 already cost us that once, from
# the other direction. The verb that installs the files owns making them quiet.
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

# Markers make the block find-able and re-runnable. Presence of the opening
# marker is the whole idempotence test: a second onboard, or a human who has
# since edited the entries, must not get a duplicate block.
GI_MARK='# >>> SwarmForge installed files >>>'
GI_END='# <<< SwarmForge installed files <<<'

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
  # The archive carries a .gitignore and a README.md of its own, and tar would
  # write them straight over the managed project's. Those two files belong to
  # the project, not to SwarmForge — same rule as the launcher in issue #33,
  # pointed the other way: there, not touching the archive's file is what
  # preserved it; here, not letting the archive touch the project's file is.
  # Saved and put back rather than excluded from extraction, because the
  # archive's top-level directory name is a GitHub-generated sha we cannot
  # write a reliable tar --exclude pattern against.
  for f in .gitignore README.md; do
    if [ -e '$ROOT'/\$f ]; then cp -p '$ROOT'/\$f \"\$tmp/keep-\$f\"; fi
  done
  tar -xzf \"\$tmp/pack.tgz\" --strip-components=1 -C '$ROOT'
  for f in .gitignore README.md; do
    if [ -e \"\$tmp/keep-\$f\" ]; then cp -p \"\$tmp/keep-\$f\" '$ROOT'/\$f; fi
  done
  # The ignore entries are DERIVED from the archive that was just installed,
  # never hardcoded: the artifact is the only thing that knows what it put
  # there, and a hand-kept list would drift the first time a Pack branch gains
  # or loses a top-level file. .gitignore and README.md are excluded because
  # those two belong to the managed project even when the archive also carries
  # them. .swarmforge/ and .worktrees/ are added because the swarm creates them
  # later, at run time, so they are not in the archive listing.
  cd '$ROOT'
  if [ ! -f .gitignore ] || ! grep -qxF '$GI_MARK' .gitignore; then
    {
      if [ -s .gitignore ] && [ -n \"\$(tail -c1 .gitignore)\" ]; then echo; fi
      echo '$GI_MARK'
      echo '# Installed by onboard project. Safe to commit; safe to delete if'
      echo '# this project version-controls its own SwarmForge instead.'
      tar -tzf \"\$tmp/pack.tgz\" \
        | sed 's#^[^/]*/##' \
        | awk -F/ 'NF && \$1 != \"\" { print \$1 }' \
        | sort -u \
        | grep -vxE '[.]gitignore|README[.]md' \
        | sed 's#^#/#'
      echo '/.swarmforge/'
      echo '/.worktrees/'
      echo '$GI_END'
    } >> .gitignore
  fi"; then
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
printf 'gitignore: SwarmForge block present in %s/.gitignore — commit it, or delete it if this project version-controls its own SwarmForge\n' "$ROOT"
printf 'next: run ./swarm in %s yourself — this script never starts a swarm\n' "$ROOT"
