#!/usr/bin/env bash
#
# Builds the local app and runs it in place of any installed pnow (same bundle id, same history).
# To go back to the Homebrew copy: quit this one, then `open /Applications/pnow.app`.
#
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh
pkill -x pnow || true
while pgrep -x pnow > /dev/null; do sleep 0.2; done
open build/pnow.app
