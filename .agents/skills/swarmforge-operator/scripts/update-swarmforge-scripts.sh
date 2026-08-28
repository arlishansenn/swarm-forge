#!/usr/bin/env bash
# update-swarmforge-scripts.sh — `update SwarmForge scripts` verb (issue
# #29): install THIS repo's own swarmforge/scripts/ into a managed
# project's swarmforge/scripts/, atomically, only after staging and
# validating a full copy so a bad or half-built source checkout never
# reaches $ROOT. Writes the manifest that start-swarm.sh's drift preflight
# reads (see lib-wake-talk.sh's read_manifest), so a project onboarded from
# an upstream pack (whose swarmforge/scripts/ came from wherever ./swarm's
# own first-run ARCHIVE_URL pointed) can be brought onto this fork's
# scripts and legacy `./swarm` launcher without the manual, silently
# incomplete process that left podsum running scripts its own launcher
# didn't recognize as required.
#
# Exit codes / STATUS line:
#   0 UPDATED   2 USAGE   5 ERROR   6 UNSAFE
# Contract details live in ../SKILL.md (verb: update SwarmForge scripts).
#
# Usage: update-swarmforge-scripts.sh --root <project-root> \
#   [--target user@host] [--key <path>] [--local] [--force]
#
# Ordering (deliberately matching start-swarm.sh's already-running-then-lock
# order, not the issue text's original "lock first" wording — see issue #29
# task brief): 1) refuse if the swarm is already running, no override,
# zero side effects, lock never touched; 2) acquire the project lock
# (--force steals a held one); 3) everything else — dirty-source check,
# staging, validation, digest, transfer, atomic replace, manifest write,
# legacy launcher rewrite — runs with the lock held, released on every exit
# path via the trap installed right after acquisition.
#
# --force has ONE effect here: it steals a held project lock. It never
# overrides the already-running refusal (no override exists for that, same
# as start-swarm.sh) and never overrides the dirty-source-checkout refusal
# (no override exists for that either, by design — an uncommitted source
# checkout is never a safe thing to ship, force or not).
#
# SOURCE_ROOT (the checkout this verb installs FROM) is always resolved
# from this script's own on-disk location, on the machine the operator
# script is actually running on — never from $ROOT/--target, regardless of
# whether the managed project itself is local or remote. Override with
# SF_SOURCE_ROOT for tests that need an isolated fixture git repo instead
# of this real checkout's live git state.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' LOCAL=0 FORCE=0

# Verb contract: a scripted verb prints STATUS=<WORD> as its first line —
# same pattern onboard-project.sh's usage_error() uses.
usage() { printf 'STATUS=USAGE\n'; sed -n '2,32p' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --force) FORCE=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$ROOT" ] || usage

# Four `..` from .../swarmforge-operator/scripts lands on the repo root:
# .../<repo-root>/.agents/skills/swarmforge-operator/scripts -> repo-root.
SOURCE_ROOT=${SF_SOURCE_ROOT:-$(cd "$HERE/../../../.." && pwd)}
SOURCE_SCRIPTS=$SOURCE_ROOT/swarmforge/scripts

# Canonical terminal-adapter filenames (swarmforge.bb's `terminal-helpers`
# def) — hardcoded here for the same reason start-swarm.sh hardcodes its
# --terminal value set instead of listing the directory: the tree that
# matters is the STAGED copy, and swarmforge.bb has no CLI flag equivalent
# to --test-required-helpers for this list, so a round trip through `bb`
# would need a new flag for a set that changes about as rarely as the
# required-helpers list itself. Read swarmforge.bb's own `terminal-helpers`
# def to keep this list in sync if it ever changes.
TERMINAL_ADAPTERS='terminal-app.sh iterm2.sh ghostty.sh windows-terminal.sh none.sh'

# ---------- preflight: already running? Same socket-liveness read/refusal
# start-swarm.sh uses for its own already-running gate — copied verbatim,
# no override, zero side effects, lock never touched. ----------
if SOCK=$(read_file .swarmforge/tmux-socket 2>/dev/null); then
  SOCK=${SOCK%$'\n'}
  if tmux_remote list-sessions >/dev/null 2>&1; then
    die UNSAFE "socket $SOCK already has a live tmux server — swarm is running; stop it before updating SwarmForge scripts" 6
  fi
fi

# ---------- lock: exclude a concurrent start (issue #29) ----------
# `|| LOCK_RC=$?` rather than a bare call: acquire_lock reports contention (1)
# and a filesystem failure (2) through its exit status, and under `set -e` a
# bare non-zero call would abort the script before the status could be read.
LOCK_RC=0; acquire_lock update || LOCK_RC=$?
if [ "$LOCK_RC" = 2 ]; then
  die ERROR "cannot create $ROOT/.swarmforge to take the project lock — check the path and its permissions" 5
