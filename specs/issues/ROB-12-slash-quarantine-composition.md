---
id: ROB-12
title: Slash-then-quarantine composes into honest-voter eviction
severity: high
category: robustness
status: open
affected_specs: [07-observability.md, 08-trust-and-security.md]
review_verdict: CONFIRMED
---

# ROB-12 — Slash-then-quarantine composes into honest-voter eviction

## Problem

Corroborated slashing shifts the reputation-weighted ⅔ quorum; a Worker quarantine is an
ordinary (⅔) TypedDiff (08 §3.6). `sentinel.qnt`'s `slashThenQuarantineTest` shows a
Sentinel bloc first manufacturing quorum by slashing honest voters, then using that quorum
to **quarantine** an honest voter — dropping it from aggregation entirely.
`quarantineRequiresQuorum` holds, because the quorum is real; it was just manufactured.

## Why it matters

The dual-set minority protection (08 §3.6) guards only kernel **removal**, not Worker
quarantine. So the composition slash→quarantine evicts honest voters through a path no
single guard rejects — a strictly stronger outcome than the weight-nudge ROB-06 considered.

## Proposed change

Extend anti-weaponization to quarantine: require the evidence trail plus a quorum computed
on **pre-slash** weights for a quarantine that follows recent Sentinel-driven slashes, or
gate Worker quarantine behind the dual-set protection when the quorum shifted via slashing.

## Acceptance

- [ ] A quarantine cannot be carried purely on quorum manufactured by recent slashes.
- [ ] `sentinel.qnt` `slashThenQuarantineTest` no longer quarantines an honest voter.
- [ ] Related: ROB-06 (parent), ROB-11 (the slashing precondition).
