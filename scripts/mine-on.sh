#!/usr/bin/env bash
# Start the Quantus node (if needed) and the miner in the background.
set -euo pipefail
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${APP_ROOT}/scripts/quantus-stack.sh" start -d
