---
id: UX-01
title: Five expert vocabularies make the model un-teachable
severity: high
category: usability
status: open
affected_specs: [README.md, 00-overview.md]
review_verdict: CONFIRMED
---

# UX-01 — Five expert vocabularies make the model un-teachable

## Problem

The mental model is not one model — it is **five expert vocabularies stacked
together**: Kubernetes reconciliation, control-theoretic PID, an optimizing JIT, a
Condorcet/BFT jury, and distributed-systems Merkle/identity. The README's first
sentence fires four of them. Each spec is internally disciplined (00 owns the
vocabulary, "00 wins" on conflicts), but no engineer holds all five deep domains in
one head, so **nothing can be skimmed** and onboarding requires fluency in five fields.

The genuinely novel idea — a deliberative governor wrapped around reconciliation, with
propose ≠ dispose and verify-before-vote — is **small but buried** under the metaphors.

## Why it matters

"Could a competent engineer hold it in their head and build it?" is a stated goal. At
present the answer is no, not because the core is complex but because the framing
demands five specialist vocabularies before the core is visible.

## Proposed change

1. Lead 00/README with the **small core in plain language**, and explicitly demote the
   four domain analogies to "implementation framings, skippable on first read."
2. State, for each borrowed vocabulary, **how much of it is actually load-bearing** vs.
   evocative (this pairs with OE-01, OE-03, OE-04).
3. Provide a one-page "minimal mental model" an engineer can hold before diving into
   any single domain spec.

## Acceptance

- [ ] 00/README open with the core mechanism, not the metaphors.
- [ ] Each analogy is labeled with its load-bearing fraction.
- [ ] A one-page minimal model exists.
- [ ] Related: OE-01/03/04 (the heavy analogies), UX-02 (overloaded "reconciliation").
