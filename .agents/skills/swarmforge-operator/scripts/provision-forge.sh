#!/usr/bin/env bash
# provision-forge.sh — provision forge (issue #144): one verb for upstream
# README steps 2-4 — install a forge into an empty directory, start it, and
# create its first project. Step 5 (New Task) is deliberately NOT here: cards
# are cut in the Dashboard or by the Host lieutenant.
#
# Exit codes / STATUS line:
#   0 PROVISIONED   2 USAGE   4 DRIFT   5 ERROR   6 UNSAFE
# Contract details live in ../SKILL.md (verb: provision forge).
#
# Usage: provision-forge.sh --root <forge-root> \
#   --forge <project-manager|lieutenant> --dashboard-port <N> \
#   [--project <name> [--pack <two-pack|four-pack|six-pack>]] \
#   [--mission <text>] [--terminal <value>] \
#   [--target user@host] [--key <path>] [--local]
#
# Three traps this script exists to absorb, none of which upstream's README
# can warn about because upstream does not have them:
#
# 1. SOURCE. The README's helper URL points at unclebob/swarm-forge. A forge
#    installed from that tree has neither D-1 (inbox resolved from roles.tsv)
#    nor D-5 (handoffd reconciliation and retry), so its handoff chain
#    deadlocks SILENTLY when a wake keystroke is swallowed by a TUI. See
#    ADR-0001/ADR-0002. This script therefore installs from this fork AND
#    proves it afterwards from file CONTENT — "I passed the right URL" is not
#    evidence.
# 2. LAUNCH. `./swarm` run bare from an ssh session lets
#    detect-terminal-backend pick terminal-app (osascript exists) with no real
#    window behind it, and the window watchdog tears the whole forge down
#    within seconds (issue #10, reproduced twice by hand). So the launch is
#    delegated to start-swarm.sh, never hand-rolled as ssh + nohup ./swarm &.
# 3. MANIFEST. get-swarm-forge installs swarmforge/scripts/ but writes no
#    .swarmforge/scripts-manifest, so start-swarm.sh reads INCOMPLETE and
#    refuses with 4 DRIFT — making --force the only way to start ANY forge,
#    which also switches off issue #29's digest check. ADR-0006 puts that
#    responsibility here: the verb that installs the tree writes the manifest
#    describing it. Neither get-swarm-forge nor start-swarm.sh is modified.
#
# Depends on the target having zsh (get-swarm-forge's shebang), curl, tar and
# git, plus the ssh/tmux machinery start-swarm.sh already requires.
#
# SWARMFORGE_REPO_URL is deliberately NOT forwarded to get-swarm-forge.
# Pointing the install at another tree would only fail the source check below,
# so offering the knob here would be offering a footgun. Someone who genuinely
# wants another tree runs get-swarm-forge themselves.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-wake-talk.sh"

TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT='' FORGE='' TERMINAL=none DASHBOARD_PORT='' PROJECT='' PACK='' MISSION=''
LOCAL=0 HAVE_MISSION=0

# Overridable so tests can install from a file:// URL instead of the network.
# The default is this fork's raw helper, never upstream's (trap 1 above).
HELPER_URL=${SWARMFORGE_HELPER_URL:-https://raw.githubusercontent.com/arlishansenn/swarm-forge/main/get-swarm-forge}

FORGE_VALUES='project-manager lieutenant'
PACK_VALUES='two-pack four-pack six-pack'
# Same canonical set as start-swarm.sh, which is where --terminal is actually
# consumed. Duplicated rather than derived for the same reason given there:
# deriving it would cost a round trip on every invocation.
TERMINAL_VALUES='ghostty iterm2 none terminal-app windows-terminal auto'

usage() { printf 'STATUS=USAGE\n'; sed -n '2,15p' "$0" >&2; exit 2; }
usage_error() { printf 'STATUS=USAGE\n%s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --root) [ $# -ge 2 ] || usage_error "--root requires a value"; ROOT=$2; shift 2 ;;
    --forge) [ $# -ge 2 ] || usage_error "--forge requires a value"; FORGE=$2; shift 2 ;;
    --terminal) [ $# -ge 2 ] || usage_error "--terminal requires a value"; TERMINAL=$2; shift 2 ;;
    --dashboard-port) [ $# -ge 2 ] || usage_error "--dashboard-port requires a value"; DASHBOARD_PORT=$2; shift 2 ;;
    --project) [ $# -ge 2 ] || usage_error "--project requires a value"; PROJECT=$2; shift 2 ;;
    --pack) [ $# -ge 2 ] || usage_error "--pack requires a value"; PACK=$2; shift 2 ;;
    # A mission may legitimately be empty, so presence is tracked separately
    # from emptiness — forge/instantiate! only skips mission.md when the key
    # is absent (nil), not when it is "".
    --mission) [ $# -ge 2 ] || usage_error "--mission requires a value"; MISSION=$2; HAVE_MISSION=1; shift 2 ;;
    --target) [ $# -ge 2 ] || usage_error "--target requires a value"; TARGET=$2; shift 2 ;;
    --key) [ $# -ge 2 ] || usage_error "--key requires a value"; KEY=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    *) usage ;;
  esac
done

[ -n "$ROOT" ] || usage_error "--root is required"
[ -n "$FORGE" ] || usage_error "--forge is required"
case " $FORGE_VALUES " in *" $FORGE "*) ;; *)
  usage_error "--forge must be one of: $FORGE_VALUES" ;; esac