fi
if [ "$LOCK_RC" != 0 ]; then
  if [ "$FORCE" != 1 ]; then
    die UNSAFE "project lock held by '$LOCK_HOLDER' — wait, or re-run with --force to break a lock left by a dead process" 6
  fi
  release_lock
  acquire_lock update || die ERROR \
    "failed to acquire project lock at $ROOT/.swarmforge/update-lock even after --force cleared it" 5
fi
trap release_lock EXIT

# ---------- dirty-source check (no override, ever) ----------
# Always a plain local git call against the OPERATOR's own machine — never
# routed through git_status, which is LOCAL/remote-*target*-aware for the
# MANAGED project, a different machine than this source checkout.
DIRTY=$(git -C "$SOURCE_ROOT" status --porcelain -- swarmforge/scripts)
[ -z "$DIRTY" ] || die ERROR \
  "source checkout at $SOURCE_ROOT has uncommitted changes under swarmforge/scripts/ — commit or stash them before updating" 5

SOURCE_COMMIT=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
SOURCE_REPO=$(git -C "$SOURCE_ROOT" remote get-url origin 2>/dev/null || echo unknown)

# ---------- stage: fresh copy of SOURCE_SCRIPTS, bytes + exec bits
# preserved (cp -R does both on macOS and Linux; verified empirically while
# building this script). Staging always happens locally, even for a remote
# --target: SOURCE_SCRIPTS is always local to the operator. Location
# depends on mode:
#
# LOCAL=1: staged under $ROOT/swarmforge/ itself (never mktemp -d's default
# $TMPDIR/tmp, which is commonly a separate tmpfs mount on Linux) so the
# `mv` below (this same local $STAGED into $ROOT/swarmforge/scripts) is
# guaranteed same-filesystem-as-destination and therefore atomic — same
# guarantee the backup rename already has by construction. A leading `.`
# keeps it out of naive directory listings; nothing in this codebase
# iterates $ROOT/swarmforge/'s own contents (confirmed against
# swarmforge.bb: its only dir listing is `fs/list-dir` on :script-dir, i.e.
# $ROOT/swarmforge/scripts itself, a sibling of this staging dir, not its
# parent).
#
# LOCAL=0 (remote): $ROOT is a path on $TARGET, not this machine — every
# other $ROOT-touching call in this codebase (read_file, acquire_lock,
# release_lock) is LOCAL/remote-aware and never touches a literal
# $ROOT-prefixed path locally, and this staging dir must not either: it's
# only ever read from (cp -R here, tar below), never `mv`'d anywhere, so it
# never needed the same-filesystem-as-$ROOT guarantee in the first place.
# Plain system temp via mktemp -d. REMOTE_STAGE below (on $TARGET itself)
# is what actually gets mv'd into the final destination on that host, and
# that one does need — and has — the same-filesystem guarantee. ----------
if [ "$LOCAL" = 1 ]; then
  STAGED="$ROOT/swarmforge/.stage.$$"
  rm -rf "$STAGED"
  mkdir -p "$ROOT/swarmforge"
else
  STAGED=$(mktemp -d)
fi
cp -R "$SOURCE_SCRIPTS/." "$STAGED/"

# ---------- validate the STAGED copy (never the live source, never the
# live destination) against the same two lists swarmforge.bb's own
# check-helper-scripts! enforces ----------
fail_staged() { # $1 = message
  rm -rf "$STAGED"
  die ERROR "$1" 5
}

[ -x "$STAGED/swarmforge.bb" ] || fail_staged \
  "staged scripts tree has no executable swarmforge.bb at $STAGED/swarmforge.bb"

command -v bb >/dev/null 2>&1 || fail_staged \
  "'bb' is not on PATH — cannot validate the staged tree's required helpers"

# Plain command substitution (unlike process substitution) propagates a
# failing `bb` under set -e, so a broken/missing bb surfaces as an error
# instead of silently reading zero lines and skipping every check below.
HELPERS=$(bb "$STAGED/swarmforge.bb" --test-required-helpers) || fail_staged \
  "bb $STAGED/swarmforge.bb --test-required-helpers failed — cannot validate the staged tree's required helpers"

while IFS= read -r helper; do
  [ -n "$helper" ] || continue
  [ -x "$STAGED/$helper" ] || fail_staged \
    "staged scripts tree is missing required helper '$helper' (or it is not executable) at $STAGED/$helper"
done <<< "$HELPERS"

for adapter in $TERMINAL_ADAPTERS; do
  [ -x "$STAGED/terminal-adapters/$adapter" ] || fail_staged \
    "staged scripts tree is missing required terminal adapter '$adapter' (or it is not executable) at $STAGED/terminal-adapters/$adapter"
done

