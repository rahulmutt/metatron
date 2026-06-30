---
id: ROB-03
title: Reputation is inert exactly when stakes are highest
severity: high
category: robustness
status: resolved
affected_specs: [08-trust-and-security.md, 02-consensus.md]
review_verdict: CONFIRMED
---

# ROB-03 — Reputation is inert exactly when stakes are highest

## Problem

Reputation is the fault tolerance 08 leans on, but Bayesian shrinkage (08 §3.3,
02 §6.1) collapses all weights to ~uniform when there is no track record — i.e. **at
genesis and after every council recomposition.** In exactly those windows the system
runs as a **flat-headcount majority among uncalibrated LLMs**, and those windows are
when the most irreversible structural decisions (forming/reshaping the council) are
made.

## Why it matters

The defense is weakest precisely when the decisions are most consequential and least
reversible. "Bootstrap" is not an edge case here — every recomposition re-enters it.

## Proposed change

Add an explicit **burn-in regime**: until calibrated samples exist, restrict
autonomous commits to **high-verification-coverage proposals** (where G0 can carry the
weight reputation cannot), and route low-coverage / high-blast-radius decisions to
human escalation.

## Steelman caveat

Shrinkage-to-prior is the *correct* statistical behavior with no data; the issue is
not the estimator but the **absence of a compensating policy** during the
uncalibrated window.

## Acceptance

- [ ] A burn-in / cold-start policy is specified for genesis and post-recomposition.
- [ ] Autonomy during burn-in is gated on verification coverage, not headcount majority.
- [ ] Related: OE-05 (reputation machinery), ROB-04 (recomposition deadlock).

## Resolution

Add an explicit burn-in / cold-start regime for genesis and post-recomposition: until
calibrated samples exist, restrict autonomous commits to high-verification-coverage
proposals (where G0 can carry the weight reputation cannot) and route low-coverage /
high-blast-radius decisions to human escalation.

Rationale: shrinkage-to-prior is the correct statistical behavior with no data, but it
leaves the system a flat-headcount majority of uncalibrated LLMs exactly in the windows
where the most irreversible structural decisions are made — and every recomposition
re-enters that window. The fix is the missing compensating policy, not a change to the
estimator.

Coverage: satisfies both checks — a burn-in policy is specified for genesis and
post-recomposition, and autonomy during burn-in is gated on verification coverage rather
than headcount majority.
