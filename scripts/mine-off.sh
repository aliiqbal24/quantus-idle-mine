#!/usr/bin/env bash
# Stop the Quantus miner and node.
set -euo pipefail
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${APP_ROOT}/scripts/quantus-stack.sh" stop
