# lib-wake-talk.sh — send-then-verify logic shared by wake-role.sh and
# talk-role.sh (issue #14: a mismatched backend must fail loudly, not send
# keys into the void). read-swarm.sh (issue #15) and stop-swarm.sh (issue
# #11) also source this file: both are report-shaped verbs that only need
# the die/read_file/tmux_remote plumbing plus BUSY_RE/IDLE_RE/classify — they
# never call resolve_role or send_and_verify, since neither sends keys.
# stop-swarm.sh additionally uses git_status for its DIRTY-worktree check.
# accept-work.sh (issue #17) additionally uses git_merge_base_ancestor for its
# already-shipped exclusion check. start-swarm.sh (issue #26) additionally
# uses run_detached for its launch step, and (issue #29) acquire_lock/
# release_lock/scripts_digest/remote_scripts_digest/read_manifest for its
# lock + drift preflight. A sibling verb, `update SwarmForge scripts`
# (issue #29, not yet implemented), reuses the same lock and digest
# primitives and is the WRITER for the manifest format read_manifest
# parses below.
# Sourced, never executed directly.
#
# Callers must set ROOT, TARGET, KEY, LOCAL before sourcing, and SOCK after
# resolving it. Provides: die, read_file, tmux_remote, resolve_role,
# send_and_verify, run_detached, acquire_lock, release_lock, scripts_digest,
# remote_scripts_digest, read_manifest.

die() { printf 'STATUS=%s\n%s\n' "$1" "$2"; exit "${3:-5}"; }

read_file() { # $1 = path under ROOT
  if [ "$LOCAL" = 1 ]; then cat "$ROOT/$1"
  else ssh -n -i "$KEY" "$TARGET" "cat '$ROOT/$1'"; fi
}

# Runs tmux on the target with argv passed through untouched, never a
# hand-built remote string. LOCAL execs tmux directly (no shell in the
# middle, so nothing needs escaping). Remote mode still has to cross an ssh
# exec, which joins its trailing arguments into one string for the remote
# shell to reparse — so each argument is %q-quoted before joining, which is
# what actually stops free text (talk role's message) from breaking out,
# rather than hoping raw argv survives the hop unquoted.
tmux_remote() {
  if [ "$LOCAL" = 1 ]; then
    tmux -S "$SOCK" "$@"
  else
    local cmd a
    cmd=$(printf '%q' tmux)$(printf ' %q' -S "$SOCK" "$@")
    ssh -n -i "$KEY" "$TARGET" "$cmd"
  fi
}

# Runs `git -C <path> status --porcelain` for stop-swarm.sh's DIRTY-worktree
# check (issue #11). Same shape as tmux_remote and for the same reason: LOCAL
# execs git directly with no shell in the middle, so argv needs no escaping;
# remote mode crosses one ssh exec that reparses a single string, so each
# argument is %q-quoted before joining — a worktree path out of roles.tsv is
# exactly the kind of free text tmux_remote's own comment warns about, not
# something to hand-interpolate into a shell string.
git_status() { # $1 = worktree path (as recorded in roles.tsv)
  if [ "$LOCAL" = 1 ]; then
    git -C "$1" status --porcelain
  else
    local cmd
    cmd=$(printf '%q' git)$(printf ' %q' -C "$1" status --porcelain)
    ssh -n -i "$KEY" "$TARGET" "$cmd"
  fi
}