# ---------- digest the STAGED tree now (local, always — this is the value
# written into the manifest, never recomputed after transfer; tar/mv are
# verified to preserve bytes and executable bits by the required cross-verb
# integration test) ----------
DIGEST=$(scripts_digest "$STAGED")

# ---------- replace: all-or-nothing across scripts tree + manifest +
# legacy launcher ----------
if [ "$LOCAL" = 1 ]; then
  BACKUP="$ROOT/swarmforge/scripts.old.$$"
  OLD_MOVED=0
  if [ -d "$ROOT/swarmforge/scripts" ]; then
    mv "$ROOT/swarmforge/scripts" "$BACKUP"
    OLD_MOVED=1
  fi
  mv "$STAGED" "$ROOT/swarmforge/scripts"

  # Back up any pre-existing manifest alongside the scripts-tree backup, so
  # a rollback below can restore it instead of just deleting the new one —
  # a missing manifest over an intact old scripts tree is neither the old
  # nor the new installation (issue #29 review round 4 finding).
  mkdir -p "$ROOT/.swarmforge"
  MANIFEST_BACKUP=""
  if [ -f "$ROOT/.swarmforge/scripts-manifest" ]; then
    MANIFEST_BACKUP="$ROOT/.swarmforge/scripts-manifest.old.$$"
    cp "$ROOT/.swarmforge/scripts-manifest" "$MANIFEST_BACKUP"
  fi
  if ! printf 'SOURCE_COMMIT=%s\nSOURCE_REPO=%s\nDIGEST=%s\n' \
        "$SOURCE_COMMIT" "$SOURCE_REPO" "$DIGEST" \
        > "$ROOT/.swarmforge/scripts-manifest" 2>/dev/null; then
    rm -rf "$ROOT/swarmforge/scripts"
    [ "$OLD_MOVED" = 1 ] && mv "$BACKUP" "$ROOT/swarmforge/scripts"
    rm -f "$MANIFEST_BACKUP"
    die ERROR "failed to write manifest at $ROOT/.swarmforge/scripts-manifest — rolled back to the previous scripts tree" 5
  fi

  if [ -f "$ROOT/swarm" ]; then
    T=$(mktemp)
    sed '/^ARCHIVE_URL=/s#unclebob/swarm-forge#arlishansenn/swarm-forge#' "$ROOT/swarm" > "$T"
    # cat into the existing inode (not `mv`, which would carry mktemp's
    # 0600 mode and owner onto $ROOT/swarm) so the launcher's own
    # executable bit and owner survive the rewrite (issue #29 review round
    # 4 finding — Critical: `mv` from mktemp bricked every legacy launcher).
    cat "$T" > "$ROOT/swarm"
    rm -f "$T"
    if ! grep -q '^ARCHIVE_URL=.*arlishansenn/swarm-forge' "$ROOT/swarm"; then
      rm -rf "$ROOT/swarmforge/scripts" "$ROOT/.swarmforge/scripts-manifest"
      [ "$OLD_MOVED" = 1 ] && mv "$BACKUP" "$ROOT/swarmforge/scripts"
      [ -n "$MANIFEST_BACKUP" ] && mv "$MANIFEST_BACKUP" "$ROOT/.swarmforge/scripts-manifest"
      die ERROR "$ROOT/swarm exists but its ARCHIVE_URL line did not match the expected upstream pattern after rewrite — rolled back to the previous scripts tree and manifest" 5
    fi
  fi

  [ "$OLD_MOVED" = 1 ] && rm -rf "$BACKUP"
  rm -f "$MANIFEST_BACKUP"
