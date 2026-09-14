#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bb --classpath "$SCRIPT_DIR" "$SCRIPT_DIR/pack_board.bb" "$@"
