---
name: swarm-observer
description: "Use when operating a running SwarmForge swarm from the local machine: attaching to role panes over SSH, watching chain progress, waking an idle role, or setting up the macmini six-pack observation workspaces."
---

# Swarm Observer

Operate a **running** SwarmForge swarm from the local machine. The swarm itself
lives on the remote host (macmini, `admin@100.64.0.4`, key `~/.ssh/tailscale_key`);
this skill is the local remote-control surface: attach, read, wake, watch.

Two sockets exist per host, one per swarm. The path in the project's
`.swarmforge/tmux-socket` is **a plain text file holding the socket path**, not
a socket itself; the real socket lives under `/tmp/swarmforge-admin/` with a
random numeric name that **changes on every `./swarm` restart**. Resolve it
dynamically, never hardcode it. The cmux socket is local only and never
crosses SSH.

## Constants

- Host: `admin@100.64.0.4`, SSH key `~/.ssh/tailscale_key`.
- Resolve each swarm's socket at use time (it changes every restart):
  ```sh
  SSH="ssh -i ~/.ssh/tailscale_key admin@100.64.0.4"
  PGSOCK=$($SSH 'cat ~/project/pi-governance/.swarmforge/tmux-socket')
  # e.g. /tmp/swarmforge-admin/<pid>.sock — the number is the launcher PID
  # and changes every restart. The tmux-socket file stores the path as text;
  # it is not the socket itself. podsum's socket lives in the same directory —
  # do not touch it unless asked.
  ```
- podsum swarm socket: resolve the same way from
  `~/project/podsum/.swarmforge/tmux-socket`. Do not touch unless asked; it is
  a different project's swarm.
- Roles: `specifier coder cleaner architect hardender QA`; sessions are
  `swarmforge-<role>`.
- Two swarms share the host; pi-governance worktrees live under
  `~/project/pi-governance/.worktrees/`.

## Attach one role

The attach line is `ssh -tt` + a quoted `tmux -S <socket> attach`:

```sh
ssh -tt -i ~/.ssh/tailscale_key admin@100.64.0.4 \
  'tmux -S '$PGSOCK' attach -t swarmforge-coder'   # $PGSOCK resolved as above
```

Detach with `Ctrl-b d`. Do not exit the inner agent TUI: `exit` in a pane kills
that agent process, and the cleanup-owner hook tears the whole swarm down with
it.

Two traps, both observed live:

1. **`cmux send` types but does not submit.** After sending a command to a pane,
   issue `send-key enter` as a separate call. Without it the ssh line sits typed
   and unexecuted, which looks exactly like a hung connection.
2. **A successful attach prints nothing.** The pane keeps its old content for a
   few seconds. Confirm success by seeing the tmux status bar
   (`[swarmforg0:<Role>*`), never by waiting for new output.

## Build the six-pane observation layout

Three workspaces of two panes each in one new window, every pane an attach:

```sh
SOCK=$($SSH 'cat ~/project/pi-governance/.swarmforge/tmux-socket')
P="ssh -tt -i ~/.ssh/tailscale_key admin@100.64.0.4"
LAYOUT='{"direction":"horizontal","split":0.5,
 "children":[{"pane":{"surfaces":[{"type":"terminal"}]}},
             {"pane":{"surfaces":[{"type":"terminal"}]}}]}'

cmux new-window --name "Six-Pack @ macmini"
cmux new-workspace --name "Specifier + Coder"  --layout "$LAYOUT" --focus false --window <new-window-ref>
cmux new-workspace --name "Cleaner + Architect" --layout "$LAYOUT" --focus false --window <new-window-ref>
cmux new-workspace --name "Hardender + QA"      --layout "$LAYOUT" --focus false --window <new-window-ref>
```

Then per pane, `cmux send --surface <ref> "$P 'tmux -S $SOCK attach -t swarmforge-<role>'"`
followed by `cmux send-key --surface <ref> enter`. Read back the surface refs
from `cmux tree --all` before addressing panes; refs are not stable guesses.
Mis-created workspaces are removed with `cmux close-workspace --workspace <ref>`.

## Read the chain

Snapshot all six roles at once (run over SSH; safe to run as often as needed):

```sh
for r in specifier coder cleaner architect hardender QA; do
  printf '%-11s | ' $r
  tmux -S $SOCK capture-pane -p -t swarmforge-$r -S -12 2>/dev/null \
    | grep -v '^$' | tail -1
done
```

Reading rules:

- The last line is the agent status line. `⏵⏵ bypass permissions on` and an
  empty prompt `❯` means idle. `Working (Ns • esc to interrupt)` means busy.
- `› You have new handoff mail. If idle, run ready_for_next.sh.` means the role
  has a queued handoff it has not picked up.
- codex panes show `gpt-5.6-sol medium · ~/project/pi-governance/.worktrees/<role>`;
  claude panes show the `SwarmForge <Role>` header.
- For depth, raise `-S` (lines of scrollback) before grepping.

## Wake an idle role

The daemon delivers a handoff by typing into the pane and submitting, but a
pane that was busy during delivery only gets the mail notice. Wake it:

```sh
tmux -S $SOCK send-keys -t swarmforge-<role> -l "ready_for_next.sh"
sleep 1
tmux -S $SOCK send-keys -t swarmforge-<role> -H 0d        # codex pane: Enter
tmux -S $SOCK send-keys -t swarmforge-<role> -H 1b 5b 31 33 75   # claude pane: CSI-u Enter
```

Which submit key to use is decided by the role's backend (claude vs codex, see
`swarmforge/swarmforge.conf`). The daemon itself does this per role; manual
wakes must do the same.

## Watch the chain unattended

A one-shot snapshot only shows the moment. For a trail, run the background
watcher on the remote host (exists at `/tmp/pigov-chain-watch.zsh`):

```sh
ssh -i ~/.ssh/tailscale_key admin@100.64.0.4 'nohup zsh -s' < /tmp/pigov-chain-watch.zsh &
```

It appends one line per role per round (180 s interval, 60 rounds) to
`/tmp/pigov-chain-watch.log` on the remote host. `/tmp` is wiped on reboot:
if the script is gone, recreate it from this section's snippet and relaunch.
Read the tail on demand:

```sh
ssh -i ~/.ssh/tailscale_key admin@100.64.0.4 'tail -40 /tmp/pigov-chain-watch.log'
```

The log answers "who was busy when" and pinpoints where a chain stalled. It
does not alert: a stalled round is discovered by being read, so check it after
any long silence.

## Talk to a role

Roles take instructions as typed text in their pane. specifier (claude) is the
task entry point; use the CSI-u Enter to submit. Approval gates in the six-pack
flow (specifier asking before handing off to coder) are answered the same way.
Keep instructions to one behavior slice per message.

## Stop the swarm

```sh
ssh -i ~/.ssh/tailscale_key admin@100.64.0.4 \
  '/Users/admin/project/swarm-forge/close-swarm /Users/admin/project/pi-governance'
```

If any stragglers remain: `tmux -S $PGSOCK kill-server`, then `pkill -f
"handoffd.bb /Users/admin/project/pi-governance"`. Verify with `pgrep -fl
handoffd` that the podsum daemon is untouched.