else
  # ---------- remote replace: staged tree lives on the OPERATOR's machine
  # and must reach $TARGET. One tar-over-ssh call extracts it into a fresh
  # remote staging path; a second, single ssh call runs the entire
  # swap/manifest-write/launcher-rewrite/rollback sequence as ONE shell
  # script string (bash -c with %q-quoted positional args — same shape as
  # remote_scripts_digest's embedded snippet), so the critical section is
  # one round trip, never a hand-interpolated $ROOT in a raw string.
  #
  # Staged under $ROOT/swarmforge/ on the REMOTE host, same reasoning as the
  # local branch above: /tmp is commonly a separate tmpfs mount on Linux, so
  # a plain /tmp path would make the remote swap `mv` fall back to a
  # non-atomic copy+delete. Named distinctly from the local $STAGED (a
  # "-remote" infix, not just the same .stage.$$) so the two never collide
  # by path even if $ROOT happens to name the same location on both the
  # operator machine and $TARGET (e.g. a shared mount). ----------
  REMOTE_STAGE="$ROOT/swarmforge/.stage-remote.$$"

  XFER_CMD=$(printf '%q' mkdir)$(printf ' %q' -p "$REMOTE_STAGE")
  XFER_CMD="$XFER_CMD && $(printf '%q' tar)$(printf ' %q' -C "$REMOTE_STAGE" -xf -)"
  # COPYFILE_DISABLE=1: macOS bsdtar otherwise packs an AppleDouble `._<name>`
  # companion for every file, which GNU tar on Linux extracts as a real file.
  # The manifest digest is computed over the STAGED tree, so those phantom
  # files made every macOS-to-Linux install fail start-swarm's drift check.
  if ! COPYFILE_DISABLE=1 tar -C "$STAGED" -cf - . | ssh -i "$KEY" "$TARGET" "$XFER_CMD"; then
    rm -rf "$STAGED"
    die ERROR "failed to transfer staged scripts to $TARGET:$REMOTE_STAGE" 5
  fi
  rm -rf "$STAGED"

  # Remote-side script, byte-identical in shape to the LOCAL branch above,
  # just running on $TARGET instead. Positional args:
  # $1=ROOT $2=REMOTE_STAGE $3=SOURCE_COMMIT $4=SOURCE_REPO $5=DIGEST.
  # Prints OK on success; MANIFEST_WRITE_FAILED or LAUNCHER_MISMATCH to
  # stderr (in addition to a non-zero exit) so this script can report a
  # specific reason instead of a generic remote-failure message.
  SNIPPET=$(cat <<'EOS'
set -eu
root=$1 stage=$2 commit=$3 repo=$4 digest=$5
old_moved=0
if [ -d "$root/swarmforge/scripts" ]; then
  mv "$root/swarmforge/scripts" "$root/swarmforge/scripts.old.$$"
  old_moved=1
fi
mv "$stage" "$root/swarmforge/scripts"
mkdir -p "$root/.swarmforge"
manifest_backup=""
if [ -f "$root/.swarmforge/scripts-manifest" ]; then
  manifest_backup="$root/.swarmforge/scripts-manifest.old.$$"
  cp "$root/.swarmforge/scripts-manifest" "$manifest_backup"
fi
if ! printf 'SOURCE_COMMIT=%s\nSOURCE_REPO=%s\nDIGEST=%s\n' "$commit" "$repo" "$digest" \
      > "$root/.swarmforge/scripts-manifest" 2>/dev/null; then
  rm -rf "$root/swarmforge/scripts"
  [ "$old_moved" = 1 ] && mv "$root/swarmforge/scripts.old.$$" "$root/swarmforge/scripts"
  rm -f "$manifest_backup"
  echo MANIFEST_WRITE_FAILED >&2
  exit 5
fi
if [ -f "$root/swarm" ]; then
  t=$(mktemp)
  sed '/^ARCHIVE_URL=/s#unclebob/swarm-forge#arlishansenn/swarm-forge#' "$root/swarm" > "$t"
  # cat into the existing inode, not `mv`, so the launcher's mode/owner
  # survive the rewrite (see the LOCAL branch above for why).
  cat "$t" > "$root/swarm"
  rm -f "$t"
  if ! grep -q '^ARCHIVE_URL=.*arlishansenn/swarm-forge' "$root/swarm"; then
    rm -rf "$root/swarmforge/scripts" "$root/.swarmforge/scripts-manifest"
    [ "$old_moved" = 1 ] && mv "$root/swarmforge/scripts.old.$$" "$root/swarmforge/scripts"
    [ -n "$manifest_backup" ] && mv "$manifest_backup" "$root/.swarmforge/scripts-manifest"
    echo LAUNCHER_MISMATCH >&2
    exit 5
  fi
fi
[ "$old_moved" = 1 ] && rm -rf "$root/swarmforge/scripts.old.$$"
rm -f "$manifest_backup"
echo OK
EOS
)
  SWAP_CMD=$(printf '%q' bash)$(printf ' %q' -c "$SNIPPET" bash \
    "$ROOT" "$REMOTE_STAGE" "$SOURCE_COMMIT" "$SOURCE_REPO" "$DIGEST")

  if ! SWAP_OUT=$(ssh -n -i "$KEY" "$TARGET" "$SWAP_CMD" 2>&1); then
    case $SWAP_OUT in
      *MANIFEST_WRITE_FAILED*)
        die ERROR "failed to write manifest at $ROOT/.swarmforge/scripts-manifest on $TARGET — rolled back to the previous scripts tree" 5 ;;
      *LAUNCHER_MISMATCH*)
        die ERROR "$ROOT/swarm exists but its ARCHIVE_URL line did not match the expected upstream pattern after rewrite — rolled back to the previous scripts tree and manifest" 5 ;;
      *)
        die ERROR "remote scripts swap on $TARGET failed: $SWAP_OUT" 5 ;;
    esac
  fi
fi

printf 'STATUS=UPDATED\nROOT=%s\nDIGEST=%s\nSOURCE_COMMIT=%s\n' "$ROOT" "$DIGEST" "$SOURCE_COMMIT"
exit 0
