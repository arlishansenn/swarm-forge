---
name: swarmforge-operator
description: "Use when operating a running SwarmForge project from the local machine: opening its role sessions or its pack_web dashboard in cmux, reading role state, waking or messaging a role, stopping the swarm, or installing an upstream pack (two-pack, four-pack, six-pack) into a new or existing project directory before the swarm has ever run."
---

# SwarmForge Operator

Operate a running SwarmForge project from the local machine. SwarmForge is
config-driven: derive the active topology from the target project's runtime
state instead of branching on two-pack, four-pack, six-pack, or role names.

**REQUIRED SUB-SKILL:** `cmux`. Load it before any cmux operation you perform
yourself (creating a window the user asked for, drift recovery, inspecting a
surface). The bundled `open-swarm.sh` script already follows the cmux contract
internally; do not re-implement its mechanics.

## Runtime inputs

Set the target project for every verb. The macmini values are defaults, not
part of the topology:

```sh
TARGET=${TARGET:-admin@100.64.0.4}
KEY=${KEY:-$HOME/.ssh/tailscale_key}
ROOT=${ROOT:?set ROOT to the remote project root}
SSH=(ssh -i "$KEY" "$TARGET")

SOCK=$("${SSH[@]}" "cat '$ROOT/.swarmforge/tmux-socket'")
SESSIONS=$("${SSH[@]}" "cat '$ROOT/.swarmforge/sessions.tsv'")
ROLES=$("${SSH[@]}" "cat '$ROOT/.swarmforge/roles.tsv'")
MASTER=$(printf '%s\n' "$ROLES" | awk -F '\t' '$2 == "master" {print $1}')
```

Runtime files are the source of truth after launch:

- `tmux-socket`: plain text containing the real socket path. Resolve it again
after every `./swarm` restart.
- `sessions.tsv`: config order, role, session, display name, agent backend.
- `roles.tsv`: role, worktree name/path, session, display name, backend, receive
mode. The row whose worktree name is `master` is the intake role.

Stop if a runtime file is missing, the socket has no sessions, or there is not
exactly one master row. A host can run several projects; only touch state under
`ROOT` and the socket read from that project.

## Verb contract

Every verb is a handover verb, a report verb, or an effect verb (see `CONTEXT.md`).
The kind decides what the verb owes you when it finishes.

**Status line and exit codes.** A scripted verb prints `STATUS=<WORD>` as its first
line. The exit codes have one meaning across all verbs:

- `0` — the verb did its work.
- `2` `USAGE` — bad arguments.
- `3` — the target is not running. Never start it; that is a human decision.
- `4` `DRIFT` — recorded state disagrees with real state. Ask before you repair.
- `5` `ERROR` — the verb failed.
- `6` `UNSAFE` — the verb refused to do destructive work because it found a
  condition that a human must clear first. Nothing was changed.

**A failure says why in plain text.** After the `STATUS=` line, a failed verb prints
one sentence that tells you what to do. There is no machine-readable reason field:
exit codes are what a script branches on, and the sentence is for a person.

**Success can also speak.** A verb that did its work but found something you must
know prints one or more `WARN=<one sentence>` lines and still exits `0`. Only report
a fact that is true for this run and can become false later. A fact that is always
true must be fixed at its cause, not warned about: a warning that appears every time
is a warning that nobody reads.

**A handover verb only contracts up to the handover.** It checks what it can, then
replaces itself with the target program. The exit code after that belongs to that
program, not to this contract.

**Not every verb has a script yet.** `onboard project`, `open swarm`, `dashboard`,
`wake role`, `talk role`, `read swarm`, `stop swarm`, `accept work`,
`start swarm`, and `update SwarmForge scripts` are scripted and follow this
contract today. The other verbs
are shell steps in this file; run them as written and read their raw output.
Bringing them under the contract is tracked in the issue tracker.

## Verb: `onboard project`

Install one upstream pack into a managed project directory. This is the
skill's only creative verb: it lands files and stops.

```sh
scripts/onboard-project.sh --root <project-dir> --pack <two-pack|four-pack|six-pack> [--local]
```

Exit codes / STATUS line:

