---
id: ROB-04
title: Council self-repair must be ratified by the broken council
severity: high
category: robustness
status: open
affected_specs: [03-control-loop.md, 02-consensus.md, 08-trust-and-security.md]
review_verdict: CONFIRMED
---

# ROB-04 — Council self-repair must be ratified by the broken council

## Problem

When the council is split or degraded, its recovery actions — `WidenCouncil`,
`Decorrelate`, recompose (03 §3.7, 02 §11.6, 08 §3.4) — are emitted as **ordinary
proposals** requiring the same ⅔ (or constitutional ¾) majority. A genuinely split
council cannot pass them. The "controller steers the council back to health" loop has
**no working actuator** in the one situation it exists to handle.

## Why it matters

This is a circular recovery dependency: the mechanism that fixes the council requires
a healthy council. Without a break-glass path, the only real recovery is unbounded
human escalation, which the specs treat as a fallback rather than a designed path.

## Proposed change

1. Make **human escalation a first-class, specified recovery** for council deadlock
   (not an implicit catch-all).
2. Add a **founder-threshold break-glass recompose** path that bypasses the deadlocked
   council quorum (consistent with the threshold-of-founders trust root in 08).
3. Define detection: how a deadlock/split is recognized and what triggers break-glass.

## Acceptance

- [ ] A recovery path exists that does not route through the broken quorum.
- [ ] Break-glass authority, threshold, and audit trail are specified.
- [ ] Related: ROB-03 (recomposition re-enters uncalibrated reputation), ROB-05.
