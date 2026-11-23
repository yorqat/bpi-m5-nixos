#!/usr/bin/env bash
# Host-side entry point. Same implementation backs `nix run .#flash -- ...`.
set -euo pipefail
cd "$(dirname "$0")"

source scripts/common.sh
source scripts/flash-body.sh