- `0` `ONBOARDED`
- `2` `USAGE` — missing arguments, or pack not in the whitelist (`main` is
  upstream's documentary branch and never a pack)
- `4` `OCCUPIED` — target already has `swarm` or `swarmforge/`; zero writes
- `5` `ERROR` — download or extract failed; target unchanged

**Boundary:** do not run `./swarm` for the user after onboarding. The three
hard prohibitions stand unchanged: never start, never clean up, never decide
the start time for the user. The script also never touches the target
project's git state — `git init` is the swarm launcher's own first-run
behavior.

## Verb: `open swarm`

Run the bundled script from this skill's directory; it owns all cmux mechanics
(settle, output parsing, workspace reuse, attach verification):

```sh
scripts/open-swarm.sh --root <project-root> [--window <ref>] \
  [--target user@host] [--key <path>] [--local]
```

It reads the runtime files, gates on a live tmux socket, pairs adjacent
sessions from `sessions.tsv` into `<Display 1> + <Display 2>` workspaces (an
odd tail becomes a single-pane workspace), reuses an existing workspace set
matched by description `swarmforge:<basename>@<host>`, re-sends attach to
stale surfaces once, then verifies every surface shows its session.

Read the result from its output and exit code:

- `0` `STATUS=OPENED|REUSED` — report `WORKSPACES`, `ATTACHED`, `REPAIRED`,
  `MASTER_DISPLAY`/`MASTER_WS` to the user. The script leaves the user's
  focus untouched; name where the master lives instead of focusing it.
- `3` `STOPPED` — the swarm is not running. Report the reason and stop. When
  the message names the window watchdog, a human must fix the terminal
  backend before restarting — relaunching as-is repeats the same kill.
- `4` `DRIFT` — cmux state disagrees with runtime files (half-finished run or
  changed topology). Ask the user before closing or re-creating anything.
- `5` `ERROR` — show the message; check cmux state before retrying. Never
  "probe" by re-running a create that may have succeeded.

Hard rules for this verb:

- **Never start a stopped swarm.** No `./swarm`, no restart, no matter how
  likely the user "meant" it. Starting is a human decision; `open` only
  connects to what already runs.
- **No macOS window by default.** The script targets the caller's current
  window. Only when the user explicitly asks for a new window, create it
  yourself per the cmux skill and pass `--window <ref>`.
- **No destructive cleanup without explicit user approval** — the script
  closes nothing, and neither should you.

## Verb: `start swarm`

Run the bundled script; it starts a stopped swarm the deliberate way (issue
#26), the counterpart to `open swarm` refusing to do it automatically
(issue #10). Today's only alternative is a manual `ssh` + `nohup ./swarm &`,
and the exact detail that manual path leaves to memory — the terminal
backend `./swarm` will otherwise auto-detect — is the root cause of the #10
incident: launched from a real terminal-less ssh session, `osascript`
existing was enough for `detect-terminal-backend` to pick `terminal-app`
with no real window behind it, and the window watchdog tore the whole swarm
down within seconds once it couldn't find that window. That failure mode
has reproduced twice under manual operation.

```sh
scripts/start-swarm.sh --root <project-root> --terminal <value> \
  [--target user@host] [--key <path>] [--local] [--force]
```

`--terminal` is **required**, not an optional env passthrough — unlike
`stop swarm`'s `--force`, which waives a state check a human can knowingly
override, `--terminal` is a required choice like `--root` itself: this is
exactly the choice the #10/#26 incident shows must never be silently
skipped. Accepted values are `ghostty`, `iterm2`, `none`, `terminal-app`,
`windows-terminal` (the same canonical backends `SWARMFORGE_TERMINAL`
accepts — one per file in `swarmforge/scripts/terminal-adapters/*.sh`) plus
`auto`: "I know automatic detection exists and I am explicitly choosing it."
`auto` is never forwarded to `SWARMFORGE_TERMINAL` literally — the script
simply does not export that variable at all when `auto` is chosen, letting
`detect-terminal-backend`'s own fallback chain run exactly as it does today.
Any other value is `2` `USAGE`, same as a missing `--root`.

Before touching anything, it checks whether the swarm is already running —
the same socket-liveness read `stop-swarm.sh`/`open-swarm.sh` use, inverted:
a socket that answers means starting again would spin up a second daemon
and a colliding second tmux session, so it refuses. A stale `tmux-socket`
file with no live server behind it (the watchdog-kill aftermath `open
swarm` already knows how to name) is the stopped state this verb exists to
recover from, not "already running" — it proceeds to launch.

Next, it acquires a project-scoped lock (issue #29) at
`$ROOT/.swarmforge/update-lock`, excluding a concurrent `update SwarmForge
scripts` on the same managed project — a lock already held by that verb is
`6` `UNSAFE`, naming the holder. Then, unless `--force` is given, it
recomputes a deterministic digest of the managed project's installed
`swarmforge/scripts/` and compares it against `$ROOT/.swarmforge/
scripts-manifest`: a missing manifest or a digest mismatch is `4` `DRIFT`,
and the launcher is never invoked — this is exactly the failure mode that
let a running swarm reach handoff with scripts its own launcher didn't
recognize as required. `--force` overrides both the lock contention and the
drift check (never the already-running check above, which has no
override): it steals a held lock and skips the digest comparison entirely.
The lock is held through the rest of this script, including launch and the
readiness poll, and is released on every exit path.

The launch itself runs detached, local or remote: `SWARMFORGE_TERMINAL=
<value> nohup ./swarm >log 2>&1 &` (or without the env var, for `auto`),
never a bare foreground `./swarm` — a bare launch is exactly what does not
survive the ssh session (or local shell) that started it closing, which is
the other half of how the #10 incident happened. It then polls the same
runtime files every other verb trusts (`tmux-socket`, then `tmux -S "$SOCK"
list-sessions`) until they confirm the swarm actually came up, rather than
reporting success just because the launch command was issued.

Exit codes / STATUS line:

- `0` `STARTED` — the swarm came up; `SOCK`/`TERMINAL` are reported.
- `2` `USAGE` — missing `--root`, missing `--terminal`, or `--terminal` not
  one of the accepted values. Nothing is attempted.
- `4` `DRIFT` — installed `swarmforge/scripts/` do not match
  `$ROOT/.swarmforge/scripts-manifest`, or it's missing (issue #29). The
  launcher is never invoked; re-run `update SwarmForge scripts` first, or
  pass `--force` to launch anyway.
- `5` `ERROR` — the runtime files never confirmed readiness within budget.
  This covers both `./swarm` exiting non-zero and it simply never becoming
  ready: the launch is intentionally detached (see above), so this script
  never inspects the launcher's own exit code, only the runtime files it
  should eventually produce — check the launch log named in the message.
- `6` `UNSAFE` — the swarm is already running; refuses to start a second
  daemon. Nothing was changed. This also now covers the project lock being
  held by a concurrent `update SwarmForge scripts` (issue #29), naming the
  holder — unlike the already-running case, `--force` clears a held lock.

**Boundary:** this verb only covers "from zero to one." Whether to `--force`
a restart over an already-running swarm, or wait out one that is still
tearing down, are `stop swarm`'s and `open swarm`'s territory, not this
one's. It also does not fix the window watchdog's own empty-window-ID
misjudgment (a launcher/watchdog-side defect) — it only keeps an operator
from accidentally walking into it via this verb. The lock and drift
preflight added by issue #29 guard entry into that same "zero to one" step;
they do not extend what this verb otherwise does. Once the launcher itself
takes over, it independently mirrors — deletes and recreates, not overlays —
and verifies each role worktree's `swarmforge/scripts/` against the
installed source before that role starts, so a stale per-role copy can't
outlive this verb's own project-level check.

## Verb: `update SwarmForge scripts`

Run the bundled script; it installs THIS repo's own `swarmforge/scripts/`
into a managed project's `swarmforge/scripts/`, the counterpart to `start
swarm`'s drift check (issue #29): a project onboarded from an upstream pack
(whose scripts came from wherever that pack's `./swarm` first-run
`ARCHIVE_URL` pointed) can drift onto scripts this fork's own launcher
doesn't recognize as required — exactly podsum's real incident, a legacy
`./swarm` whose `ARCHIVE_URL` line was never repointed and a
`swarmforge/scripts/` tree missing files the current launcher expects. This
verb is the WRITER for the identity manifest `start swarm`'s preflight
reads; the two never disagree about what "this project's scripts came from
here" means, because one writes the format the other reads, byte for byte.

```sh
scripts/update-swarmforge-scripts.sh --root <project-root> \
  [--target user@host] [--key <path>] [--local] [--force]
```

It stages the operator's own source checkout into a fresh temp copy
first, validates that STAGED copy against the same required-helpers and
terminal-adapters lists `swarmforge.bb`'s own `check-helper-scripts!`
enforces, and only then replaces the managed project's scripts tree,
manifest, and (if present) legacy `./swarm` launcher — all three
atomically, with rollback on any failure from the swap onward. Nothing at
`$ROOT` is touched until staging and validation both pass.

Preflight order deliberately mirrors `start swarm`'s (issue #29): 1)
refuse if the swarm is already running, no override, zero side effects, the
project lock never touched; 2) acquire the same project-scoped lock
`start swarm` uses, excluding a concurrent launch — `--force` steals a
held lock; 3) everything else runs with the lock held. The source checkout
this verb installs FROM is always resolved from where the operator script
itself lives, on the operator's own machine, regardless of whether `$ROOT`
is local or remote — a dirty (uncommitted) source checkout under
`swarmforge/scripts/` is refused with **no override, ever**: unlike the
lock, `--force` has no effect on this check, because an uncommitted source
checkout is never safe to ship. `--force` here does exactly one thing —
steal a held lock — and nothing more.

Exit codes / STATUS line:

- `0` `UPDATED` — the scripts tree, manifest, and legacy launcher (if
  present) were replaced; `ROOT`/`DIGEST`/`SOURCE_COMMIT` are reported.
- `2` `USAGE` — missing `--root`.
- `5` `ERROR` — the source checkout is dirty under `swarmforge/scripts/`
  (no override); the staged copy is missing a required helper or terminal
  adapter (names the file, `$ROOT` untouched); the manifest write failed
  (rolled back to the previous scripts tree); or a legacy `$ROOT/swarm`
  launcher's `ARCHIVE_URL` line didn't match the expected pattern after
  rewrite (names `$ROOT/swarm`, rolls back the scripts swap and manifest
  write too — the whole point of this verb existing).
- `6` `UNSAFE` — the swarm is already running (no override), or the
  project lock is held by a concurrent `start swarm` (names the holder;
  `--force` steals it).

**Boundary:** this verb only ever installs the operator's own current
source checkout; it never fetches, never targets a different commit or
branch, and never starts or stops anything. A managed project with no
`$ROOT/swarm` file at all is not an error — the launcher-rewrite step is
simply skipped, since not every managed project necessarily has that
legacy file. It also never repairs a running swarm's already-loaded
process state: a `DRIFT` reported by `start swarm` means "update, then
start" — this verb is the "update" half, never the "start" half.

## Verb: `dashboard`

Run the bundled script; it tunnels and opens the pack_web dashboard page:

```sh
scripts/open-dashboard.sh --root "$ROOT" [--window <ref>] \
  [--target admin@host] [--key ~/.ssh/key] [--local]
```

It reads `$ROOT/.swarmforge/dashboard-url`, ensures an SSH local-forward
tunnel to that port (reuses a working one; preferred port first, any free
port on bind conflict), confirms the port is owned by *this* project's own
`pack_web` (below), then opens or reuses one workspace named
`Dashboard · <basename>` with a browser surface on the tunneled URL.

Port ownership: HTTP 200 only proves something answers on the port, not
that it is this project's dashboard — on a host running several managed
projects with dynamic port allocation, a stale `dashboard-url` can collide
with another project's `pack_web`. The script reads
`$ROOT/.swarmforge/pack_web.pid` and confirms the process's `--serve`
argument equals `$ROOT`, running that check against `$TARGET`/local
directly (the tunnel carries HTTP only, no process identity). Same hard
rules and exit codes as `open swarm`: exit 3 STOPPED means dashboard-url is
missing, or `pack_web.pid` is missing/its process is dead — never start
`pack_web.sh --serve` yourself; exit 4 DRIFT means either multiple matching
workspaces, or the port is owned by another project's `pack_web` — in the
ownership case, someone else's dashboard is squatting the recorded port and
a human decides, the script never auto-repairs it; exit 5 ERROR. `--local`
expects the dashboard to already listen on this machine and runs the same
ownership check locally; no tunnel is created.

## Verb: `attach role`

Find the role in `sessions.tsv` and use its recorded session; do not construct
a session from a hardcoded role list:

```sh
ssh -tt -i "$KEY" "$TARGET" "tmux -S '$SOCK' attach -t '$SESSION'"
```

## Verb: `read swarm`

Run the bundled script; it iterates `sessions.tsv` in config order, captures
each recorded session's pane, and classifies it three ways instead of the old
two-state guess:

```sh
scripts/read-swarm.sh --root <project-root> \
  [--target user@host] [--key <path>] [--local]
```

Output is one line per role: `STATUS=READ` first, then `<role> <STATE> |
<pane text>` for every row in `sessions.tsv`, in config order:

```
STATUS=READ
coder    BUSY     | Working (esc to interrupt)
cleaner  UNKNOWN  | ⚠ rate limit reached, retrying in 43s
```

Exit codes / STATUS line:

- `0` `READ` — the verb did its work. This includes runs where some or every
  role reads `UNKNOWN`: reporting `UNKNOWN` accurately is success, not
  failure, for a verb whose job is to report accurately.
- `2` `USAGE` — missing `--root`.
- `3` `STOPPED` — `sessions.tsv`/`tmux-socket` missing, or the socket has no
  tmux server; the swarm is not running, never start it.
- `5` `ERROR` — the verb itself failed to run (not "some role is UNKNOWN").

`STATE` is one of:

- `IDLE` — the pane's last non-empty line confidently matches a known idle
  prompt (a bare `❯`/`>` with nothing after it, or a literal "ask me
  anything" placeholder).
- `BUSY` — it confidently matches a known busy marker (a codex-style
  "esc to interrupt" banner, or a claude-style "participle + for Ns"
  spinner line).
- `UNKNOWN` — neither. This also covers a **blank pane** (no non-empty line
  in the captured scrollback at all) — blank does not mean idle, since a role
  stuck on an error, a rate limit, or a confirmation prompt can leave an
  empty-looking last line too. `UNKNOWN` is the safe default, not a fallback
  to guess away.

**Boundary:** this verb does not try to enumerate every backend's error
states — `codex`, `grok`, and `claude` each render differently and drift
across versions, and chasing that is a losing race. Unrecognized output is
`UNKNOWN` by design; every role's raw pane text is always attached (`IDLE` and
`BUSY` included) so a human can check the read against the evidence. This is a
report verb (`CONTEXT.md` "## Operator verbs"): it never calls `send-keys` or
anything else that mutates tmux state, only `list-sessions` and
`capture-pane`. A visible handoff-mail notice on an `IDLE` role means it needs
`wake role` — that judgment is still the human's to make from the attached
text, not something this verb classifies.

## Verb: `wake role`

Run the bundled script; it resolves session and backend from `sessions.tsv`
itself and verifies the wake actually landed instead of trusting a stale
guess:

```sh
scripts/wake-role.sh --root <project-root> --role <name> \
  [--target user@host] [--key <path>] [--local]
```

It types `ready_for_next.sh`, confirms the text reached the input line, submits
with the backend's own key encoding (CSI-u Enter for `claude`, raw carriage
return for every other backend — see submit-keys in `handoffd.bb`; a symbolic
key name such as `C-m`/`C-j` is never used, since a TUI that negotiated
extended keys does not receive a literal Enter through tmux's key-encoding
layer), then confirms the input line no longer holds it.

Exit codes / STATUS line:

- `0` `WOKEN`
- `2` `USAGE` — missing `--root` or `--role`
- `3` — `sessions.tsv`/`tmux-socket` missing, or the socket has no tmux
  server; the swarm is not running, never start it
- `5` `ERROR` — the role is not in `sessions.tsv`, the text never reached the
  input line, or it reached but was never submitted (the failure sentence
  names the recorded backend — check it against the agent actually running
  in that session, per issue #14)

**Boundary:** `--role` never accepts a `--backend` override; the recorded
backend in `sessions.tsv` is the only source, because a caller-supplied guess
is exactly the silent-failure mode this script exists to catch.

## Verb: `talk role`

Run the bundled script; same send-then-verify contract as `wake role`, sending
one behavior slice instead of `ready_for_next.sh`:

```sh
scripts/talk-role.sh --root <project-root> --role <name> --message <text> \
  [--target user@host] [--key <path>] [--local]
```

Exit codes / STATUS line: same table as `wake role` (`0` `SENT`, `2` `USAGE`,
`3`, `5` `ERROR`), with the same "text arrived but was never submitted" ERROR
naming the backend for a mismatch.

**Boundary:** a lost `talk role` message is a lost dispatch, not just a missed
poke — the verified-submit step matters more here than for `wake role`. New
work enters through the `master` row from `roles.tsv`; no role name such as
`specifier` or `coder` is universally the intake role.

## Verb: `accept work`

Human acceptance after the swarm finishes a task. The chain ends when the
last recipient completes its inbound handoff; that completed file is the
delivery record.

Run the bundled script; it reports the terminal handoff per task the same way
this verb always has, and also closes a real gap (issue #17): a handoff stuck
in `inbox/new` — delivered but never claimed, the chain is broken — used to
read identically to "no work finished yet," because the old manual command
only ever looked at `inbox/completed`. Those two situations call for opposite
human responses (keep waiting vs. go find out why nothing picked it up), so
the script now WARNs about both `inbox/new` and `inbox/in_process` backlogs
old enough to be a stuck chain rather than normal in-transit delay:

```sh
scripts/accept-work.sh --root <project-root> \
  [--target user@host] [--key <path>] [--local]
```

Report body, per not-yet-shipped task:

- `task:` — the stable task name the chain carried (maps to the issue when the
  intake named it, e.g. `issue-50-brief-quality` → `Closes #50`).
- `commit:` — the final committed state; this is what the human PR should
  carry.
- `completed_at:` — when the chain finished.

Exit codes / STATUS line:

- `0` `REPORTED` — the verb did its work. This includes runs that print one or
  more `WARN=` lines: a stuck chain is information this verb successfully
  reported, not a verb failure.
- `2` `USAGE` — missing `--root`.
- `5` `ERROR` — `$ROOT/.swarmforge/handoffs` could not be found (wrong
  `--root`/`--target`/`--local`, or the target is unreachable).

**`WARN=` lines** report a backlog stuck long enough that it is not just
normal in-transit delay, one line per affected worktree:

```
WARN=3 handoffs are stuck in inbox/new in cleaner — the chain is not moving
WARN=1 handoffs are stuck in inbox/in_process in coder — claimed but not finishing
```

Staleness is judged by each handoff's own header timestamp
(`enqueued_at`/`dequeued_at`), never filesystem mtime — the same source of
truth `handoffd.bb`'s own retry ladder uses. Presence alone is not stuck: a
healthy chain routinely has a file sit briefly between delivery and pickup
(the daemon's own reconciliation doesn't send its first retry wake until 5s
have passed), so `inbox/new` only WARNs past 5 minutes — long enough to have
outlasted the daemon's fast retry rungs. `inbox/in_process` uses a longer,
30-minute threshold, since a role can legitimately work a real task for many
minutes; warning at the same 5-minute mark would fire on healthy in-progress
work, not a stuck chain.

Rules (unchanged from the manual command this replaces):

- **Exclude already-shipped tasks.** A completed handoff whose `commit:` is
  already on `origin/main` (or an ancestor of `HEAD`) has been accepted and
  merged; it must not be reported again. This runs `git merge-base
  --is-ancestor <commit> origin/main` against the **managed project's own**
  git repository at `$ROOT` — not swarm-forge's — the same way `stop swarm`'s
  `git status` check runs against the project's own worktrees. A check that
  cannot be confirmed (bad commit, no `origin/main`) is treated as "not
  shipped," never silently dropped. Also skip intermediate chain records (a
  task appears once per hop); keep only the terminal handoff — the newest
  completed file for a given `task:` per worktree.
- The handoff points at the commit only. The code itself is in git; verify
  with `git show --stat <commit>` or tests before opening the PR.
- When opening the PR, carry the `task:` → issue mapping into the PR body
  (`Closes #N`) so GitHub links them. The swarm never touches GitHub; linking
  is the accepting human's job.
- The board directory (`$ROOT/.swarmforge/board/`, when present) carries the
  same task name in `tasks.tsv` and the intake text in `<task>.txt`; use it to
  cross-check which issue the task came from.

**Boundary:** this is a report verb (`CONTEXT.md` "## Operator verbs") — it
only reads. It never modifies, moves, or deletes anything under `inbox/`:
`completed/` is an audit trail, `new/` and `in_process/` are live queue state
owned by the daemon and the `ready_for_next`/`done_with_current` helpers, not
by a human-facing report. It also does not try to diagnose *why* a handoff
went unclaimed — that could be the daemon stopped, the role busy, or a failed
wake (see issue #14) — this verb's only job is to make a stuck chain visible,
not to explain it.

## Verb: `stop swarm`

Run the bundled script; it preflights before it stops anything (issue #11):
`stop swarm` used to be a bare `close-swarm` call with no grace period and no
check of role state or uncommitted work, equivalent to pulling the power
instead of a shutdown. The script now reports what a stop would interrupt and
requires a human decision before it touches tmux.

```sh
scripts/stop-swarm.sh --root <project-root> \
  [--target user@host] [--key <path>] [--local] [--force]
```

It reads `sessions.tsv` and classifies each role's pane exactly the way `read
swarm` does (same `BUSY`/`IDLE`/`UNKNOWN` judgment, same shared code — the two
verbs must never disagree about a role's state), then reads `roles.tsv`'s
worktree-path column and runs `git status --porcelain` against each one
(deduplicated, since `master`/`none` rows both resolve to the project root).
Only when every role reads `IDLE` and every worktree is clean does it run the
same stop `close-swarm` has always done.

Exit codes / STATUS line:

- `0` `STOPPED` — every role was `IDLE` and every worktree was clean (or
  `--force` was passed); the swarm was stopped the same way it is today.
- `2` `USAGE` — missing `--root`.
- `3` `STOPPED` — `sessions.tsv`/`roles.tsv`/`tmux-socket` missing, or the
  socket has no tmux server; nothing to stop.
- `5` `ERROR` — the verb itself failed to run.
- `6` `UNSAFE` — a role read `BUSY` or `UNKNOWN`, or a worktree was dirty (or
  its status could not be verified at all — treated as unsafe, never as
  clean). **Nothing was changed**: no `kill-session`, no `close-swarm` call.
  Report the `PREFLIGHT` block to the user and let a human decide whether to
  wait or re-run with `--force`.

On `6` `UNSAFE`, stdout carries a `PREFLIGHT` block after `STATUS=`, one line
per unsafe condition found:

```
STATUS=UNSAFE
PREFLIGHT
BUSY=cleaner
UNKNOWN=coder
DIRTY=.worktrees/cleaner (12 files)
```

**`--force` skips the preflight gate entirely** — no state files read, no
tmux reached for anything but the stop itself — reproducing today's
unconditional behavior exactly. It is a human's explicit call to interrupt
whatever is running; the script never assumes it.

**Boundary:** this verb does not implement graceful per-agent shutdown — no
`/exit` sent to any backend, no wait for it to wind down. It only surfaces
state to a human before an irreversible `kill-session`. It also never commits
on a role's behalf: a dirty worktree blocks the stop, but nothing here writes
a commit — that stays a human decision. If cleanup is incomplete after a
clean or forced stop, resolve this project's socket again, kill only that
tmux server, and match `handoffd.bb` with the exact project root; verify
other project daemons remain running.

## Testing

`scripts/test-open-swarm.sh` and `scripts/test-open-dashboard.sh` run the
two flows against a stubbed cmux/ssh/curl, covering topology pairing, reuse,
repair, stopped, drift, unparseable mutation output, tunnel reuse, and
port-conflict fallback. `test-open-dashboard.sh` additionally stubs `ps`
(via the ssh stub, plus a fake `pack_web.pid`/process registry) to cover the
port-ownership check: a live process whose `--serve` argument names a
different root (exit 4 DRIFT, actual root in stdout, no cmux call at all),
a missing `pack_web.pid`, and a `pack_web.pid` whose process is dead (both
exit 3 STOPPED, not 4). `scripts/test-wake-talk.sh` runs `wake-role.sh` and
`talk-role.sh` against a stubbed tmux, covering verified submit, a submit key
that never lands, an unknown role, a dead socket, and that neither script
ever submits with the symbolic `C-m`/`C-j`. `scripts/test-read-swarm.sh` runs
`read-swarm.sh` against a stubbed tmux (capture-pane keyed per session, so
one run can give two roles different pane content), covering an explicit
idle marker, an explicit busy marker, a blank pane (must read `UNKNOWN`,
never `IDLE`), unrecognized error text (`UNKNOWN` with the raw text still
attached), a dead socket, and that the script never calls `send-keys`.
`scripts/test-stop-swarm.sh` runs `stop-swarm.sh` against a stubbed
tmux/git/close-swarm, covering a `BUSY` role, an `UNKNOWN` role, a `DIRTY`
worktree, `--force` bypassing the gate, an all-clean stop, and a dead socket
— and asserts that on every blocked case neither `kill-session` nor
`close-swarm` is ever called. `scripts/test-accept-work.sh` runs
`accept-work.sh` against a stubbed `git` (find/sed run for real against
fixture files, `--local` so ssh is never invoked), covering a clean run with
no stuck handoffs, a fresh (not-yet-stale) `inbox/new` file that must not
WARN, a stale `inbox/new` backlog and a stale `inbox/in_process` backlog that
each WARN with their count and worktree name, an in-progress
`inbox/in_process` file under its longer threshold that must not WARN, the
already-shipped-commit exclusion, terminal-handoff dedup across chain hops,
and that two runs never change a byte under any `inbox/` tree.
`scripts/test-start-swarm.sh` runs `start-swarm.sh` against a stubbed
tmux/ssh and a fake `./swarm` launcher, covering missing `--root`/
`--terminal`, an invalid `--terminal` value, an already-running swarm
(refused, launcher never invoked), a stale dead socket (proceeds to
launch), `--terminal`'s value reaching the launcher's environment, `auto`
never being exported, and launch timeout. Its detachment cases prove real
process survival rather than argv shape: a fake launcher records its own
PID and sleeps past the point `start-swarm.sh` has already returned
control, and the test asserts start-swarm.sh returned well before that
delay elapsed, then sends the launcher a real `SIGHUP` (local case — what a
closing session delivers) and confirms it still finishes and writes its
marker file afterward, and (remote case, via a stub `ssh` that actually
executes the launch command instead of just logging it) that the marker
appears only after the stub ssh invocation itself has already returned.
`scripts/test-update-swarmforge-scripts.sh` runs `update-swarmforge-scripts.sh`
against a stubbed tmux/ssh and real local filesystem operations for staging,
digesting, validation, and replacement (stubbing only the ssh/tmux
boundary, per issue #29's Testing Decisions), against disposable fixture
git repos built from a real copy of this repo's own scripts so the
dirty-source case never depends on this checkout's own live git state.
Covers missing `--root`, an already-running swarm (refused with `--force`,
zero filesystem changes), project-lock contention naming the holder and
`--force` stealing it, a dirty source checkout, a staged tree missing a
required helper or terminal adapter (names the file, `$ROOT` untouched), a
successful local update (manifest digest/commit/repo correct, old tree
gone, legacy launcher rewritten and verified, `swarmforge.conf`/roles/
constitution/`sessions.tsv` byte-identical before and after), a legacy
launcher whose `ARCHIVE_URL` never matches the expected pattern (rolls back
the scripts swap and manifest write, not just the launcher), a manifest
write failure (old tree restored), a project with no legacy `./swarm` file
at all (launcher rewrite skipped, not an error), a full remote update over
the stub-ssh tar-pipe transfer, and the required cross-verb case: this
script's own successful update followed by `start-swarm.sh --local` with no
`--force` proceeding straight to `STATUS=STARTED` instead of `DRIFT`,
proving the digest this script writes and `start-swarm.sh`'s own read of it
genuinely agree. Run them after any change to the scripts or the stub
contracts.
