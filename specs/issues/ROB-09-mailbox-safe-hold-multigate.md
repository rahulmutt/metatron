---
id: ROB-09
title: Mailbox does not state that a node's Blocked state is the conjunction of all its gating Questions
severity: high
category: robustness
status: resolved
affected_specs: [06-interaction-and-mailbox.md]
review_verdict: MODEL-SURFACED
---

# ROB-09 — Mailbox does not state that a node's Blocked state is the conjunction of all its gating Questions

## Status

**Resolved.** Surfaced by formal modeling (Apalache bounded model checking of
`specs/quint/mailbox.qnt`, Metatron Quint spec suite, Task 8), not by the original
adversarial spec review. The clarification below has now been applied to
`specs/06-interaction-and-mailbox.md`: §3.4's gating-edge bullet now states that a
node's `Blocked` state is the **conjunction over all of its currently-active gating
edges** (active = `OPEN` **or** safe-held `CLOSED` per §2.4), with a matching
cross-reference added to §2.4's high-stakes hold-and-degrade bullet. The Quint model
(`specs/quint/mailbox.qnt`) already enforces this semantics (findings F4/F5), so spec
and model now agree.

## What the model found

`specs/06-interaction-and-mailbox.md` §3.4 describes the Question-to-node gating
relationship in per-event, node-level terms: "creating a Question marks its target
progress node `Blocked`; answering or closing a Question clears the block." Read
literally, this describes the block as cleared by the resolution of *a* Question,
without addressing what happens when **more than one Question gates the same
progress node** and those Questions resolve into *different* states at different
times.

A Quint model of the mailbox subsystem (`specs/quint/mailbox.qnt`) formalized this
node-level `nodeBlocked: NodeId -> bool` exactly as described, and Apalache (bounded
model checking) found two related, increasingly serious counterexamples against the
`gatingConsistent` invariant (node blocked iff some question actively gates it):

1. **Two Open questions gating the same node.** Answering one question unconditionally
   cleared the node's block, even though the other question was still `Open` and still
   gating the same node — releasing work that should have stayed blocked.
2. **A safe-held `Closed` high-stakes question plus a still-`Open` question gating the
   same node (the headline finding).** §2.4 specifies that when a high-stakes Question's
   bounded escalation-timeout expires, the gated node "holds and degrades safely — it
   stays `Blocked` … but never proceeds on the irreversible action" (the Question itself
   transitions to a bounded fallback state, modeled as `Closed`, while the *node* must
   stay `Blocked`). When a *second*, ordinary `Open` question also gates that node and is
   later answered, a literal reading of §3.4's single-event clear rule wrongly clears the
   node's block — releasing a node that was still supposed to be safe-held onto its
   irreversible action, directly contradicting §2.4's "never proceeds" guarantee.

Both were genuine, reachable safety violations under the model (not tautologies or
vacuous checks — non-vacuity was confirmed by populated-state traces and, for (2), by
explicitly re-including the `timeoutHighStakes` transition in the verified step
relation rather than excluding it to dodge the counterexample). Both are now fixed in
the Quint model (`specs/quint/mailbox.qnt`, see `specs/quint/FINDINGS.md` §3, findings
F4/F5): a node's `Blocked` state is derived from the **set** of all its gating
Questions still in an active-block state (`Open`, or safe-held `Closed`), not
overwritten by the resolution of any single one.

## Affected spec §

`specs/06-interaction-and-mailbox.md`:
- §3.4 "Question lifecycle & the gating edge" — the clearing rule ("answering or
  closing a Question clears the block") is stated per-Question, not per-node-as-a-set.
- §2.4 "Blocking-until-answered" — establishes the high-stakes hold-and-degrade
  guarantee ("stays `Blocked` … never proceeds on the irreversible action") that the
  multi-gate interaction above can silently violate if the clearing rule is applied
  naively.
- §3.6 "Question deduplication & fan-out" addresses the reverse direction (one Question
  gating multiple nodes) but does not address multiple Questions gating one node.

## Suggested resolution

Make the node-level semantics explicit in §3.4 (with a cross-reference from §2.4):
state that a progress node's `Blocked` status is the **logical conjunction (OR) of all
its currently-active gating edges** — where "active" includes both an `Open` Question
and a Question that has safe-held into its bounded high-stakes fallback per §2.4 — and
that resolving (answering or superseding) any *one* gating Question clears only *that*
edge; the node returns to `Ready` only when **no** gating edge remains active. This is
a conservative, backward-compatible clarification (the common single-Question-per-node
case, which is likely the implicit mental model today, is unaffected) and it closes
exactly the ambiguity the Quint model's counterexamples exploited. No change to the
mechanism or the high-stakes hold-and-degrade policy itself is needed — only an
explicit statement of how the node-level `Blocked` bit composes across multiple
concurrent gating Questions.
