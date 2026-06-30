---
id: ROB-01
title: Confident collective error is invisible to the feedback loop
severity: critical
category: robustness
status: open
affected_specs: [02-consensus.md, 03-control-loop.md, 07-observability.md]
review_verdict: CONFIRMED
---

# ROB-01 — Confident collective error is invisible to the feedback loop

## Problem

The only *fast* health signal the system has is `dispersion` — vote **disagreement**,
not **wrongness**. The most likely real-world LLM failure is a **correlated,
confidently-wrong council**: agents sharing a base model agree on a bad answer. That
produces *low* dispersion → low divergence error → the PID controller (03 §3.2) reads
"healthy" and does nothing. Verification (G0) only covers the machine-checkable part
of a proposal by construction, so it can't catch the subjective residue the council
got wrong.

The worst failure mode emits the **best** telemetry. This is the single most
dangerous blind spot in the design, and no spec owns it.

## Why it matters

Every downstream safety story (graceful degradation, self-correction, "the controller
steers the council back to health") assumes errors are *observable*. A failure the
loop cannot see cannot be corrected by the loop.

## Proposed change

1. Treat **"high subjective residue + low dispersion + low verification coverage"** as
   a distinct, escalating risk signal — not a healthy reading.
2. Require at least one **red-team lane drawn from a deliberately different model
   population** on consequential proposals, so confident agreement is stress-tested by
   a decorrelated source.
3. Surface "fraction of the decision that was machine-verifiable" as a first-class
   metric in 07, alongside dispersion.

## Acceptance

- [ ] Observability (07) exposes verification-coverage and a low-dispersion/low-coverage
      composite signal.
- [ ] Control loop (03) escalates rather than relaxes on that composite signal.
- [ ] Consensus (02) mandates a decorrelated red-team lane for high-blast-radius proposals.
- [ ] Related: ROB-02 (independence), OE-01 (the error vector feeding the PID).
