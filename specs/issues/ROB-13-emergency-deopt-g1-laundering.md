---
id: ROB-13
title: Emergency deopt launders a single Sentinel's opinion into vote weight via G1
severity: high
category: robustness
status: open
affected_specs: [07-observability.md, 08-trust-and-security.md, 02-consensus.md]
review_verdict: CONFIRMED
---

# ROB-13 — Emergency deopt launders a single Sentinel's opinion into vote weight via G1

## Problem

ROB-06 bounds auto-ratified Sentinel authority to **reversible** actions — e.g. emergency
deopt — with no corroboration required (08 §3.6). But 02 §6.2 scores votes retroactively
against **G1 ground truth, which includes observed trap storms**. `sentinel.qnt`'s
`g1LaunderingTest` shows one Sentinel storming deopts (no corroboration) and the subsequent
G1 retro-scoring dropping every approving juror's weight — an un-corroborated single-Sentinel
path into vote weight. `slashRequiresCorroboration` is never violated: no slash occurs.

## Why it matters

"Reversible" is not "consequence-free". A reversible action that manufactures the telemetry
G1 scoring reads becomes an *irreversible* weight move, bypassing the k-of-n gate ROB-06
installed on the *slashing* path — the same side door, one hop removed.

## Proposed change

Either exclude Sentinel-triggered deopt storms from G1 retro-scoring credit, or require the
same k-of-n corroboration before deopt-derived G1 signal is allowed to move reputation.

## Acceptance

- [ ] A single Sentinel's emergency deopts cannot, via G1, move any juror's weight.
- [ ] `sentinel.qnt` `g1LaunderingTest` no longer drops honest-juror weight.
- [ ] Related: ROB-06 (parent), `02` §6.2 (G1 scoring).
