---
id: UX-06
title: AgentNode is co-owned by all five planes
severity: low
category: usability
status: resolved
affected_specs: [01-state-model.md, 00-overview.md]
review_verdict: SOFTENED
---

# UX-06 — AgentNode is co-owned by all five planes

## Problem

The `AgentNode` object (01 §2.1) carries fields touched by every plane — interaction,
governance, state, execution, observability. This undercuts the spec's framing of
"clean horizontal slices / disjoint plane ownership": the central object is in fact
**shared by everyone**, which is the opposite of a clean slice.

## Why it matters

Readers are told the planes are cleanly separated, then discover the most important
object is co-owned. Left implicit, this reads as an inconsistency; made explicit, it's
a fine and common design (one aggregate with per-concern sections).

## Proposed change

Document `AgentNode` as **the one deliberately shared aggregate**, with its fields
**grouped by owning plane**, and state that this is an intentional exception to the
otherwise-sliced model rather than letting "clean slices" imply disjoint ownership.

## Acceptance

- [ ] `AgentNode` is presented as an explicit shared aggregate with per-plane field groups.
- [ ] 00/01 wording no longer implies the planes own fully disjoint state.
- [ ] Related: UX-05 (plane/role asymmetry), UX-01 (model clarity).

## Resolution

Document `AgentNode` as the one deliberately shared aggregate, with its fields grouped by
owning plane, and adjust 00/01 wording so "clean slices" no longer implies disjoint plane
ownership — it is an intentional exception to the otherwise-sliced model.

Rationale: the central object is touched by every plane, which contradicts the "clean
horizontal slices" framing if left implicit. Made explicit as one shared aggregate with
per-concern sections, it is a fine and common design rather than an inconsistency.

Coverage: satisfies both checks — `AgentNode` is presented as an explicit shared
aggregate with per-plane field groups, and 00/01 wording no longer implies the planes own
fully disjoint state.
