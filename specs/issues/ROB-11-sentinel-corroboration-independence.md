---
id: ROB-11
title: k-of-n Sentinel corroboration has no independence requirement
severity: high
category: robustness
status: open
affected_specs: [07-observability.md, 08-trust-and-security.md]
review_verdict: CONFIRMED
---

# ROB-11 — k-of-n Sentinel corroboration has no independence requirement

## Problem

ROB-06's resolution requires **k-of-n Sentinel corroboration** before a finding moves
reputation/vote weight (07 §5.9, 08 §3.6). But neither spec requires the corroborating
Sentinels to be **decorrelated**. Sentinels are LLM-backed and can share a base model, so
a correlated bloc of k Sentinels is a single logical watcher — and `sentinel.qnt`'s
`blocCaptureTest` shows the bloc self-corroborating to slash every honest voter to zero,
reaching faction supermajority while `slashRequiresCorroboration` holds throughout.

## Why it matters

02 imposes exactly this decorrelation discipline on Genesis voters (ROB-02, red-team lane,
measured-decorrelation precondition). The Sentinel path has no equivalent, so ROB-06's fix
closes the *single*-Sentinel door but leaves it open k-wide to a correlated bloc.

## Proposed change

Require corroborating Sentinels to be measurably decorrelated (distinct base
model/class, or a dispersion floor on their findings), mirroring 02's voter-independence
precondition; or route bloc-correlated corroboration through G0 adjudication instead.

## Acceptance

- [ ] Corroboration counts only decorrelated Sentinels toward k.
- [ ] `sentinel.qnt` `blocCaptureTest` no longer reaches faction supermajority under the
      strengthened gate.
- [ ] Related: ROB-06 (parent), ROB-02 (voter independence).
