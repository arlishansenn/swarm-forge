#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VERB=talk-role
REAL_SCRIPT=talk-role.sh
EXPECTED_STATUS=SENT
FIELDS='ROLE SESSION'
DEFAULT_ADAPTER=real
. "$HERE/test-support/wake-fixture.sh"
. "$HERE/test-support/verb-contract.sh"
