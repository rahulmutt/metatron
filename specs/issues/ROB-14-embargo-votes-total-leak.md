---
id: ROB-14
title: Blind-vote embargo omits the consensus.votes_total counter
severity: medium
category: robustness
status: open
affected_specs: [07-observability.md]
review_verdict: CONFIRMED
---

# ROB-14 — Blind-vote embargo omits the consensus.votes_total counter

## Problem

07 §2.1's worked example increments `consensus.votes_total{verdict}` at vote-cast time. The
blind-vote embargo (07 §3.9) buffers the `BlindVoteCast` event and `vote.cast` span and
delays `dispersion`/`posterior` to `DecisionReached` — but never mentions the counter. A
live per-verdict counter leaks the running tally to a not-yet-voted Genesis member, letting
them correlate — defeating the decorrelation §3.9 exists to protect.

## Why it matters

This is an internal inconsistency in the plane that is supposed to *protect* the blind-vote
invariant. The leak is coarse (counts, not identities) but still correlating.

## Proposed change

Add `consensus.votes_total` to the embargo: buffer per-verdict increments and release them
on `DecisionReached`, alongside `dispersion`/`posterior`. One-line addition to §3.9's list.

## Acceptance

- [ ] §3.9 explicitly embargoes `consensus.votes_total` until the blind round closes.
- [ ] The §2.1 example is reconciled with the embargo rule.
