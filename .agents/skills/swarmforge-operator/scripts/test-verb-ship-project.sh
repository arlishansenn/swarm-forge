#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VERB=ship-project
REAL_SCRIPT=ship-project.sh
EXPECTED_STATUS=PR_OPENED
FIELDS='url'
DEFAULT_ADAPTER=real
. "$HERE/test-support/ship-fixture.sh"
. "$HERE/test-support/verb-contract.sh"
