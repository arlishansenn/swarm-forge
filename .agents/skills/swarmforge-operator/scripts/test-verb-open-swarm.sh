#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VERB=open-swarm
REAL_SCRIPT=open-swarm.sh
EXPECTED_STATUS=OPENED
FIELDS='ROOT TARGET WINDOW WORKSPACES'
DEFAULT_ADAPTER=real
. "$HERE/test-support/open-swarm-fixture.sh"
. "$HERE/test-support/verb-contract.sh"
