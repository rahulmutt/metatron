#!/usr/bin/env bash
# Runs quint verify (Apalache backend) on each module's declared safety invariants.
# Each module lists its checked invariants in a top comment: # VERIFY: inv1, inv2
#
# A module MAY also declare an optional second, step-overridden bounded pass for
# invariants that are only non-vacuously exercised under a non-default step action
# (e.g. an action that populates a map the default step never touches). This is
# driven by three directives, all optional as a group:
#   # VERIFY-STEP: <stepActionName>
#   # VERIFY-MAX-STEPS: <int>
#   # VERIFY-STEP-INVARIANTS: <comma-separated invariants>
# If # VERIFY-STEP: is absent, the second pass is skipped entirely and the module
# behaves exactly as it did before this feature existed.
set -euo pipefail
for f in specs/quint/*.qnt; do
  invs=$(grep -m1 '# VERIFY:' "$f" | sed 's/.*# VERIFY: *//' || true)
  if [ -n "$invs" ]; then
    echo "== verify $f: $invs"
    quint verify --invariant="$invs" "$f"
  fi

  step=$(grep -m1 '# VERIFY-STEP:' "$f" | sed 's/.*# VERIFY-STEP: *//' || true)
  [ -z "$step" ] && continue
  maxs=$(grep -m1 '# VERIFY-MAX-STEPS:' "$f" | sed 's/.*# VERIFY-MAX-STEPS: *//' || true)
  sinvs=$(grep -m1 '# VERIFY-STEP-INVARIANTS:' "$f" | sed 's/.*# VERIFY-STEP-INVARIANTS: *//' || true)
  echo "== verify $f [step=$step max-steps=$maxs]: $sinvs"
  quint verify --step="$step" --max-steps="$maxs" --invariant="$sinvs" "$f"
done
