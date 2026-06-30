---
id: ROB-07
title: Blast-radius reversibility classifier is undefined yet gates autonomy
severity: high
category: robustness
status: resolved
affected_specs: [06-interaction-and-mailbox.md, 00-overview.md]
review_verdict: SOFTENED
---

# ROB-07 — Blast-radius reversibility classifier is undefined yet gates autonomy

## Problem

Whether the system **acts without asking** hinges on a blast-radius / reversibility
classification (06 §2.4, enum `BlastRadius` §4.2). But the spec never states the
**default when reversibility is unknown**, nor how reversibility is *positively
proven*. The single most important safety gate of the interaction plane rests on an
undefined predicate, and the "answer-wins revert" behavior depends on the same
predicate.

## Why it matters

A misclassification in the permissive direction means the system takes an
irreversible action it should have escalated. An undefined default is the most
dangerous possible setting for a gate that controls autonomy.

## Proposed change

1. Make **"reversibility unknown ⇒ block (escalate to human)"** normative.
2. Define **reversible** concretely: *no external side effect through the
   mcp-auth-proxy* **and** *a revertible DAG diff*. Anything else is irreversible by
   default.
3. Specify how the two objective inputs (external-effect, diff-revertibility) are
   computed, so the classifier is not a free-form LLM judgment.

## Steelman caveat

Two of the classifier's three inputs are objectively computable (does it touch the
proxy; is the diff revertible), so this is closer to a definable predicate than a pure
coin-flip — but the spec must actually *define* it and pin the unknown-case default.

## Acceptance

- [ ] Unknown reversibility defaults to block/escalate.
- [ ] `reversible` is given an operational definition tied to proxy effects + diff revert.
- [ ] Related: ROB-05 / UX-04 (escalation behavior when the human never answers).

## Resolution

Make "reversibility unknown ⇒ block/escalate" normative. Define `reversible` ≡ (no
external side effect through the mcp-auth-proxy) AND (a revertible DAG diff); anything
else is irreversible by default. Specify how the two objective inputs — external-effect
and diff-revertibility — are computed, so the classifier is not a free-form LLM judgment.

Rationale: an undefined default on the gate that decides whether the system acts without
asking is the most dangerous possible setting. Two of the three inputs are objectively
computable, so the predicate can be pinned to those, with the unknown case safely
defaulting to escalation.

Coverage: satisfies both checks — unknown reversibility defaults to block/escalate, and
`reversible` gets an operational definition tied to proxy effects plus diff revert. The
ROB-05/UX-04 link (what happens when the human never answers) is handled in those issues.
