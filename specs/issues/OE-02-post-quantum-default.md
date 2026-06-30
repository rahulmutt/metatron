---
id: OE-02
title: Hybrid post-quantum crypto mandated as the default now
severity: medium
category: overengineering
status: wontfix
affected_specs: [00-overview.md, 08-trust-and-security.md, 09-mcp-auth-proxy.md]
review_verdict: SOFTENED
---

# OE-02 — Hybrid post-quantum crypto mandated as the default now

## Problem

The spec set mandates hybrid post-quantum signatures/KEM (`Ed25519+ML-DSA`,
`X25519+ML-KEM`) as the **default** across all signing and transport (00 §7,
08 §3.2, 09 §3.8). But:

- The threat — quantum forgery of internal vote signatures, which are **not
  confidential** — sits far down a risk list dominated by LLM drift and prompt
  injection.
- The escape hatch is **already built**: a scheme-tagged, crypto-agile `SigScheme`
  enum (the same mechanism correctly used to *defer* BLS/FROST).
- Composite "verify both" doubles signature size and cost on the hottest paths and
  forces ML-DSA/ML-KEM into the v1 critical path — while 08 §5 admits the PQ
  migration itself is unsolved.

## Why it matters

This forces the most exotic crypto in the design onto every hot path before the
simple version was shown to fail, contradicting the spec's own "defer exotic
crypto" stance applied to BLS/FROST.

## Proposed change

Default to **Ed25519 + X25519/mTLS** behind the existing `SigScheme` enum; make PQ a
config flip, not a mandate.

## Steelman caveat (important — scopes the fix)

Harvest-now-decrypt-later *does* bite the **permanent, append-only ledger**: a
signature on a commit-witness that must remain verifiable for the life of the system
cannot be retrofitted to PQ later. So the correct resolution is **scoped**, not
blanket removal: keep a PQ option (or default) for **long-lived commit-witness
signatures on the ledger**, and use classical schemes for ephemeral SVIDs, transport,
and per-event signatures where rotation makes the quantum threat moot.

## Acceptance

- [ ] PQ is no longer mandated for ephemeral/transport/per-event signing.
- [ ] A reasoned PQ posture for *permanent ledger witnesses* is recorded explicitly.
- [ ] Migration story (08 §5) is either resolved or marked a blocking open question.

## Resolution

Keep the hybrid post-quantum mandate (`Ed25519+ML-DSA`, `X25519+ML-KEM`) as the default
across all signing and transport. The PQ-as-default posture is deliberate and no spec
change is made.

Rationale: defaulting strong is the intended security stance — harvest-now-decrypt-later
and the permanence of append-only ledger witnesses argue for one uniform PQ default
rather than a per-path split that can be misconfigured, and the crypto-agile `SigScheme`
enum already keeps the door open if the posture is revisited. The doubled signature size
and per-path cost are an accepted trade-off.

Coverage: as a wontfix this intentionally leaves all three acceptance checks unmet — PQ
remains mandated for ephemeral/transport/per-event signing, no scoped ledger-only split
is recorded, and the 08 §5 migration story is not closed here. That migration thread
remains the one genuine residual and is tracked separately.
