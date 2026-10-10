#!/usr/bin/env bash
# The balance model at every world strength: the harsh sample first
# (their guards and a summary), then the standard run, which judges all three and writes docs/balance.md.
# Each sample is reused when the mod has not changed (scripts/sample_worlds.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$HOME/Library/Application Support/factorio-sampler/script-output"
for s in harsh; do  # (gentle: out of the setting until redesigned)
  ES_STRENGTH=$s scripts/sample_worlds.sh
  BALANCE_STRENGTH=$s BALANCE_OUT="$OUT/balance-$s.md" uv run --with numpy docs/balance.py > /dev/null
  echo "$s: $(sed -n '/^GUARDS:/,$p' "$OUT/balance-$s.md" | tail -n +2 | tr '\n' ' ')"
done
scripts/sample_worlds.sh
uv run --with numpy docs/balance.py > /dev/null
echo "standard: docs/balance.md written"
