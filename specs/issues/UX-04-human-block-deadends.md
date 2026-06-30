---
id: UX-04
title: Many paths dead-end at "block until a human answers"
severity: medium
category: usability
status: resolved
affected_specs: [02-consensus.md, 06-interaction-and-mailbox.md, 09-mcp-auth-proxy.md]
review_verdict: SOFTENED
---

# UX-04 — Many paths dead-end at "block until a human answers"

## Problem

Several independent failure/uncertainty paths all terminate at **"block until a human
answers"** with no defined behavior when the human never returns:

- quorum failure / persistent council split (02 §10.2)
- high-stakes ambiguity gate (06 §2.4) — "blocks indefinitely"
- dangerous-tool step-up and proxy-down (09 §6.5)

These gate **availability on human latency**, and 06 additionally allows **two
authorized users to mutually deadlock** with no precedence rule. "Block indefinitely"
also contradicts the system's own tenet that humans are an unreliable oracle.

## Why it matters

A system that is supposed to steer itself toward a target stops dead in many ordinary
situations, and "indefinitely" is not an operational answer. Multiple independent
dead-ends with no timeout policy is both a liveness and a usability problem.

## Proposed change

1. Define a **uniform escalation-timeout with safe, conservative defaults** (what
   happens when no human answers within the window — typically: hold + degrade safely,
   never silently proceed on irreversible actions).
2. Add a **deterministic cross-user precedence rule** so two authorized users cannot
   mutually deadlock.
3. Make "block indefinitely" concrete: bounded wait → defined fallback.

## Steelman caveat

Blocking on humans for genuinely high-stakes/irreversible actions is the *right*
default; the objection is the absence of a *bounded* policy and a tie-break rule, not
the existence of human gates.

## Acceptance

- [ ] One escalation-timeout policy covers all human-block paths.
- [ ] Cross-user conflict has a deterministic precedence rule.
- [ ] No path is specified as blocking "indefinitely" without a defined fallback.
- [ ] Related: ROB-04 (council deadlock), ROB-07 (reversibility gate).

## Resolution

Adopt one uniform escalation-timeout policy across all human-block paths: a bounded wait
that, on expiry, holds and degrades safely and never silently proceeds on irreversible
actions. Add a deterministic cross-user precedence rule so two authorized users cannot
mutually deadlock, and ensure no path is specified as blocking "indefinitely."

Rationale: several independent paths gate availability on human latency with no defined
fallback, and "indefinitely" contradicts the system's own tenet that humans are an
unreliable oracle. A single bounded policy plus a tie-break rule fixes both the liveness
and usability problems while preserving human gates for genuinely irreversible actions.

Coverage: satisfies all three checks — one escalation-timeout policy covers every
human-block path, cross-user conflict has a deterministic precedence rule, and no path
blocks indefinitely without a defined fallback.