# Runs `git -C <ROOT> merge-base --is-ancestor <commit> origin/main` for
# accept-work.sh's already-shipped exclusion (issue #17). Unlike git_status,
# this always runs at ROOT itself, never a worktree path: origin/main is a
# property of the whole project repo, not any one worktree, and it means the
# MANAGED PROJECT's own origin/main — a completely different repo than
# swarm-forge's. Same LOCAL/remote shape as git_status and for the same
# reason: a commit hash parsed out of a handoff file is exactly the
# untrusted free text tmux_remote's own comment warns about, so it is
# %q-quoted before crossing the single ssh-reparsed string, never
# hand-interpolated. Exit status is git's own: 0 = ancestor (already
# shipped), 1 = not an ancestor, anything else = could not be confirmed —
# callers must treat "not confirmed" the same as "not shipped" (report it),
# never suppress a completed task just because the check itself failed.
git_merge_base_ancestor() { # $1 = commit
  if [ "$LOCAL" = 1 ]; then
    git -C "$ROOT" merge-base --is-ancestor "$1" origin/main
  else
    local cmd
    cmd=$(printf '%q' git)$(printf ' %q' -C "$ROOT" merge-base --is-ancestor "$1" origin/main)
    ssh -n -i "$KEY" "$TARGET" "$cmd"
  fi
}

# Runs $2.. as a backgrounded, nohup'd command against $TARGET/local, for
# start-swarm.sh's launch step (issue #26) — the counterpart to tmux_remote/
# git_status, but for a command whose whole point is to keep running after
# this function returns. Never waits on the child; the caller's own
# readiness poll is what confirms it actually came up. Each remote argv
# element is %q-quoted before joining into the single ssh command string,
# same reasoning as tmux_remote's own comment: a launcher path or env value
# is untrusted free text, never hand-interpolated.
#
# `</dev/null` on the backgrounded command guards a DIFFERENT scenario than
# the hang described below: it stops the detached child from ever reading a
# caller's own stdin if start-swarm.sh itself is invoked with something
# piped into it. Good hygiene, but a 4-variant empirical reproduction (done
# while re-verifying this fix) confirmed `</dev/null` is NOT what fixes the
# hang below — removing the subshell wrapper alone does.
#
# LOCAL never wraps the launch in a subshell or `bash -c` — `cd`/`nohup ...
# &` run directly at this function's own top level, `cd`-ing back
# afterward. That IS load-bearing: this session empirically found that a
# `(...)` subshell around the backgrounded command leaks an inherited
# duplicate of a caller's `$(...)` pipe-write-end fd into the detached
# child, on bash 3.2 (macOS's stock /bin/bash) — a caller capturing this
# script's combined output via real command substitution
# (`$(start-swarm.sh ... 2>&1)`) then blocks until that fd's last holder
# (the detached child) closes it, i.e. for as long as the launched swarm
# keeps running. Running the redirected, nohup'd command directly at this
# function's own top level, with no subshell/`bash -c`/`eval` layer in
# between, is what avoids that leak.
run_detached() { # $1 = absolute log path, rest = argv to run detached
  local log=$1; shift
  if [ "$LOCAL" = 1 ]; then
    mkdir -p "$(dirname "$log")"
    local prev; prev=$(pwd)
    cd "$ROOT"
    nohup "$@" </dev/null >>"$log" 2>&1 &
    cd "$prev"
  else
    # Remote crosses ssh's own channel, not a raw inherited pipe — this
    # session verified by hand (twice) that a real `ssh ... 'cd ROOT &&
    # nohup CMD >LOG 2>&1 &'` genuinely detaches and returns promptly;
    # ssh's channel-close semantics are not the local pipe-fd quirk above,
    # so the subshell-avoidance rule doesn't apply to this branch.
    local q_argv q_log q_root
    q_argv=$(printf '%q ' "$@")
    q_log=$(printf '%q' "$log")
    q_root=$(printf '%q' "$ROOT")
    ssh -n -i "$KEY" "$TARGET" \
      "mkdir -p \$(dirname $q_log) && cd $q_root && nohup $q_argv </dev/null >>$q_log 2>&1 &"
  fi
}

