---
id: OE-05
title: Reputation modeled as an adaptive-control economy for 5–7 voters
severity: medium
category: overengineering
status: open
affected_specs: [02-consensus.md, 08-trust-and-security.md]
review_verdict: SOFTENED
---

# OE-05 — Reputation modeled as an adaptive-control economy for 5–7 voters

## Problem

Reputation (02 §6, 08 §3.3) is built as a full adaptive-control economy: proper
scoring rules, beta-Bayesian shrinkage, eligibility-trace credit assignment, decay
half-lives, and bounded slashing — high-order estimation applied to a population of
**5–7 fixed voters**, where §11.8 admits the thresholds are "coarse" and the ground
truth they calibrate against arrives "sometimes never." The apparatus then spawns
its own attack surface (sleeper / Sybil / collusion) that needs further defenses.

## Why it matters

The estimator is far more sophisticated than the data can support, and it is the
mechanism 08 leans on as "THE defense" — yet the verification gate (G0) can only
score the machine-checkable part of a proposal, not the subjective residue the
jurors actually voted on. Complexity here also directly feeds two robustness gaps
(ROB-03 inert-at-genesis, ROB-06 Sentinel side-door).

## Proposed change

Replace with a **scalar track-record weight in [0,1] that decays to a class prior.**
Detect hard, off-protocol behavior mechanically and quarantine via quorum/human
escalation rather than via a learned economy.

## Steelman caveat

Some down-weighting of demonstrably-miscalibrated voters is worth keeping; the
objection is to the RL-grade machinery (eligibility traces, calibration training of
stateless LLMs, beta shrinkage), not to "track record influences weight."

## Acceptance

- [ ] Reputation reduced to a scalar decaying weight, or the heavy estimator is
      justified against a sample size and ground-truth-arrival argument.
- [ ] Off-protocol detection vs. reputation slashing are separated (see ROB-06).
- [ ] "Reputation = P(match ground truth)" claim narrowed to the measurable subset.
