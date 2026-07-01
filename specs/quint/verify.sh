#!/usr/bin/env bash
# Runs quint verify (Apalache backend) on each module's declared safety invariants.
# Each module lists its checked invariants in a top comment: # VERIFY: inv1, inv2
#
# Optional per-module directives (all skipped cleanly when absent, so a module
# with only "# VERIFY:" behaves exactly as it did before these features existed):
#
#   Default-step pass:
#     # VERIFY: inv1, inv2                 (required to run the default pass)
#     # VERIFY-MAX-STEPS: <int>            (bounds the default pass depth; omit ->
#                                          Apalache default depth. Use when a module's
#                                          state space is intractable at default depth
#                                          but sound at a shallower bound.)
#
#   Optional second, step-overridden pass — for invariants only non-vacuously
#   exercised under a non-default step action (e.g. an action that populates a map
#   the default step never touches). Skipped entirely unless # VERIFY-STEP: is present:
#     # VERIFY-STEP: <stepActionName>
#     # VERIFY-STEP-MAX-STEPS: <int>
#     # VERIFY-STEP-INVARIANTS: inv1, inv2
set -euo pipefail
for f in specs/quint/*.qnt; do
  invs=$(grep -m1 '# VERIFY:' "$f" | sed 's/.*# VERIFY: *//' || true)
  if [ -n "$invs" ]; then
    maxs=$(grep -m1 '# VERIFY-MAX-STEPS:' "$f" | sed 's/.*# VERIFY-MAX-STEPS: *//' || true)
    if [ -n "$maxs" ]; then
      echo "== verify $f [max-steps=$maxs]: $invs"
      quint verify --max-steps="$maxs" --invariant="$invs" "$f"
    else
      echo "== verify $f: $invs"
      quint verify --invariant="$invs" "$f"
    fi
  fi

  step=$(grep -m1 '# VERIFY-STEP:' "$f" | sed 's/.*# VERIFY-STEP: *//' || true)
  [ -z "$step" ] && continue
  smaxs=$(grep -m1 '# VERIFY-STEP-MAX-STEPS:' "$f" | sed 's/.*# VERIFY-STEP-MAX-STEPS: *//' || true)
  sinvs=$(grep -m1 '# VERIFY-STEP-INVARIANTS:' "$f" | sed 's/.*# VERIFY-STEP-INVARIANTS: *//' || true)
  echo "== verify $f [step=$step max-steps=$smaxs]: $sinvs"
  quint verify --step="$step" --max-steps="$smaxs" --invariant="$sinvs" "$f"
done