# ---------- project lock (issue #29: exclude start/update from interleaving
# on one managed project) ----------
# mkdir-based, no staleness/heartbeat/TTL judgment anywhere — a design
# decision already closed by an adversarial review (see issue #29's
# "Locking"/"Further Notes"): a held lock is held, full stop, regardless of
# age. The operator's only way to clear one left by a dead/killed holder is
# an explicit --force at the call site (see start-swarm.sh), never anything
# automatic in here. Lock dir: $ROOT/.swarmforge/update-lock. Holder file:
# $ROOT/.swarmforge/update-lock/holder, plain text, one line, the verb name
# ("start" or "update") that acquired it.
LOCKDIR=.swarmforge/update-lock

# $1 = holder name ("start" or "update"). On success, the lock dir now
# exists with its holder file written, and this returns 0. On an
# already-held lock, returns 1 and sets LOCK_HOLDER to the existing holder
# file's contents, for the caller to name in its own UNSAFE message.
# Returns 2 when the runtime parent could not be created at all — a
# filesystem or permission failure, which the caller reports as ERROR/5.
# Stealing a held lock (removing it and re-acquiring) is the CALLER's job
# via release_lock + a retry, driven by --force — this function only ever
# reports contention, never clears it itself. Same LOCAL/remote dual-mode
# shape as tmux_remote/git_status: LOCAL runs mkdir directly (no shell in
# the middle), remote builds one %q-quoted command string and ships it in a
# single ssh call — never hand-interpolating $ROOT into a raw ssh string.
#
# The parent is created first, and deliberately with `mkdir -p` while the
# lock dir itself stays a bare `mkdir` (issue #35). A freshly onboarded
# project has no `.swarmforge/` at all yet — onboarding installs the Pack and
# stops. Without this, the bare mkdir failed for a missing parent, the holder
# read then found nothing, and a genuinely fresh project was reported as
# contention with an EMPTY holder name: "lock held by ''". The lock dir keeps
# its bare mkdir because that failure-when-it-exists IS the atomic test; only
# the parent is made idempotently.
acquire_lock() {
  local holder=$1
  if [ "$LOCAL" = 1 ]; then
    mkdir -p "$ROOT/.swarmforge" 2>/dev/null || return 2
    if mkdir "$ROOT/$LOCKDIR" 2>/dev/null; then
      printf '%s\n' "$holder" > "$ROOT/$LOCKDIR/holder"
      return 0
    fi
    LOCK_HOLDER=$(cat "$ROOT/$LOCKDIR/holder" 2>/dev/null)
    return 1
  else
    local cmd out rc
    # exit 3 distinguishes "could not make the parent" from mkdir's own
    # "already exists" contention path, so the two do not collapse into one
    # indistinguishable non-zero status after the ssh hop.
    cmd="mkdir -p $(printf '%q' "$ROOT/.swarmforge") 2>/dev/null || exit 3; if mkdir $(printf '%q' "$ROOT/$LOCKDIR") 2>/dev/null; then printf '%s\n' $(printf '%q' "$holder") > $(printf '%q' "$ROOT/$LOCKDIR/holder"); else cat $(printf '%q' "$ROOT/$LOCKDIR/holder") 2>/dev/null; exit 1; fi"
    if out=$(ssh -n -i "$KEY" "$TARGET" "$cmd"); then
      return 0
    fi
    rc=$?
    [ "$rc" = 3 ] && return 2
    LOCK_HOLDER=$out
    return 1
  fi
}

# Removes the lock directory. Best effort, never dies — callers wire this
# into their own `trap ... EXIT` (see start-swarm.sh), which must not itself
# abort a script that is already exiting. Same LOCAL/remote dual-mode shape
# as the rest of this file. No return-value contract beyond "tried."
release_lock() {
  if [ "$LOCAL" = 1 ]; then
    rm -rf "$ROOT/$LOCKDIR" 2>/dev/null || true
  else
    local cmd
    cmd=$(printf '%q' rm)$(printf ' %q' -rf "$ROOT/$LOCKDIR")
    ssh -n -i "$KEY" "$TARGET" "$cmd" 2>/dev/null || true
  fi
}

