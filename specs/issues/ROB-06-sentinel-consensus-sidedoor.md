---
id: ROB-06
title: Sentinels are a single-agent side door into consensus weighting
severity: high
category: robustness
status: resolved
affected_specs: [07-observability.md, 08-trust-and-security.md]
review_verdict: CONFIRMED
---

# ROB-06 — Sentinels are a single-agent side door into consensus weighting

## Problem

A Sentinel is a dynamic, LLM-backed watcher. Its alerts feed **reputation slashing**
(07 §3.3, 08 §3.6), and reputation **is voting weight**. So a single drifting or
compromised Sentinel can shift the weighted majority of the council **without holding
a Genesis key** — violating the stated invariant that *no single agent swings
consensus*.

## Why it matters

The separation-of-powers model (propose ≠ dispose, no single voter decisive) is a
core safety property. A side channel from one watcher into vote weighting defeats it
indirectly, and Sentinels are exactly the kind of dynamic, governed-not-kernel agent
that can drift or be subverted.

## Proposed change

1. Require **k-of-n Sentinel corroboration** (or adjudication through the deterministic
   verification gate) before any finding moves reputation/vote weight.
2. Limit any **auto-ratified** Sentinel authority to **reversible** actions (e.g.
   deopt), never to weight changes that bias future consensus.

## Acceptance

- [ ] A single Sentinel finding cannot, by itself, change vote weight.
- [ ] Auto-ratified Sentinel emergency authority is bounded to reversible actions.
- [ ] The "no single agent swings consensus" invariant is re-checked against this path.
- [ ] Related: OE-05 (reputation as weight), ROB-01 (drift detection).

## Resolution

Require k-of-n Sentinel corroboration (or adjudication through the deterministic
verification gate) before any finding moves reputation/vote weight, and bound any
auto-ratified Sentinel authority to reversible actions only. Re-check the "no single
agent swings consensus" invariant against this path.

Rationale: reputation is voting weight, so a single drifting or compromised Sentinel
feeding slashing is a side door that shifts the weighted majority without holding a
Genesis key — defeating separation of powers indirectly. Corroboration plus
reversible-only auto-authority restores the invariant.

Coverage: satisfies all three checks — a single Sentinel finding can no longer change
vote weight, auto-ratified emergency authority is bounded to reversible actions, and the
"no single agent swings consensus" invariant is re-verified against the Sentinel path.
