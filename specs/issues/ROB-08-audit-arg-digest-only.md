---
id: ROB-08
title: Audit records only an arg-digest, defeating forensics
severity: medium
category: robustness
status: open
affected_specs: [09-mcp-auth-proxy.md]
review_verdict: CONFIRMED
---

# ROB-08 — Audit records only an arg-digest, defeating forensics

## Problem

The `mcp-auth-proxy` audit log records only a **digest of the call arguments**
(09 §3.10). For a system whose entire purpose is bounding privileged external
action — refunds, wires, production writes — incident forensics needs to know *what*
was actually done. A digest proves integrity but reveals nothing, defeating the audit's
own reason to exist.

## Why it matters

The proxy is described as the best idea in the spec set precisely because every
privileged call is brokered and audited. An audit you can't read after the fact
undercuts the value proposition: you can prove a call happened but not reconstruct the
blast radius of a breach.

## Proposed change

Store **field-redacted structured arguments** under the gateway's existing
DLP/encryption machinery, and keep the digest **alongside** as an integrity check (not
as a replacement). DLP handles the secrets-leakage concern that motivated the
digest-only design.

## Acceptance

- [ ] Audit records contain replayable, field-redacted structured args.
- [ ] The digest is retained as an integrity/tamper-evidence companion.
- [ ] Redaction policy reuses the existing DLP DSL rather than introducing a new one.
