---
id: UX-05
title: Five planes / five roles invite a false 1:1 grid
severity: low
category: usability
status: resolved
affected_specs: [00-overview.md]
review_verdict: SOFTENED
---

# UX-05 — Five planes / five roles invite a false 1:1 grid

## Problem

00 presents **five planes** (interaction, governance, state, execution, observability)
and **five agent roles** (Guardian, Genesis, Worker, Compiler, Sentinel). The symmetric
count invites readers to assume a clean 1:1 plane↔role grid — which the design then
**violates**: the State plane has no owning role, and the Execution plane has two
(Worker + Compiler). The pleasing symmetry is misleading.

## Why it matters

A false structural symmetry is a subtle but persistent source of misunderstanding; new
readers build the wrong mental index and have to unlearn it.

## Proposed change

**Break the symmetry explicitly** in 00: state that planes and roles are *different
decompositions* (one by concern, one by power), show the actual mapping (including
"State has no role; Execution has two"), and avoid presenting them as parallel
five-item lists side by side.

## Acceptance

- [ ] 00 explicitly states planes and roles are not 1:1 and shows the real mapping.
- [ ] Related: UX-06 (the shared AgentNode across planes), UX-01 (model clarity).

## Resolution

Break the plane/role symmetry explicitly in 00: state that planes and roles are different
decompositions — one by concern, one by power — show the real mapping (the State plane
has no owning role; the Execution plane has two, Worker + Compiler), and stop presenting
them as parallel five-item lists side by side.

Rationale: the symmetric five-and-five counts invite a false 1:1 grid the design then
violates, so new readers build the wrong mental index and have to unlearn it. Naming the
asymmetry up front prevents that.

Coverage: satisfies the single acceptance check — 00 states planes and roles are not 1:1
and shows the real mapping. The UX-06/UX-01 links are carried in those issues.
