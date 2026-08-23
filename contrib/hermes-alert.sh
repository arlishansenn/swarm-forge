#!/usr/bin/env bash
# hermes-alert.sh — deliver a SwarmForge alert through the Hermes gateway.
#
# Site glue, not part of a pack: it knows where this deployment's Hermes lives.
# Wire it in on the swarm host (the machine running handoffd) as:
#
#   SWARMFORGE_ALERT_CMD='/path/to/hermes-alert.sh discord:#dev'
#
# handoffd runs it once per handoff that exhausts its wake attempt cap, with
# SWARMFORGE_ALERT_HANDOFF and SWARMFORGE_ALERT_ATTEMPTS in the environment.
#
# Hermes runs on msb7, not on the swarm host, so this is an ssh hop. That hop is
# the whole integration: `hermes send` reuses the gateway's stored platform
# credentials and needs no running gateway for bot-token platforms.
#
# Smoke test before trusting it — the alert path is only worth having if it has
# been proven once:
#   ./hermes-alert.sh discord:#dev "swarmforge alert path test"
# List what targets exist:
#   ssh msb7 '~/.local/bin/hermes send --list'
#
# Exit codes: 0 delivered, 2 usage, 5 ssh or hermes failure.
set -euo pipefail

usage() {
  sed -n '2,23p' "$0" >&2
  exit 2
}

[ $# -ge 1 ] || usage
TARGET=$1

# The target is pasted into a remote shell command. A single quote in it would
# break out of the quoting; refuse rather than guess what the operator meant.
case $TARGET in
  *"'"*) echo "hermes-alert: target may not contain a single quote" >&2; exit 2 ;;
esac

# Both overridable because this deployment's ssh alias resolves to a LAN address:
# a swarm host that moves networks needs to be pointed somewhere else without
# editing this file.
HOST=${SWARMFORGE_HERMES_HOST:-msb7}
HERMES=${SWARMFORGE_HERMES_BIN:-'~/.local/bin/hermes'}

MESSAGE=${2:-"swarmforge on $(hostname -s): handoff ${SWARMFORGE_ALERT_HANDOFF:-<unknown>} still unclaimed after ${SWARMFORGE_ALERT_ATTEMPTS:-?} wake attempts"}

# The message goes over stdin, never into the remote command line: it carries
# operator-facing prose, and remote shell quoting is not the place to find out
# what characters it contains.
if ! printf '%s\n' "$MESSAGE" |
     ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" \
         "$HERMES send --quiet --to '$TARGET'"; then
  echo "hermes-alert: delivery to $TARGET via $HOST failed" >&2
  exit 5
fi
