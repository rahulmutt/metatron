---
id: ROB-05
title: Consensus stall amputates the external-action plane in minutes
severity: high
category: robustness
status: open
affected_specs: [08-trust-and-security.md, 09-mcp-auth-proxy.md]
review_verdict: CONFIRMED
---

# ROB-05 — Consensus stall amputates the external-action plane in minutes

## Problem

SVIDs are minutes-lived (08 §3.8) and the `mcp-auth-proxy` validates them against the
**current advancing Merkle head** and **fails closed** (09 §3.9). Therefore any
consensus stall — the council can't reach quorum — expires every credential within
minutes and **halts all external action**, including the very tools an operator would
need to diagnose and recover. This cascade across the trust/proxy boundary is analyzed
in neither spec.

## Why it matters

A liveness failure in governance silently becomes a total loss of external capability,
at the worst possible time. Fail-closed is correct for *revocation*, but here it also
fires on *staleness*, conflating "this agent was cut off" with "the head stopped
advancing."

## Proposed change

Validate SVIDs against the **last-known-good head with a bounded staleness grace
window**, so a transient quorum stall does not instantly amputate external action.
Only genuine quarantine/revocation (an explicit decision recorded in state) cuts an
agent off mid-window. Define the grace bound and the diagnostic-tool carve-out.

## Acceptance

- [ ] SVID validation distinguishes "head is stale" from "agent is revoked."
- [ ] A bounded staleness grace window is specified, with its security trade-off stated.
- [ ] Recovery/diagnostic tooling has a defined path during a stall.
- [ ] Related: ROB-04 (the stall that triggers this is often a council deadlock).
