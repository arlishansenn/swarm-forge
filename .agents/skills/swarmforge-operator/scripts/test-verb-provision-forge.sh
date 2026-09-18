#!/usr/bin/env bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
VERB=provision-forge
REAL_SCRIPT=provision-forge.sh
EXPECTED_STATUS=PROVISIONED
FIELDS='ROOT FORGE URL TARGET'
DEFAULT_ADAPTER=real
. "$HERE/test-support/provision-fixture.sh"
. "$HERE/test-support/verb-contract.sh"
