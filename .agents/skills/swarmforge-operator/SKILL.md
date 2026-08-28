---
name: swarmforge-operator
description: "Use when operating a running SwarmForge project from the local machine: opening its role sessions or its pack_web dashboard in cmux, reading role state, waking or messaging a role, running one GitHub issue through the swarm to a stacked pull request, stopping the swarm, or installing a fork pack (two-pack, four-pack, six-pack) into a new or existing project directory before the swarm has ever run."
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
`start swarm`, `update SwarmForge scripts`, and `run issue` are scripted and
follow this contract today. The other verbs
are shell steps in this file; run them as written and read their raw output.
Bringing them under the contract is tracked in the issue tracker.

## Verb: `onboard project`

Install one fork pack into a managed project directory. This is the
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

The pack comes from `arlishansenn/swarm-forge`, and the extracted archive is
**immutable input** (issue #38, ADR-0002). Each fork Pack branch already ships
its final config and a launcher pointing at this fork's `main`, so there is no
post-install patch step any more. That step is what used to destroy the
launcher's executable mode (issue #33): not touching the file is what keeps its
bytes and mode intact, not a more careful way of writing it back. `update
SwarmForge scripts` keeps its own separate ARCHIVE_URL rewrite as a
legacy-repair path for projects onboarded before this change.

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
  [--target user@host] [--key <path>] [--local] [--force] \
  [--dashboard-port <N>]
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

`--dashboard-port <N>` (issue #78) is forwarded as `SWARMFORGE_DASHBOARD_PORT`,
which `pack_web` binds instead of asking the kernel for a random one. Omit it
and nothing is exported — `pack_web` keeps the random port it has always
picked, byte for byte. A fixed port is what `dashboard --tailnet` needs: a
random one cannot be published on a tailnet, because there is no stable URL
to publish. Only the shape is validated (digits, `2` `USAGE` otherwise);
which ports a host hands out is that host's own convention, not something
SwarmForge has an opinion about. `--terminal` and `--dashboard-port`
accumulate into one `env` prefix, so both reach the launcher together.

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
scripts-manifest`. Which of the two identity artifacts exist decides what
happens (issue #35):

- **Fresh** — snapshot and manifest both absent. This is a project that was
  onboarded and left stopped, and the Pack's own launcher owns first-run
  bootstrap, so `start swarm` hands off to it rather than refusing. Fresh does
  not mean "ignore a mismatch": it is the single exact state where both are
  absent.
- **Managed** — both present. The digest is verified before launch, and so
  before any role-worktree mirroring can propagate the top-level tree. Issue
  #29's per-role fidelity check only proves a role's copy matches its source,
  so a corrupt top-level tree has to be caught here or not at all.
- **Incomplete** — exactly one present. A torn install; `4` `DRIFT`, never a
  guess about which side is right.

A digest mismatch is likewise `4` `DRIFT`, and the launcher is never invoked —
this is exactly the failure mode that let a running swarm reach handoff with
scripts its own launcher didn't recognize as required. `--force` overrides both
the lock contention and the drift check (never the already-running check above,
which has no override): it steals a held lock and skips the digest comparison
entirely. The lock is held through the rest of this script, including launch
and the readiness poll, and is released on every exit path — **except one**: a
readiness timeout on the fresh-bootstrap path leaves it deliberately held. The
readiness budget is sized for launching an already-installed snapshot, while a
first run also downloads one, which is unbounded; timing out there does not
prove the launcher stopped, and releasing would let a retry or a concurrent
`update SwarmForge scripts` become a second writer against an install still in
progress. Clearing it is then an explicit `--force`.

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
- `2` `USAGE` — missing `--root`, missing `--terminal`, `--terminal` not one
  of the accepted values, or a non-numeric `--dashboard-port`. Nothing is
  attempted.
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

Run the bundled script; it opens the pack_web dashboard page as a cmux
browser workspace:

```sh
scripts/open-dashboard.sh --root "$ROOT" [--window <ref>] \
  [--target admin@host] [--key ~/.ssh/key] [--local] [--tailnet]
```

It reads `$ROOT/.swarmforge/dashboard-url`, reaches the port (tunnel or
tailnet, below), confirms the port is owned by *this* project's own
`pack_web`, then opens or reuses one workspace named `Dashboard · <basename>`
with a browser surface on the resulting URL. `TUNNEL=` in the report says
which path was taken: `created`, `reused`, `tailnet`, or `local`.

### How to run it

Set these once, then run the steps in order. `SF` is this skill's `scripts/`
directory. For a dashboard on the machine you are already on, follow the
`# local:` comments: `REMOTE=(--local)`, and read the file without `ssh`.

```sh
SF=.agents/skills/swarmforge-operator/scripts
ROOT=/Users/admin/project/podsum          # the MANAGED project's root, on its host
TARGET=admin@100.64.0.4                   # omit for a local root
KEY=~/.ssh/tailscale_key                  # omit for a local root
REMOTE=(--target "$TARGET" --key "$KEY")  # local: REMOTE=(--local)
```

**Step 1 — read the port.**

```sh
PORT=$(ssh -n -i "$KEY" "$TARGET" "cat $ROOT/.swarmforge/dashboard-url" | sed 's#.*:##; s#/##')
# local: PORT=$(sed 's#.*:##; s#/##' "$ROOT/.swarmforge/dashboard-url")
echo "$PORT"
```

**Step 2 — branch on it.**

```sh
case $PORT in
  778[0-9]) echo "fixed   -> step 3" ;;
  *)        echo "random  -> step 5" ;;
esac
```

**Step 3 — fixed port: open it over the tailnet.**

```sh
"$SF"/open-dashboard.sh --root "$ROOT" "${REMOTE[@]}" --tailnet
```

Expect `TUNNEL=tailnet`. On `5` `ERROR` naming an unpublished port, run step 6a
once and repeat this step. Then go to step 4.

**Step 4 — done. Print the report's `URL=` line in your reply.** Not "opened
it" — the address itself, because that is what opens on the user's phone.

**Step 5 — random port: open it over the ssh tunnel, then stop.**

```sh
"$SF"/open-dashboard.sh --root "$ROOT" "${REMOTE[@]}"
```

Expect `TUNNEL=created` or `reused`. Print the `URL=` line **and** say it works
only on this machine and dies when the laptop sleeps. Offer step 6; do not run
it. Step 6b interrupts running work, so it is the user's call.

**Step 6 — switch this project to a fixed port. Only after the user agrees.**

```sh
# 6a. publish the range — ONE-TIME PER HOST; skip if `serve status` lists it
ssh -i "$KEY" "$TARGET" 'for p in $(seq 7780 7789); do tailscale serve --bg --tcp $p tcp://127.0.0.1:$p; done'
ssh -i "$KEY" "$TARGET" 'tailscale serve status'

# 6b. show what stopping would interrupt, then stop  (ASK FIRST)
"$SF"/read-swarm.sh  --root "$ROOT" "${REMOTE[@]}"
"$SF"/stop-swarm.sh  --root "$ROOT" "${REMOTE[@]}"

# 6c. start again on this project's port from the table below (7780, 7781, ...)
"$SF"/start-swarm.sh --root "$ROOT" "${REMOTE[@]}" --terminal none --dashboard-port <N>

# 6d. go back to step 3
```

`start swarm` refuses an already-running swarm with `6` `UNSAFE` and has no
override, so 6b cannot be skipped. `tailscale serve --bg` survives reboots and
`tailscale down`/`up`, and `--tcp` takes one port (no range syntax), which is
why 6a is a loop run once per host.

**Never expose the dashboard any other way.** 6a is the only sanctioned path.
Do not write a port forwarder or a proxy, do not add an `ssh -L` of your own,
do not change what `pack_web` binds to. It binds `127.0.0.1` on purpose, so a
host without tailscale behaves exactly as before; anything in front of that
publishes a Teardown button to everyone who can reach it. If these steps do
not get there, say so and stop — do not improvise a route.

### Dashboard port allocation

`7780`-`7789` is reserved for dashboards, one number per project, so that the
URL itself says which project you are looking at:

| project | port |
|---|---|
| podsum | `7780` |
| pi-governance (coder2) | `7781` |
| unassigned | `7782`-`7789` |

Ports do not actually collide across hosts — this table exists so a human
reading a URL knows what it is. It is a convention this fork's operator keeps
by hand: nothing derives it, nothing enforces it, and `--dashboard-port` does
not range-check against it. Give a new project the next free number and add a
row here.

### Why `--tailnet` exists

Without the flag the script builds an SSH local-forward to the port. That
tunnel lives on the operator's laptop: **it dies when the laptop sleeps**, and
no other device can use it. `--tailnet` skips it, takes the target's tailscale
IP straight out of `--target`, checks `http://<ip>:<port>/` answers 200, and
points the browser surface there.

The verb runs **no `tailscale` command** — it only observes over HTTP, and on a
port that does not answer it exits `5` `ERROR` with the command to run, having
created no workspace and no tunnel. `--tailnet` with `--local` is `2` `USAGE`:
there is no target host to reach over the tailnet. It is not the default; the
ssh path is unchanged.

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
ownership check locally; no tunnel is created. The ownership check runs on
the `--tailnet` path too, and matters more there: a fixed port is a far
likelier collision target than a random one was.

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

The judgment reads the last couple of non-empty lines, after dropping any
trailing static footer (issue #58). Grok draws one below the prompt — `Grok
4.6 (high) · always-approve · 93K / 500K · ctrl+o transcript` — that carries
no state and never changes, so stopping at the pane's physically last line
reported `UNKNOWN` for every Grok role. `BUSY` wins over `IDLE` anywhere in
that window, because a busy pane still shows its empty prompt below the
spinner.

- `IDLE` — a line there confidently matches a known idle prompt (a bare
  `❯`/`>` with nothing after it, or a literal "ask me anything" placeholder),
  and no busy marker is present.
- `BUSY` — a line there confidently matches a known busy marker (a codex-style
  "esc to interrupt" banner, a claude-style "participle + for Ns" spinner, or
  Grok's "Waiting for response").
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
poke — the verified-submit step matters more here than for `wake role`. That
step judges the input line, which is the last non-empty line **after** any
trailing static footer is dropped. Reading the physically last line instead is
what made every Grok dispatch report `STATUS=SENT` without confirming the
submit key had landed (issue #58); reading further up the pane instead brings
back issue #28, where text parked in transcript history reads as unsent. It is
that one line, and the footer is the only thing skipped. New
work enters through the `master` row from `roles.tsv`; no role name such as
`specifier` or `coder` is universally the intake role. Normal task intake is
Dashboard New Task, not `talk role`: New Task creates the Board card and
carries the stable task name all the way to the terminal handoff `accept
work` reports (issue #39). `talk role` sends a behavior message to a running
role — it never creates a Board task, and is not a substitute for New Task.

## Verb: `accept work`

Human acceptance after the swarm finishes a task. The chain ends when it
returns to the **master** Role; the file in the master worktree's own
`inbox/completed/` is the delivery record, and it is the only one (issue
#39). Every other worktree's `completed/` holds intermediate hops of the same
task — a chain passing through `cleaner` on its way back leaves a completed
file there too, and reporting that one as the result named the wrong
`commit:`. The script resolves master from `.swarmforge/roles.tsv` by
**worktree-name (column 2) `== master`**, never by role name: which role sits
on master differs per pack (`coder` in two-pack, `specifier` in four-pack).
It requires exactly one such row and refuses to guess.

Being in master's `completed/` is necessary but not sufficient. The master also
completes **non-terminal** inbound handoffs — an intermediate hop it merged and
closed carries `task`/`commit`/`completed_at` too, and sits in the same
directory. Terminal is a property of the sending event, and the script accepts
either signal:

- `non-forwarding: true` — stamped by `swarm_handoff.bb` when the sender is the
  pack's last role, and enforced there too: holding a stamped inbound handoff
  makes `swarm_handoff.sh` refuse to send another `git_handoff`.
- the `to:` recipient **set** equals every role but the sender — the
  compatibility path for records written before the stamp existed.

That second one is set equality, not a recipient count. A two-pack's terminal
`cleaner → coder` return has exactly one recipient, because "every role except
cleaner" is just `coder`; counting recipients misses it.

The Board is cross-checked but never decides. `handoffd` moves a card to `done`
when it **delivers** a terminal-shaped handoff, before any recipient has
processed it, so a lane disagreement is reported as a `WARN=` and the record is
still printed. With no Board at all the report says so and falls back to the
handoffs alone.

Run the bundled script; it reports the terminal handoff per task from the
master worktree, and also closes a real gap (issue #17): a handoff stuck
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
  `--root`/`--target`/`--local`, or the target is unreachable); or
  `$ROOT/.swarmforge/roles.tsv` is missing or does not have exactly one
  `master` worktree row (the message carries the actual match count).

**`WARN=` lines** come from two independent scans, and neither changes the
exit code.

A **stuck backlog**, one line per affected worktree — long enough that it is
not just normal in-transit delay (issue #17; this scan still covers *every*
worktree, unaffected by the master-only rule above, since a chain can stall
at any hop):

```
WARN=3 handoffs are stuck in inbox/new in cleaner — the chain is not moving
WARN=1 handoffs are stuck in inbox/in_process in coder — claimed but not finishing
```

A **malformed completed record** in the master worktree — a delivery record
must be `type: git_handoff` with non-empty `task`, `commit` and
`completed_at`. A record short of that is named, not silently dropped (same
"uncertain, so say so" rule the already-shipped check follows):

```
WARN=<file> missing commit — not reported as a delivery record
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
  shipped," never silently dropped.
- **One record per task, the newest one on master.** Intermediate hops are
  already excluded by reading only the master worktree; when master itself
  holds several terminal returns for one `task:` (a re-run, a fast
  `cleaner → coder` loop), the newest `completed_at:` wins. Ordering compares
  the ISO8601 UTC string with its fractional part padded to a fixed 9 digits
  first — the producer drops the fraction entirely on an exact second
  boundary, so `...:55Z` and `...:55.000001Z` both occur and only the padded
  form orders them correctly. No `date` parsing is involved; `date` on macOS
  cannot parse the fractional shape at all. The report still prints the
  recorded `completed_at:` verbatim. Equal padded timestamps fall back to
  filename lexical order, a declared last-resort tie-break, so the result is
  never undefined.
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

## Verb: `run issue`

Put **one** GitHub issue through the swarm and stop at a reviewable PR. Every
step it takes was already a documented step in this file; what was missing was
a verb that takes them in order. Skipping one raised no error, and podsum lost
both ways it can be lost: a `git pull` was never run after a merge, so the
managed project's `main` diverged from `origin/main` and stayed diverged; and
a Board card named `验收 3 个 commit` produced a `task:` that mapped back to no
issue, so the accepting human had to reverse-engineer what the PR closed.

```sh
scripts/run-issue.sh --root <project-root> --issue <N> \
  [--target user@host] [--key <path>] [--local] [--max-wait <seconds>]
```

Six steps, in this order:

1. Read `$ROOT/.swarmforge/dashboard-url`. **Every run, never cached** —
   `pack_web` binds a fresh port on every start.
2. `gh issue view <N>` on the target, inside `$ROOT`, so `gh` resolves the
   *managed project's* repository from its own git remote. Its title becomes
   the slug: `feat/issue-<N>-<slug>` for the branch, `issue-<N>-<slug>` for
   the task name, one source for both.
3. `BASE` = the newest open PR's `headRefName`, or `main` when there is none.
4. Read **both** markers — the Board card and the branch — and answer all four
   states: neither is a fresh run, both is a resume, the branch alone is a
   resume that still owes a POST, the card alone is refused. Refuse too if the
   swarm is waiting on a human. Create the branch from `BASE` unless it is
   already there.
5. `POST {dashboard-url}/api/tasks` once — skipped only when the card is
   already on the Board — then poll the Board lane until `done`.
6. `accept work` for the commit — **retried until the delivery record is
   actually visible**, not read once — then `git push` and
   `gh pr create --base BASE`.

### Stacked branches, and why `main` is left alone

The branch comes off the newest open PR's head, not off `main`:

```
main                      ← only ever moves when a human merges a PR
 └ feat/issue-27          PR base = main
    └ feat/issue-28       PR base = feat/issue-27
       └ feat/issue-29    PR base = feat/issue-28
```

That buys three things at once. A linear `blocked by` chain needs the previous
issue's commits **visible** to the next issue's coder, and they are not on
`main` until a human merges. PR diffs stay clean — every branch off `main`
with nothing merged means each later PR carries every earlier PR's commits.
And the swarm stops committing onto `main` directly. Once a human merges the
lower PR, GitHub retargets the upper one to `main` by itself.

No new worktree is needed for this. `merge_and_process.bb` contains exactly
two git commands (`merge-base --is-ancestor` and `merge --no-edit`), both
against whatever `HEAD` is; nothing in the swarm names a branch. `BASE` is
looked up fresh from `gh pr list` on every call — **this verb keeps no state
between calls.**

### The four things it refuses to get wrong

- **It never posts the same task twice.** `pack_web`'s `create-task!` checks
  only that the name is non-empty, so a second POST really does create a
  second card and a second handoff note. The Board is grepped for the task
  name *before* anything is created. An existing card does not always mean
  "stop", though — if the matching branch is there too, the card is this verb's
  own from an interrupted run and the second call resumes it instead (issue
  #65, see *If the run is killed*). The converse holds as well: a branch with
  no card is an earlier run of this verb that was killed before it posted, so
  the POST is *owed*, not skipped (issue #76).
- **It stops when the swarm is waiting on a human.** A blocked agent does not
  fail — it writes a clarification request or a pending approval and waits, so
  its task never reaches `done`. `/api/state`'s `clarifications` (status
  `pending`) and `approvals` are checked once before anything is created and
  again on every poll round. This is the only thing in the loop that stops it
  on purpose, and it is what makes a `for ... || break` chain safe: without
  it, the loop moves on to the next issue and stacks the next branch on top of
  work nobody has looked at.
- **Only the Board lane says a task finished.** The chain is
  `coder → cleaner → coder`, and `/api/state`'s `work_in_flight[].state` reads
  `idle` for the coder between hops. A role-state check calls a half-finished
  task done; the script never reads that field.
- **A poll timeout is not a failure.** It exits `5` `ERROR` saying the task may
  still be running, and **never re-posts** — a re-post would create a second
  card and a second chain.
- **Board `done` and `accept work` are two different events, not one.**
  `handoffd` marks the card `done` the moment it *delivers* a terminal-shaped
  handoff, while `accept work` reads only the master's `inbox/completed/`, so
  for as long as the master is still working that file in `inbox/in_process/`
  the task is `done` on the Board and invisible to the report. The script
  retries `accept work` across that window (`SF_RUN_ISSUE_DELIVERY_SECONDS`,
  default 600s) instead of reading it once. Issue #63: reading once made
  `#60`'s live run on podsum `#30` exit `5` with nothing pushed and no PR, on
  a run whose work had in fact completed.

### One issue per call

There is no `--issues 28,29,30`. A list version would need exactly one piece
of error handling, and the caller already has it:

```sh
for n in 28 29 30; do run-issue.sh --root R --issue "$n" || break; done
```

Exit codes / STATUS line:

- `0` `PR_OPENED` — the report body carries `issue:`, `task:`, `branch:`,
  `base:`, `commit:`, `resumed:` and `url:`. `resumed: yes` means this call
  continued an earlier interrupted run rather than posting a new task.
- `2` `USAGE` — missing `--root` or `--issue`, or `--issue` is not a number.
  Nothing runs at all.
- `5` `ERROR` — `dashboard-url`/`roles.tsv` missing, `gh`/`git`/`curl` failed,
  the poll ceiling was reached (`SF_RUN_ISSUE_TIMEOUT_SECONDS`, default
  7200s), or the Board said `done` but the delivery record stayed invisible to
  `accept work` for the whole delivery window (`SF_RUN_ISSUE_DELIVERY_SECONDS`,
  default 600s) — never open a PR from a branch whose commit was not confirmed.
  Neither ceiling ever pushes, opens a PR, or re-posts the task.
- `6` `UNSAFE` — a card by that name exists **and its branch does not**, so it
  is not this verb's card, or a pending clarification/approval is blocking.
  Both name the thing to clear, and nothing was created in either case. A card
  *with* its branch is resumed, not refused.
- `7` `STILL_RUNNING` — `--max-wait` ran out. The task is posted and the swarm
  is still working: nothing was pushed, no PR was opened, and the task was
  **not** re-posted. The body carries `lane:` and `waiting_for:` so the caller
  knows how far it got, and re-running the same command continues from there.
  It is a separate code from `5` on purpose. The `for ... || break` chain
  breaks on both, but "still working, call me again" and "something broke"
  need different reactions from whoever reads the break — the same reason GNU
  `timeout` exits `124` instead of reusing the exit code of the command it
  timed out.

The PR is always opened with explicit `--title`/`--body`. **Never `--fill`:**
it would use the swarm's own commit messages, which carry no `Closes #N` —
exactly how a PR ended up needing a human to work out which issue it closed.
The body carries `Closes #<N>` plus `accept work`'s `task:`/`commit:`/
`completed_at:` verbatim, and no diff copy: the code is in git, the PR only
needs the pointer.

The task body is the minimal handoff `#26`/`#27` already proved — read the
issue, inventory before implementing, TDD, and the handoff chain, which is
**derived from `roles.tsv`** rather than written out, because role names
differ per pack. The issue body itself is deliberately not copied; the coder
can read it, and a copy goes stale.

### Running it from an agent session

**This verb blocks for the whole chain — minutes to hours. That is not a hang.**
It polls every `SF_RUN_ISSUE_POLL_SECONDS` (default 15s) up to
`SF_RUN_ISSUE_TIMEOUT_SECONDS` (default 7200s), plus up to
`SF_RUN_ISSUE_DELIVERY_SECONDS` (default 600s) more after the Board turns
`done`, waiting for the delivery record. The loop is plain shell: two
short round trips per round (`curl /api/state`, `cat tasks.tsv`) and **no model
call**, so the wait costs no tokens no matter how long it runs. What costs
tokens is the swarm's own agents on the target host, and that is unaffected by
the poll interval.

**Know your harness's cap, and pass a timeout.** The cap that bites is the
*client's* default, not the shell tool's own ceiling:

- **pi's `bash`** arms no timer at all unless `timeout` is passed
  (`dist/core/tools/bash.js:75-80`, mirrored in `pi-agent-core`'s
  `dist/harness/tools/bash.js:11-19`), and its ceiling is `MAX_TIMEOUT_MS =
  2_147_483_647` ms — about 24.8 days (`dist/core/tools/bash.js:16`). Nothing
  in the tree aborts a tool call on a clock; `AbortController` fires only on
  user abort and session dispose, and the timeout message is assembled from
  the `timeout` value the caller passed, so it can only ever print a number
  someone sent. The **120 seconds** recorded in issue #65 was therefore not
  pi's: it was a client-injected default, and passing an explicit `timeout`
  removes it. (Measured on `@earendil-works/pi-coding-agent@0.84.3`: no
  `timeout`, `sleep 150` killed at 120s; `timeout: 300`, the same `sleep 150`
  ran to completion.)
- **Claude Code's `Bash`** defaults to 2 minutes (`BASH_DEFAULT_TIMEOUT_MS`)
  and caps **hard** at 10 minutes (`BASH_MAX_TIMEOUT_MS`). No argument lifts
  that ceiling.

So, in this order:

1. Pass an **explicit large timeout** where the tool takes one (pi's `bash`
   takes `timeout` in seconds).
2. Where the hard cap is below a real chain — Claude Code's 10 minutes is —
   use **`--max-wait`** just under it, so the verb exits cleanly on `7`
   `STILL_RUNNING` instead of being SIGKILLed, and call it again. A clean exit
   reports the lane it reached; a kill reports nothing.
3. Use the harness's **background mode** if it has one (Claude Code's `Bash`
   takes `run_in_background: true`).
4. Otherwise let it be killed and **re-run the same command**. That is a
   supported path, not a repair (see below).

Do not wrap the call in `nohup ... &` to dodge the cap. Cancelling a pi tool
call kills the whole process tree, which takes the detached job with it, and a
detached run's output goes somewhere nobody is reading.

Do not "check on it" with `read swarm` in a second call while it runs — the
script is already polling, and a second reader tells you nothing it will not
print itself.

### `--max-wait <seconds>` — the caller's deadline

`SF_RUN_ISSUE_TIMEOUT_SECONDS` and `SF_RUN_ISSUE_DELIVERY_SECONDS` are the
*callee's* ceilings; until issue #76 a caller had no way to say how long it
could wait, and a harness that killed it at 600s produced a SIGKILL rather than
an exit. `--max-wait` is the caller's own budget, wall-clock, for the whole
call. The semantics are `kubectl wait --timeout`'s, deliberately not a fourth
invention:

| value | meaning |
|---|---|
| positive | wait at most that long, then exit `7` `STILL_RUNNING`. Replaces both ceilings for this call. |
| `0` | check once and return: post if a POST is owed, then report the current lane. |
| negative | keep the existing ceilings. This is the default (`-1`), so behaviour without the flag is unchanged. |

Reaching it is a **clean exit, not a kill**: nothing is pushed, no PR is
opened, the task is never re-posted, and the report names the lane it stopped
at. The budget covers the polling *and* the `accept work` delivery window, so
one number bounds the command rather than one phase of it.

### If the run is killed

**Re-run the exact same command.** The verb detects its own earlier run and
continues from wherever it stopped: it never posts a second task, never creates
a second branch, and never opens a second PR. A resumed run prints
`resumed: yes` in its report body.

What it looks at, and what it does:

| Board card for `issue-<N>-<slug>` | branch `feat/issue-<N>-<slug>` | what happens |
|---|---|---|
| absent | absent | fresh run |
| absent | **present** | **resume** — skip the branch, POST the task that never got posted |
| present | present | **resume** — skip the branch and the POST, pick up at the poll |
| present | absent | `6` `UNSAFE` — that card is not this verb's; nothing is touched |

The branch is the marker because this verb always creates it *before* it posts.
A card whose branch is missing was typed into the Dashboard by hand or made by
something else, and continuing on it would push work this verb never scoped.

The second row is the window **between** those two writes, about two ssh round
trips wide, and until issue #76 it had no exit: with no card the verb took the
fresh path, ran `git checkout -b` onto a branch that already existed, and
failed `5` `ERROR` — on every re-run, until a human deleted the branch by hand.
Both markers are now read on every run and each of the two decisions (create
the branch, post the task) answers to its own marker, so no ordering of the two
writes can produce a state with no way out.

To see which state you are in without running anything:

```sh
scripts/read-swarm.sh --root <project-root>          # is the swarm still working?
ssh <target> "grep '^issue-<N>-' <root>/.swarmforge/board/tasks.tsv"
```

A card in any lane means the task is posted; re-running is then always the
right move, whether the lane is still `coder` or already `done`.

**Boundary:** this verb opens a PR and stops. It never merges (`--merge` and
`--auto` are never passed), never answers a clarification (`read swarm` does
not even know the concept exists — that is a separate issue), and never
changes the Dashboard's listen address or the role topology. Recovery from
either `UNSAFE` is a human's: resolve the clarification in the Dashboard, or
delete the duplicate card — and if the task had already been posted before the
block, take it the rest of the way with `accept work` by hand rather than
re-running this verb, which would refuse on the card it created.

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
genuinely agree. `scripts/test-run-issue.sh` runs `run-issue.sh` against stubbed
`gh`/`git`/`curl` and a stubbed `accept-work.sh`, with `--local` so `ssh` is
never invoked while `dashboard-url`, `roles.tsv` and the Board TSV stay real
files read by a real `cat`. Lane progression is driven by the stubs — the POST
stub creates the card in the master lane, and each `/api/state` call advances
it by one scripted lane — so "how many rounds did it wait" is an assertable
number rather than a race. It covers missing/non-numeric arguments (nothing
runs at all), a duplicate Board card (exit 6, no POST, board and handoffs
byte-identical, no branch created), a pending clarification and a pending
approval before the POST (exit 6 naming the id, nothing created), a
clarification appearing mid-poll (exit 6 at the exact round it appeared, no
PR), `BASE` taken from an open PR's head and falling back to `main`, the
branch and task name sharing one slug, the task body naming the handoff chain
derived from `roles.tsv`, a coder that goes idle mid-chain while the lane is
still `coder`/`cleaner` (keeps waiting, and `work_in_flight` never appears
outside comments in the script), the poll ceiling (exit 5, exactly one POST,
no PR), and the PR argv itself: `--base`/`--head`/`--title`/`--body` present,
`Closes #N` and `accept work`'s `commit:` in the body, and `--merge`,
`--auto`, `--fill` absent. Two cases cover issue #63's delivery window, using
an `accept work` stub that reports successfully while omitting the current
task's block for a set number of calls: one where the record appears on the
third call (exit 0, exactly one push, exactly one `gh pr create`, and still
only one POST) and one where it never appears (exit 5 naming `in_process`, no
push, no PR, no re-post). Issue #65's resume path is covered by running the
script twice against one fixture: the first pass is cut off after the POST (a
lane that never reaches `done` plus a zero poll ceiling), and the second pass
must exit 0 with `resumed: yes` while the Board still holds exactly one card
and the two runs together produce exactly one POST, one branch, one push and
one `gh pr create`. A third case re-runs after a PR already exists for the
head and asserts `gh pr create` is not called again. Issue #76's dead end gets
a case of its own: the branch registry is seeded with the branch and the Board
left empty — exactly what a run killed between step 4 and step 5 leaves — and
the run must exit 0 having created no second branch, posted exactly one task,
and opened one PR. That case only bites because the `git` stub's `checkout -b`
now **fails on an existing branch** the way real git does; with a stub that
always succeeded it would pass against the broken script. `--max-wait` is
covered four ways: `0` exits `7` `STILL_RUNNING` after exactly one lane check
with no push and no PR and is then resumable like any other kill, `0` during
the delivery window exits `7` rather than `5`, a negative value still reaches
the old `5` `ERROR` ceiling, and a non-numeric value exits `2` having run no
command at all. For these the `git` stub
keeps a real branch registry — `checkout -b` records a name and `rev-parse
--verify` answers from it — because a stub that always exits 0 would let both
the resume case and the not-our-card case pass for the wrong reason. Its `accept work` stub prints a `WARN=` line and a
decoy task block first, so a parser that reads by line offset instead of by
`task:` prefix fails. Run them after any change to the scripts or the stub
contracts.