case " $TERMINAL_VALUES " in *" $TERMINAL "*) ;; *)
  usage_error "--terminal must be one of: $TERMINAL_VALUES" ;; esac
# Required, not defaulted. pack_web binds a random port when nothing is
# exported, and a random port has no stable URL to publish on a tailnet — so
# `dashboard --tailnet` could never reach a forge provisioned without one.
# Only the SHAPE is checked; which ports a host hands out is that host's own
# convention (see SKILL.md's port table, which nothing derives or enforces).
[ -n "$DASHBOARD_PORT" ] || usage_error "--dashboard-port is required — a random port cannot be published on a tailnet"
case $DASHBOARD_PORT in *[!0-9]*) usage_error "--dashboard-port must be digits" ;; esac

# $ROOT, $PROJECT and $PACK all cross an ssh hop as %q-quoted arguments, and
# $PROJECT additionally becomes a path segment and a JSON value. Reject the
# characters that make any of those ambiguous rather than trying to escape
# them in three different grammars.
case $ROOT in *"'"*) usage_error "--root must not contain a single quote" ;; esac
case $ROOT in /*) ;; *) usage_error "--root must be an absolute path on the target" ;; esac

if [ -n "$PROJECT" ]; then
  case $PROJECT in
    *[!A-Za-z0-9._-]*) usage_error "--project may only contain letters, digits, dot, underscore and hyphen" ;;
    .*) usage_error "--project must not start with a dot" ;;
  esac
  if [ -z "$PACK" ]; then
    # A lieutenant forge has exactly one project template
    # (.swarmforge/project-pack) and its forge.bb pack-dir ignores the pack
    # name entirely, so requiring a choice there would be asking for an answer
    # that is thrown away. instantiate! still rejects a blank pack, hence the
    # placeholder.
    if [ "$FORGE" = lieutenant ]; then PACK=project-pack
    else usage_error "--project needs --pack (one of: $PACK_VALUES)"; fi
  elif [ "$FORGE" != lieutenant ]; then
    case " $PACK_VALUES " in *" $PACK "*) ;; *)
      usage_error "--pack must be one of: $PACK_VALUES" ;; esac
  fi
elif [ -n "$PACK" ]; then
  usage_error "--pack without --project has nothing to create"
fi

# WARN lines are part of a SUCCESSFUL run's report (see SKILL.md's verb
# contract), and STATUS must be the first line printed, so they are collected
# and emitted at the end rather than as they are discovered. A failing run
# reports through die() instead; its one-sentence reason is what matters
# there.
WARNS=()
warn() { WARNS+=("$1"); }
emit_warns() {
  [ ${#WARNS[@]} -eq 0 ] && return 0
  local w
  for w in "${WARNS[@]}"; do printf 'WARN=%s\n' "$w"; done
}

# Same LOCAL/remote split as lib-wake-talk.sh's helpers. `-n` on every ssh is
# D-8: an ssh that inherits this script's stdin can silently eat a caller's
# input.
remote() { # $1 = command string (already %q-quoted by the caller)
  if [ "$LOCAL" = 1 ]; then bash -c "$1"; else ssh -n -i "$KEY" "$TARGET" "$1"; fi
}
q() { printf '%q' "$1"; }

# ---------- stage 1: install ----------
# Three shapes, told apart before anything is written:
#   absent/empty  -> install
#   swarm + swarmforge/scripts present -> already installed, skip
#   anything else -> a torn install, or somebody's directory. Refuse.
# The third case is a write-boundary guard, not a state machine: composing a
# forge into a directory that already holds unrelated files is not a step this
# verb can undo, and get-swarm-forge would happily do it.
INSTALLED=0
ROOT_STATE=$(remote "if [ ! -e $(q "$ROOT") ]; then echo absent;
  elif [ ! -d $(q "$ROOT") ]; then echo notdir;
  elif [ -e $(q "$ROOT/swarm") ] && [ -d $(q "$ROOT/swarmforge/scripts") ]; then echo installed;
  elif [ -z \"\$(ls -A $(q "$ROOT") 2>/dev/null)\" ]; then echo empty;
  else echo occupied; fi") || die ERROR "cannot inspect $ROOT on the target — check the path, the host and the ssh key" 5

case $ROOT_STATE in
  installed) INSTALLED=1 ;;
  notdir) die UNSAFE "$ROOT exists and is not a directory; nothing was changed" 6 ;;
  occupied) die UNSAFE "$ROOT is not empty and has no complete forge install (no ./swarm plus swarmforge/scripts) — clear it or pick another root; nothing was changed" 6 ;;
  absent|empty) ;;
  *) die ERROR "unexpected state '$ROOT_STATE' for $ROOT" 5 ;;
esac

if [ "$INSTALLED" = 1 ]; then
  warn "$ROOT already had a forge installed — install skipped, nothing was re-downloaded"
else
  # The helper is fetched into a temp dir and run with cwd = $ROOT, because
  # get-swarm-forge composes into the CURRENT directory. It is never left
  # behind on the target: a stale copy is one more thing that can drift from
  # the fork.
  #
  # Its output is held, not streamed. get-swarm-forge ends with a chatty
  # "Run ./swarm to start the dashboard" line, and letting that reach stdout
  # puts it AHEAD of this verb's STATUS= line — the one thing the verb
  # contract says must come first. On failure the held output is what tells
  # the operator what broke, so it goes to stderr there.
  INSTALL_LOG=$(mktemp)
  if ! remote "set -e
    mkdir -p $(q "$ROOT")
    tmp=\$(mktemp -d)
    trap 'rm -rf \"\$tmp\"' EXIT
    curl -fsSL $(q "$HELPER_URL") -o \"\$tmp/get-swarm-forge\"
    chmod +x \"\$tmp/get-swarm-forge\"
    cd $(q "$ROOT")
    \"\$tmp/get-swarm-forge\" $(q "$FORGE")" >"$INSTALL_LOG" 2>&1; then
    cat "$INSTALL_LOG" >&2
    rm -f "$INSTALL_LOG"
    die ERROR "installing $FORGE into $ROOT failed — see the output above; $ROOT may hold a partial tree, clear it before retrying" 5
  fi
  rm -f "$INSTALL_LOG"
fi

# ---------- stage 1b: prove the source, from content ----------
# Two markers, one per fork delta, both checked BEFORE the launcher is ever
# called. File EXISTENCE is not a discriminator: upstream ships handoffd.bb
# and handoff_lib.bb too, with different contents.
#
# Ceiling, named rather than hidden: two markers are not a whole-tree
# equivalence proof. If upstream ever grows a function by the same name this
# check calls an upstream tree a fork tree. Proving equivalence properly means
# re-downloading this fork's branch and comparing digests — one extra download
# on every run, for a failure mode that has not happened yet. Swap it in when
# a marker actually goes stale.
remote "grep -q 'reconcile-once!' $(q "$ROOT/swarmforge/scripts/handoffd.bb") \
        && grep -q 'roles.tsv' $(q "$ROOT/swarmforge/scripts/handoff_lib.bb")" 2>/dev/null \
  || die ERROR "the script snapshot in $ROOT is not this fork's: handoffd.bb lacks reconcile-once! (D-5) or handoff_lib.bb lacks roles.tsv (D-1). A forge built on that tree deadlocks silently on a swallowed wake key. Nothing was started." 5

# ---------- stage 1c: the manifest (ADR-0006) ----------
# Written only when ABSENT. A manifest that exists and disagrees with the tree
# is real drift and belongs to start-swarm.sh to report — overwriting it here
# would erase exactly the signal issue #29 built.
if read_manifest >/dev/null 2>&1; then
  :
else
  DIGEST=$(remote_scripts_digest "$ROOT/swarmforge/scripts")
  [ -n "$DIGEST" ] || die ERROR "could not digest $ROOT/swarmforge/scripts; refusing to write a manifest that describes nothing" 5
  # SOURCE_COMMIT is unknown by construction: get-swarm-forge installs from a
  # branch tarball, which carries no commit id. read_manifest only ever reads
  # DIGEST=; the other two lines are provenance for humans.
  # Trailing newline included: $(...) strips it, so it is added back by the
  # printf that writes the file rather than carried in the variable.
  MANIFEST=$(printf 'SOURCE_COMMIT=unknown\nSOURCE_REPO=%s#%s\nDIGEST=%s' "$HELPER_URL" "$FORGE" "$DIGEST")
  remote "mkdir -p $(q "$ROOT/.swarmforge") && printf '%s\n' $(q "$MANIFEST") > $(q "$ROOT/.swarmforge/scripts-manifest")" \
    || die ERROR "could not write $ROOT/.swarmforge/scripts-manifest" 5
  [ "$INSTALLED" = 1 ] && warn "$ROOT had no scripts-manifest — wrote one for the installed tree, nothing was re-downloaded"
fi

# ---------- stage 2: start ----------
# The same liveness question every other verb asks: read tmux-socket, then
# probe the server behind it. A socket FILE with no server is stopped, not
# running.
RUNNING=0
if SOCK=$(read_file .swarmforge/tmux-socket 2>/dev/null); then
  SOCK=${SOCK%$'\n'}
  tmux_remote list-sessions >/dev/null 2>&1 && RUNNING=1
fi

if [ "$RUNNING" = 1 ]; then
  warn "a swarm was already running at $ROOT — start skipped, no second daemon was launched"
else
  START_ARGS=(--root "$ROOT" --terminal "$TERMINAL" --dashboard-port "$DASHBOARD_PORT")
  if [ "$LOCAL" = 1 ]; then START_ARGS+=(--local)
  else START_ARGS+=(--target "$TARGET" --key "$KEY"); fi
  # Never --force. The whole point of stage 1c is that a forge no longer needs
  # it.
  #
  # Output goes to a file rather than $(...): start-swarm.sh detaches a child
  # that can inherit a command-substitution pipe's write end on bash 3.2, and
  # the capturing caller then blocks for as long as the launched swarm lives
  # (see run_detached's comment in lib-wake-talk.sh).
  SS_OUT=$(mktemp)
  SS_RC=0
  "$HERE/start-swarm.sh" "${START_ARGS[@]}" >"$SS_OUT" 2>&1 || SS_RC=$?
  if [ "$SS_RC" != 0 ]; then
    # start-swarm.sh's own STATUS line is already the first line of that file,
    # and its exit code already means the right thing in this shared table, so
    # it is passed through rather than re-labelled.
    cat "$SS_OUT"
    rm -f "$SS_OUT"
    exit "$SS_RC"
  fi
  rm -f "$SS_OUT"
fi

# ---------- readiness: the dashboard's HTTP port ----------
# start-swarm.sh's readiness proves a tmux server answers. It does NOT prove
# pack_web is listening, and POSTing to a port nothing has bound yet is how a
# verb reports a project it never created. Budget copied from
# open-dashboard.sh's tunnel handshake (20 x 0.5s) because it waits on the
# same thing: one TCP handshake against an already-launched server.
DASH_TRIES=${SF_DASH_TRIES:-20}
DASH_INTERVAL=${SF_DASH_INTERVAL:-0.5}
URL='' PORT=''
for _ in $(seq 1 "$DASH_TRIES"); do
  if URL=$(read_file .swarmforge/dashboard-url 2>/dev/null); then
    URL=${URL%$'\n'}
    if [ -n "$URL" ]; then
      PORT=$(printf '%s' "$URL" | sed -n 's#^http://127\.0\.0\.1:\([0-9][0-9]*\)/\{0,1\}$#\1#p')
      # curl runs ON THE TARGET: pack_web binds 127.0.0.1 there on purpose,
      # and reaching it from this machine would mean exposing it. Host-local
      # self-access is not exposure; this verb creates no tunnel, no proxy and
      # no tailscale serve config.
      if [ -n "$PORT" ] && remote "curl -s -o /dev/null --max-time 3 -w '%{http_code}' $(q "http://127.0.0.1:$PORT/")" 2>/dev/null | grep -qx 200; then
        break
      fi
    fi
  fi
  URL='' PORT=''
  sleep "$DASH_INTERVAL"
done

if [ -z "$PORT" ]; then
  if [ -n "$PROJECT" ]; then
    die ERROR "the forge at $ROOT is up but its dashboard never answered on 127.0.0.1 within $(printf '%sx%ss' "$DASH_TRIES" "$DASH_INTERVAL") — project '$PROJECT' was NOT created; check $ROOT/.swarmforge/dashboard.log, then re-run this same command" 5
  fi
  die ERROR "the forge at $ROOT is up but its dashboard never answered on 127.0.0.1 within $(printf '%sx%ss' "$DASH_TRIES" "$DASH_INTERVAL") — check $ROOT/.swarmforge/dashboard.log" 5
fi

report() { # $1.. extra KEY=value lines
  printf 'STATUS=PROVISIONED\nROOT=%s\nFORGE=%s\nURL=%s\nTARGET=%s\n' \
    "$ROOT" "$FORGE" "$URL" "$([ "$LOCAL" = 1 ] && echo local || echo "$TARGET")"
  [ $# -eq 0 ] || printf '%s\n' "$@"
  emit_warns
}

# ---------- stage 3: the first project ----------
if [ -z "$PROJECT" ]; then
  report
  exit 0
fi

if remote "test -e $(q "$ROOT/projects/$PROJECT")" 2>/dev/null; then
  die UNSAFE "$ROOT/projects/$PROJECT already exists — pick another name, or open the existing one from the dashboard; nothing was changed" 6
fi

if [ "$FORGE" = lieutenant ]; then
  warn "a lieutenant forge has a single project template (.swarmforge/project-pack), so the pack name is not a choice it can act on"
fi

# POST to the running dashboard is the ONLY supported headless path: the
# production pack_web.bb -main understands --serve and nothing else; every
# --test-* flag, including --test-new-project, is dispatched solely by the
# test harness. Going around HTTP and calling forge.bb directly would also
# make this script a second writer against the forge's open-projects state,
# which the running dashboard owns.
#
# The handler is instantiate! followed by open-project!, so a 2xx here means
# the project directory exists AND its swarm has been asked to come up.
BODY=$(python3 -c '
import json, sys
body = {"name": sys.argv[1], "pack": sys.argv[2]}
if sys.argv[3] == "1":
    body["mission"] = sys.argv[4]
print(json.dumps(body))
' "$PROJECT" "$PACK" "$HAVE_MISSION" "$MISSION")

# One remote call returns the status code on the first line and the body
# after it, so a failure can quote what the server actually said instead of
# guessing from the code alone.
POST_OUT=$(remote "tmpf=\$(mktemp)
  code=\$(printf '%s' $(q "$BODY") | curl -sS -o \"\$tmpf\" -w '%{http_code}' --max-time 120 \
    -X POST -H 'Content-Type: application/json' --data-binary @- $(q "http://127.0.0.1:$PORT/api/projects") || echo 000)
  printf '%s\n' \"\$code\"
  cat \"\$tmpf\"
  rm -f \"\$tmpf\"") || die ERROR "could not reach the dashboard at 127.0.0.1:$PORT on the target to create '$PROJECT'; the forge is up, the project was not created" 5

CODE=${POST_OUT%%$'\n'*}
RESP=${POST_OUT#*$'\n'}
[ "$RESP" = "$POST_OUT" ] && RESP=''

case $CODE in
  2*) ;;
  # 409 is the only conflict status this endpoint raises, and it covers both
  # "Project already exists" and "Project already open". The :error keyword in
  # forge.bb's ex-data never reaches the wire — http-error serialises only the
  # message — so the status is the discriminator, not a body field.
  409) die UNSAFE "the forge refused to create '$PROJECT': ${RESP:-conflict} — pick another name, or open the existing one from the dashboard" 6 ;;
  *) die ERROR "creating '$PROJECT' failed with HTTP ${CODE:-none}: ${RESP:-<empty response>}. The forge is up; the project was not created." 5 ;;
esac

report "PROJECT=$PROJECT" "PACK=$PACK" "PROJECT_PATH=$ROOT/projects/$PROJECT"
exit 0