# ---------- scripts digest + manifest (issue #29: drift detection between
# a managed project's installed swarmforge/scripts/ and its own identity
# manifest) ----------

# $1 = optional file path; omitted reads stdin. Prints just the hex digest
# to stdout. macOS ships no sha256sum, only `shasum -a 256`; a typical Linux
# ssh target has sha256sum — prefer it, fall back to shasum -a 256. Both
# accept a path arg or stdin and both print "<hex>  <name>", hence the
# `awk '{print $1}'` trim. Shipped verbatim (not re-derived) inside
# remote_scripts_digest's embedded ssh snippet below, so there is exactly
# one algorithm to reason about.
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  else
    shasum -a 256 "$@" | awk '{print $1}'
  fi
}

# $1 = directory to digest. LOCAL-only — operates on a path already
# resolved to be on the current machine; remote_scripts_digest below ships
# this identical logic across ssh when LOCAL=0. Deterministic
# content+executable-bit digest over a scripts tree (issue #29): for every
# regular file under $1 (recursively; dotfiles and empty directories get no
# special-casing — find -type f already only ever yields files), one line
# "<relative-path> <x-or-dash> <sha256-of-contents>", sorted by relative
# path, concatenated and sha256'd again as a whole. Relative to $1 itself
# (not the caller's absolute location) with `/` separators, so the digest
# doesn't change between the operator's source checkout and a managed
# project's install path. Timestamps, directory order, and a trailing `/`
# on $1 itself never affect it — `dir=${dir%/}` strips one up front so the
# `${f#"$dir"/}` prefix-strip below always matches find's single-slash
# output, whether the caller passed ".../scripts" or ".../scripts/".
# The trailing `|| true` neutralizes `set -o pipefail` turning a merely
# EMPTY tree (find matches nothing, or the empty `while read` loop's own
# exit status) into a spurious failure under this file's callers' `set -e`
# — the digest of an empty tree is still a valid, deterministic value, not
# an error.
scripts_digest() {
  local dir=$1 f rel x
  dir=${dir%/}
  { find "$dir" -type f 2>/dev/null || true; } | LC_ALL=C sort | while IFS= read -r f; do
    rel=${f#"$dir"/}
    [ -x "$f" ] && x=x || x=-
    printf '%s %s %s\n' "$rel" "$x" "$(sha256_hex "$f")"
  done | sha256_hex || true
}

# $1 = directory to digest (on $TARGET when LOCAL=0, otherwise the current
# machine). Dual-mode wrapper (issue #29): start-swarm.sh only ever needs
# to digest a MANAGED PROJECT's own already-installed swarmforge/scripts,
# never the operator's own source checkout, so this is the only digest
# entry point start-swarm.sh calls. LOCAL runs scripts_digest directly;
# remote ships the identical algorithm across one ssh call, same
# run_detached/tmux_remote shape (one %q-quoted command string, single ssh
# call, no hand-interpolated $dir). The embedded snippet below is
# copy-pasted line-for-line from sha256_hex/scripts_digest above, not
# re-derived, so a remote digest and a local digest of the same tree can
# never drift apart by implementation accident.
remote_scripts_digest() {
  local dir=$1
  if [ "$LOCAL" = 1 ]; then
    scripts_digest "$dir"
  else
    local snippet cmd
    snippet=$(cat <<'EOS'
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  else
    shasum -a 256 "$@" | awk '{print $1}'
  fi
}
dir=$1
dir=${dir%/}
{ find "$dir" -type f 2>/dev/null || true; } | LC_ALL=C sort | while IFS= read -r f; do
  rel=${f#"$dir"/}
  [ -x "$f" ] && x=x || x=-
  printf '%s %s %s\n' "$rel" "$x" "$(sha256_hex "$f")"
done | sha256_hex || true
EOS
)
    cmd=$(printf '%q' bash)$(printf ' %q' -c "$snippet" bash "$dir")
    ssh -n -i "$KEY" "$TARGET" "$cmd"
  fi
}

# Manifest READER (issue #29; the WRITER belongs to the `update SwarmForge
# scripts` verb, a sibling task — this function nails down the exact
# on-disk format the writer must match byte-for-byte). Path:
# $ROOT/.swarmforge/scripts-manifest — a plain file, sibling to
# .swarmforge/sessions.tsv etc., outside the digested swarmforge/scripts/
# tree so digest computation is never self-referential. Format: plain
# KEY=value lines, one per line, no quoting (this codebase's existing
# runtime-file convention, not JSON). Required keys: SOURCE_COMMIT=<sha>,
# SOURCE_REPO=<best-effort identity, or the literal string "unknown">,
# DIGEST=<sha256 hex from scripts_digest>. Key order does not matter to
# this reader and extra keys are ignored — it only ever looks for DIGEST=,
# the only field start-swarm.sh needs.
#
# Reads via read_file (already handles LOCAL/remote). On success, PRINTS
# the digest value to stdout and returns 0 — callers capture it by command
# substitution (`MANIFEST_DIGEST=$(read_manifest)`), exactly like every
# other value this file's callers pull out of a runtime file. A missing
# manifest, or one with no DIGEST= line, is NOT an error at this function's
# level: it returns 1 and prints nothing, leaving "missing manifest" as the
# caller's own DRIFT case (a legacy managed project without a manifest is
# DRIFT even if an incidental byte comparison would appear equal — issue
# #29).
read_manifest() {
  local raw line
  raw=$(read_file .swarmforge/scripts-manifest 2>/dev/null) || return 1
  while IFS= read -r line; do
    case $line in
      DIGEST=*) printf '%s\n' "${line#DIGEST=}"; return 0 ;;
    esac
  done <<< "$raw"
  return 1
}

