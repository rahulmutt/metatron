---
id: OE-06
title: SPIFFE/SPIRE + custom attestor + offline root CA for a single node
severity: medium
category: overengineering
status: resolved
affected_specs: [08-trust-and-security.md]
review_verdict: SOFTENED
---

# OE-06 — SPIFFE/SPIRE + custom attestor + offline root CA for a single node

## Problem

08 §3.7–§3.8 specifies a production PKI ceremony — SPIFFE/SPIRE, a custom on-chain
Metatron workload attestor, and an offline threshold-split root CA → SPIRE
intermediate issuer — for a system whose **default execution backend is a single-node,
in-process actor runtime.** The genuinely load-bearing idea ("authority is a
config-layer membership lookup, not a bearer credential") needs almost none of this.

## Why it matters

It front-loads multi-cluster federation machinery (and its ceremony, key custody, and
failure modes) before there is a second cluster to federate. It also duplicates the
self-certifying content-hash `AgentId` already defined beneath it.

## Proposed change

For v1: **keypair identity + short-lived orchestrator-signed token + a polled
revocation list.** Adopt SPIRE/attestor/split-root-CA only when multi-cluster
federation is a concrete, present requirement.

## Steelman caveat

The *concepts* 08 gets right — self-certifying `AgentId` decoupled from a rotatable
op-key, role-as-state not role-as-credential, crypto-agility via a scheme tag — are
excellent and should stay. The objection is to the PKI *ceremony*, not the identity
model.

## Acceptance

- [ ] §08 gates SPIFFE/SPIRE + attestor + split-root-CA behind a multi-cluster trigger.
- [ ] A minimal single-node identity/revocation path is specified as the default.
- [ ] Reputation-weighted `f32` threshold compare (08) is checked for floating-point
      determinism across nodes (a separate but adjacent correctness hazard).

## Resolution

Specify a minimal single-node default — keypair identity + short-lived orchestrator-signed
token + a polled revocation list — and gate SPIFFE/SPIRE, the Metatron workload attestor,
and the split-root-CA behind a concrete multi-cluster trigger. Separately, flag the
reputation-weighted `f32` threshold compare for cross-node floating-point determinism.

Rationale: the load-bearing idea (authority is a config-layer membership lookup, not a
bearer credential) needs almost none of the production PKI ceremony, and front-loading
multi-cluster federation machinery before a second cluster exists is pure cost and risk.
The identity concepts that 08 gets right — self-certifying `AgentId`, role-as-state,
crypto-agility via a scheme tag — are kept.

Coverage: satisfies all three checks — the ceremony is gated behind a multi-cluster
trigger, a minimal single-node identity/revocation path is the default, and the `f32`
determinism hazard is flagged for follow-up.
