#!/usr/bin/env bash
# verify.sh — the single gate. Must exit 0 before any commit.
set -e
cd "$(dirname "$0")/.."
echo "── gdparse ──────────────────────────────"
find addons -name '*.gd' -print0 | xargs -0 gdparse
echo "── parity ───────────────────────────────"
node server/scripts/check-parity.mjs
echo "── invariants ───────────────────────────"
node server/scripts/check-invariants.mjs
echo "── tsc ──────────────────────────────────"
(cd server && npx tsc --noEmit)
echo "── vitest ───────────────────────────────"
(cd server && npx vitest run --reporter=basic)
