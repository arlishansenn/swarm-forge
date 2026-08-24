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
`wake role`, `talk role`, `read swarm`, `stop swarm`, and `accept work` are
scripted and follow this contract today. The other verbs are shell steps in
this file; run them as written and read their raw output. Bringing them under
the contract is tracked in the issue tracker.

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

## Verb: `dashboard`

Run the bundled script; it tunnels and opens the pack_web dashboard page:

```sh
scripts/open-dashboard.sh --root "$ROOT" [--window <ref>] \
  [--target admin@host] [--key ~/.ssh/key] [--local]
```

It reads `$ROOT/.swarmforge/dashboard-url`, ensures an SSH local-forward
tunnel to that port (reuses a working one; preferred port first, any free
port on bind conflict), then opens or reuses one workspace named
`Dashboard · <basename>` with a browser surface on the tunneled URL.

Same hard rules and exit codes as `open swarm`: exit 3 STOPPED means
dashboard-url is missing — never start `pack_web.sh --serve` yourself; exit
4 DRIFT means multiple matching workspaces — cleanup needs user approval;
exit 5 ERROR. `--local` expects the dashboard to already listen on this
machine; no tunnel is created.

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
port-conflict fallback. `scripts/test-wake-talk.sh` runs `wake-role.sh` and
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
and that two runs never change a byte under any `inbox/` tree. Run them after
any change to the scripts or the stub contracts.
