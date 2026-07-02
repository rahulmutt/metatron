---
id: ROB-15
title: Under-declaring telemetry capability is a blessed detection-evasion path
severity: medium
category: robustness
status: open
affected_specs: [07-observability.md, 08-trust-and-security.md]
review_verdict: CONFIRMED
---

# ROB-15 — Under-declaring telemetry capability is a blessed detection-evasion path

## Problem

07 §5.7 states "under-declaring is fine" (extra telemetry is a bonus, not a violation). 07
§3.5.4 says consumers treat a low-`coverage_ratio` source as higher-variance — a Sentinel
**raises its detection threshold** rather than firing on a source it can barely see. Composed,
an adversarial agent minimizes its **declared** capability to dim its own telemetry and buy a
higher Sentinel detection threshold — coverage is treated as honesty-neutral but is
adversary-controlled.

## Why it matters

The graceful-degradation design assumes low coverage is benign (a poor harness), never
strategic. An agent that *wants* to avoid scrutiny is rewarded for declaring less.

## Proposed change

Make declared capability a floor an agent cannot lower unilaterally (or treat a *drop* in
declared capability as itself a `DriftDetected`/anomaly signal, not a threshold relaxation),
so under-declaration cannot be used to purchase detection leniency.

## Acceptance

- [ ] A drop in declared telemetry capability does not raise the Sentinel detection threshold
      for that source (or is itself flagged).
- [ ] §5.7 / §3.5.4 are reconciled against the adversarial-under-declaration case.
