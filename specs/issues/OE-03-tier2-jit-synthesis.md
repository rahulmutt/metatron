---
id: OE-03
title: Tier-2 JIT code synthesis trusts an undefined equivalence metric
severity: high
category: overengineering
status: open
affected_specs: [05-agent-jit.md]
review_verdict: CONFIRMED
---

# OE-03 — Tier-2 JIT code synthesis trusts an undefined equivalence metric

## Problem

The agent-JIT's Tier-2 *generalizes* a stochastic LLM policy into deterministic
synthesized code, trusted via an `EquivalenceCertificate` whose underlying
equivalence metric §8a **admits is undefined**. The "safe by construction" and
guard-"soundness" claims are unachievable/unfalsifiable for a stochastic policy
(§6.5 contradicts the whole-system safety claim), and §5.2's "cost pressure lowers
thresholds" contradicts RD-3's locked "does not tune the statistical bound."

Tier-1 (exact canonical-key memoization + guard + deopt-to-LLM) already captures
most of the cost savings with a **trivially-correct fallback**. Tier-2's marginal
value over Tier-1 is unquantified, and it is the most dangerous tier.

## Why it matters

You cannot ship a mechanism whose safety predicate you cannot state. Tier-2 is the
joint where the elegant "it's a JIT" analogy breaks — a real JIT is safe because its
guards are *sound and decidable* (is-this-an-int32); equivalence of a stochastic
policy to synthesized code is neither.

## Proposed change

Ship **Tier-0 (LLM) + Tier-1 (exact-match memo with guard + deopt-to-LLM) only.**
Keep the `Tier` enum so Tier-2 slots in later, but defer Tier-2 until (a) the
equivalence metric exists and (b) measured Tier-1 hit rates prove insufficient.

## Steelman caveat

The JIT analogy is genuinely precise at the *mechanism* level (interpreter↔harness,
guard↔trap, deopt↔deopt, OSR↔mid-task tier swap). The objection is narrowly to
Tier-2's trust model, not to the tiering framing or to Tier-1.

## Acceptance

- [ ] §05 marks Tier-2 deferred behind the existing `Tier` enum.
- [ ] The equivalence metric is listed as a blocking prerequisite for Tier-2.
- [ ] §5.2 vs RD-3 contradiction (cost pressure tuning the bound) is resolved.
