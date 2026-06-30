---
id: ROB-02
title: Tolerance claim rests on voter independence admitted false elsewhere
severity: high
category: robustness
status: resolved
affected_specs: [08-trust-and-security.md, 02-consensus.md, README.md]
review_verdict: CONFIRMED
---

# ROB-02 — Tolerance claim rests on voter independence admitted false elsewhere

## Problem

08 (threat T1, §3.3) sells "graceful degradation, not a tolerance cliff" and invokes
the Condorcet Jury Theorem (collective error → 0 as n grows). **Both require voter
independence.** Yet the README lists **correlation-aware vote aggregation as an open
research question**, and 02 §5's open questions omit correlated failure entirely. The
central fault-tolerance claim therefore rests on a premise the authors elsewhere admit
is false.

Reputation cannot rescue this: a *novel* correlated failure has no track record to
down-weight against.

## Why it matters

CJT at n=5–7 is nowhere near its asymptotic regime, and correlated jurors break the
math directly rather than gracefully. If the headline tolerance property is
conditional on an unmet assumption, the system's safety posture is overstated.

## Proposed change

- Demote the tolerance claim to: **"mitigated; correlated failure is the headline
  residual risk."**
- Mandate **measured base-model / harness diversity** before any quorum is treated as
  independent; make decorrelation an operational precondition, not an assumption.
- Cross-link the open "correlation-aware aggregation" question into 02 and 08 instead
  of leaving it only in the README.

## Acceptance

- [ ] 08 no longer claims a tolerance bound that assumes independence without caveat.
- [ ] Decorrelation is specified as a measured precondition for quorum validity.
- [ ] Related: ROB-01 (confident collective error is the symptom of this).

## Resolution

Demote the tolerance claim to "mitigated; correlated failure is the headline residual
risk." Mandate measured base-model / harness diversity as an operational precondition
before any quorum is treated as independent, and cross-link the correlation-aware
aggregation open question into 02 and 08 rather than leaving it only in the README.

Rationale: both the "graceful degradation" claim and the Condorcet appeal require voter
independence, which the README itself flags as unsolved and which reputation cannot
rescue for a novel correlated failure. An honest residual-risk framing plus a measured
decorrelation precondition stops the headline safety property from resting on an unmet
assumption.

Coverage: satisfies both checks — 08 no longer asserts an independence-bound tolerance
without caveat, and decorrelation becomes a measured precondition for quorum validity.
The ROB-01 link (the symptom of this gap) is carried in ROB-01.
