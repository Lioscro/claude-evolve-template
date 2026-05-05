#!/usr/bin/env bash
set -euo pipefail

EVOLVE_DIR="$HOME/.claude/evolve"
source "$EVOLVE_DIR/scripts/lib.sh"

init_project "$1"
