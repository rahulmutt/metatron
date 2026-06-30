---
id: UX-03
title: Full consensus on every diff is the throughput bottleneck
severity: high
category: usability
status: resolved
affected_specs: [00-overview.md, 02-consensus.md, 01-state-model.md]
review_verdict: SOFTENED
---

# UX-03 — Full consensus on every diff is the throughput bottleneck

## Problem

Every state advance — including the **high-churn common case** of routine progress
updates and worker spawns — contends on a **single serialized Merkle head** (01) and
goes through a **full LLM consensus round** (02 §9.1, 00 §5). The entire agent-JIT
(05) is then introduced largely to claw back the cost that governance spends. The
system pays for heavyweight governance on cheap, reversible operations and then builds
more machinery to recover the loss.

## Why it matters

This couples throughput and cost to the slowest, most expensive path for operations
that don't need it, and it makes the cost story circular (consensus is expensive →
add a JIT → JIT adds its own trust machinery). It also makes the common-case latency
hard to reason about.

## Proposed change

**Gate full consensus to high-blast-radius changes.** Let ordinary spawns and progress
updates proceed under a **single Guardian with post-hoc audit** (and cheap optimistic
concurrency on the head), reserving the blind-vote council for consequential or
irreversible proposals. This is consistent with the existing blast-radius tiering that
00/README already describe but the hot path ignores.

## Steelman caveat

A single, serialized, audited head is genuinely valuable as the system-of-record; the
objection is to running *full council consensus* on every diff, not to having one
ordered log.

## Acceptance

- [ ] Routine/reversible state advances bypass full council consensus (audited).
- [ ] The blast-radius tiering is applied to the *write path*, not just described.
- [ ] The JIT's cost-justification is re-evaluated once cheap writes are cheap.
- [ ] Related: OE-03 (JIT exists partly to offset this), UX-02.

## Resolution

Gate full council consensus to high-blast-radius changes. Let routine, reversible
advances — ordinary spawns and progress updates — proceed under a single Guardian with
post-hoc audit and cheap optimistic concurrency on the head, reserving the blind-vote
council for consequential or irreversible proposals. Apply the blast-radius tiering to
the write path, and re-evaluate the JIT's cost-justification once cheap writes are cheap.

Rationale: running full LLM consensus on every diff couples throughput and cost to the
slowest path for operations that don't need it, and makes the cost story circular
(consensus is expensive → add a JIT → the JIT adds its own trust machinery). Tiering the
write path keeps the single ordered system-of-record while pricing cheap operations
cheaply.

Coverage: satisfies all three checks — routine/reversible advances bypass full council
consensus (audited), blast-radius tiering is applied to the write path rather than just
described, and the JIT cost-justification is re-opened once writes are cheap.