# ---------- report-verb classification (issue #15, shared per issue #11) ----
# Moved here from read-swarm.sh so stop-swarm.sh's preflight reads a role's
# BUSY/IDLE/UNKNOWN state exactly the way `read swarm` does — the issue #11
# acceptance criterion is that the two judgments never drift apart, which a
# second copy of this logic could not guarantee.
#
# BUSY: the "esc to interrupt" hint tied to codex's interruptible-work banner
# ("Working (44s • esc to interrupt)"), or the "<participle> for Ns" shape of
# claude's spinner line ("Baked for 13s", "Cogitated for 28s"). The spinner
# glyph itself is skipped as a marker — unicode chrome a font/terminal may not
# round-trip byte-for-byte; the text shape after it is the stable part.
# IDLE: a bare prompt character with nothing else on the line (claude's empty
# input line), or the literal placeholder text inviting input ("Ask Codex to
# do anything").
BUSY_RE='esc to interrupt|[A-Za-z]+(ed|ing) for [0-9]+s'
IDLE_RE='^(❯|>)[[:space:]]*$|Ask .* to do anything'

classify() { # $1 = last non-empty pane line ("" for a blank pane)
  if [ -z "$1" ]; then echo UNKNOWN
  elif printf '%s' "$1" | grep -qE "$BUSY_RE"; then echo BUSY
  elif printf '%s' "$1" | grep -qE "$IDLE_RE"; then echo IDLE
  else echo UNKNOWN
  fi
}

