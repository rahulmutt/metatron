---
id: OE-04
title: Hand-rolled Merkle DAG storage engine for a linear log
severity: medium
category: overengineering
status: resolved
affected_specs: [01-state-model.md]
review_verdict: SOFTENED
---

# OE-04 — Hand-rolled Merkle DAG storage engine for a linear log

## Problem

`01-state-model.md` proves the head is a **serialized, single-writer, linear chain**
of signed commits — then builds database-grade machinery on top of it: HAMT/MST
collections (leaf structure left unchosen: "HAMT or MST"), path-copying, epoch GC,
snapshots, compaction, differential retention, and versioned-codec replay.

That is a bespoke content-addressed store for an artifact the same spec shows is a
signed linear log.

## Why it matters

This is the most over-built subsystem relative to what it stores. Each of those
mechanisms is its own correctness surface (GC, compaction, codec migration) for a
v0.1 design, and the "is it HAMT or MST" non-decision shows the structure isn't yet
load-bearing.

## Proposed change

Use **git or a hash-chained append-only table** for the store: content-addressing,
tamper-evidence, structural sharing, and per-path history come off the shelf. **Keep**
the genuinely valuable parts — the typed-diff algebra and the invariant checks — and
drop the bespoke store / GC / clock apparatus.

## Steelman caveat

01 is the strongest spec in the set and is self-aware (it explicitly *drops* a vector
clock it judged unnecessary). The diff algebra and invariant checks earn their keep.
The objection is only to the bespoke storage/GC/collection engine, not to the
content-addressed signed-log model.

## Acceptance

- [ ] A decision is recorded: adopt an off-the-shelf content-addressed store, or
      justify the bespoke engine against a concrete requirement git can't meet.
- [ ] If bespoke is kept, the HAMT-vs-MST non-decision is resolved.
- [ ] Three clocks (§ logical time) reduced to one counter + one human hint, or
      justified.

## Resolution

Adopt an off-the-shelf content-addressed store (git or a hash-chained append-only table)
for the head. Keep the genuinely valuable parts — the typed-diff algebra and the
invariant checks — and drop the bespoke store / GC / collection engine. Reduce the three
logical clocks to one counter + one human hint.

Rationale: the head is a serialized, single-writer linear log, so content-addressing,
tamper-evidence, structural sharing, and per-path history come off the shelf; the bespoke
HAMT/MST + path-copying + epoch GC + compaction + codec-replay machinery is unjustified
correctness surface for a v0.1 design, and the unresolved "HAMT or MST" non-decision
shows it was never load-bearing.

Coverage: satisfies all three checks — the off-the-shelf store is adopted (which moots
the HAMT-vs-MST non-decision rather than forcing it), and the clocks collapse to one
counter plus a human hint.
