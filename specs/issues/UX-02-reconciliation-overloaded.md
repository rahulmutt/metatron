---
id: UX-02
title: '"Reconciliation" names two different nested loops'
severity: high
category: usability
status: open
affected_specs: [03-control-loop.md, 04-runtime-and-harness.md, 00-overview.md]
review_verdict: CONFIRMED
---

# UX-02 — "Reconciliation" names two different nested loops

## Problem

"Reconciliation" is used for **two distinct loops** that are then nested inside each
other:

- **Governance loop** — the PID controller moves *desired state* by authoring
  proposals that consensus accepts (03).
- **Execution loop** — the backend makes running processes match the committed config
  (04, Kubernetes-style).

Both are described as "drive actual toward desired," and 03 nests the steering loop
around the execution loop. One word for two loops at different altitudes is a reliable
source of confusion, and it also obscures the convergence-ownership question (who is
responsible for closing the gap — see ROB/RD notes in 04).

## Why it matters

The reader cannot tell which loop a given guarantee, latency, or failure mode belongs
to. This is a naming defect with real consequences for reasoning about stability and
convergence.

## Proposed change

Reserve **"reconciliation" for the execution loop** (matching reality to committed
config). Give the governance loop its own name (e.g. **"steering"** or
**"governance loop"**) and state explicitly where one is nested in the other and which
owns convergence.

## Acceptance

- [ ] 00 glossary distinguishes the two loops with separate terms.
- [ ] 03 and 04 adopt the distinction consistently.
- [ ] Convergence ownership across the two loops is stated.
- [ ] Related: UX-03 (governance loop as bottleneck), OE-01 (the steering controller).
