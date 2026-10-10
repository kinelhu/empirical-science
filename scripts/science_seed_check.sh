#!/usr/bin/env bash
# The science seed (0.70): the same science seed builds the same hidden world on two different maps. Runs
# the integration test on two map seeds and compares the seeded world's fingerprint (es-test prints it).
# A test run alone cannot see this: it cannot change its own map seed. Fails if the fingerprints differ.
set -euo pipefail
cd "$(dirname "$0")/.."
a=$(scripts/test.sh 4242 2>&1 | grep "the science seed" | grep -o "seeded world [0-9]*" || true)
b=$(scripts/test.sh 777 2>&1 | grep "the science seed" | grep -o "seeded world [0-9]*" || true)
echo "map 4242: ${a:-none}; map 777: ${b:-none}"
[ -n "$a" ] && [ "$a" = "$b" ] || { echo "SCIENCE SEED CHECK FAILED: the seeded worlds differ (a world layer reads the map seed)"; exit 1; }
echo "science seed check ok"
