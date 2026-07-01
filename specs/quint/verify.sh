#!/usr/bin/env bash
# Runs quint verify (Apalache backend) on each module's declared safety invariants.
# Each module lists its checked invariants in a top comment: # VERIFY: inv1, inv2
set -euo pipefail
for f in specs/quint/*.qnt; do
  invs=$(grep -m1 '# VERIFY:' "$f" | sed 's/.*# VERIFY: *//' || true)
  [ -z "$invs" ] && continue
  echo "== verify $f: $invs"
  quint verify --invariant="$invs" "$f"
done