# Looks up $1 in sessions.tsv (columns: index, role, session, display,
# agent). Sets SESSION/AGENT on success; returns 1 if the role has no row —
# never accepts backend from the caller, sessions.tsv is the only source.
resolve_role() {
  local row
  row=$(printf '%s\n' "$SESSIONS" | awk -F'\t' -v r="$1" '$2 == r {print $3"\t"$5; exit}')
  [ -n "$row" ] || return 1
  SESSION=${row%%$'\t'*}
  AGENT=${row#*$'\t'}
}

# Timeout budgets (overridable for tests, same trick as handoffd.bb's
# SWARMFORGE_WAKE_RETRY_MS): arrival is typing landing in the input line,
# which is near-instant once the pane exists, so a few seconds covers normal
# jitter. Consumption is the submit key actually being processed — an agent
# mid-thought can leave keystrokes queued in the terminal buffer for longer,
# so that budget runs three times as long.
ARRIVAL_TRIES=${SF_ARRIVAL_TRIES:-10}
ARRIVAL_INTERVAL=${SF_ARRIVAL_INTERVAL:-0.3}
CONSUME_TRIES=${SF_CONSUME_TRIES:-20}
CONSUME_INTERVAL=${SF_CONSUME_INTERVAL:-0.5}

pane_has() { tmux_remote capture-pane -p -t "$SESSION" | grep -qF -- "$1"; }

# Whole-pane presence, scoped to the pane's LAST NON-EMPTY LINE — same
# extraction read-swarm.sh's classification loop uses before calling
# classify() (issue #15). The input line is always that last non-empty
# line; once a backend redraws with new content below the submitted text
# (transcript echo, a busy marker, the next prompt — anything), the text
# stops being the last line even though whole-pane `pane_has` still finds
# it higher up in scrollback. `|| true` matches read-swarm.sh's own guard:
# grep exits 1 on no match, which would otherwise trip `set -o pipefail`.
last_line_has() {
  local last
  last=$(tmux_remote capture-pane -p -t "$SESSION" | grep -v '^$' | tail -1 || true)
  printf '%s' "$last" | grep -qF -- "$1"
}

# Type $1, confirm it arrived, submit with the backend's own key encoding
# (never symbolic C-m/C-j — see submit-keys in handoffd.bb), then confirm
# the text is no longer the pane's last non-empty line. Dies ERROR/5 on
# either failure to wait.
#
# issue #28: consumption used to be judged by whole-pane `pane_has`, which
# stays true forever on backends (Grok observed live on podsum) that move
# submitted text into persisted transcript history rather than erasing it —
# a false negative on a message that was actually sent and already running.
# last_line_has is immune to that: history sitting above the last line
# doesn't matter, only whether the text is still what's currently in the
# editable input position. This also naturally covers the issue's "输入框为
# 空或 role 已进入 BUSY" success condition — both a cleared input line and a
# BUSY marker redraw change the last line away from $text, so no separate
# classify()/BUSY_RE check is needed here; that classifier is documented
# (SKILL.md, `read swarm`'s boundary paragraph) as intentionally incomplete
# across backends and would just trade one false negative for another.
#
# Residual assumption, inherited from that same read-swarm.sh convention:
# a backend that renders a static footer/hint line below the input — one
# that never contains the input and doesn't change on submit — would make
# last_line_has report "consumed" on the very first poll, whether or not
# the submit key actually landed. No currently supported backend does
# this; if one ever does, this is the false positive to watch for.
send_and_verify() {
  local text=$1 i
  tmux_remote send-keys -t "$SESSION" -l "$text"
  for ((i = 0; i < ARRIVAL_TRIES; i++)); do
    pane_has "$text" && break
    sleep "$ARRIVAL_INTERVAL"
  done
  pane_has "$text" || die ERROR \
    "text never appeared in $SESSION's input line; check the tmux session is alive" 5

  if [ "$AGENT" = claude ]; then
    tmux_remote send-keys -t "$SESSION" -H 1b 5b 31 33 75
  else
    tmux_remote send-keys -t "$SESSION" -H 0d
  fi

  for ((i = 0; i < CONSUME_TRIES; i++)); do
    last_line_has "$text" || return 0
    sleep "$CONSUME_INTERVAL"
  done
  die ERROR \
    "text reached $SESSION's input line but was never submitted — check sessions.tsv's backend ($AGENT) against the agent actually running in that session" 5
}
