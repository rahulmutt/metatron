# Reputation Dynamics — Quint Model (W2) — Design

**Date:** 2026-07-01
**Status:** Approved design, pre-implementation
**Author:** brainstormed with Rahul Muttineni

## Purpose

Extend the Metatron Quint spec suite (`specs/quint/`) with a new `reputation.qnt`
module that **actively tests** the reputation-weighting principle the existing suite
leaves entirely static. Today `consensus.qnt` initializes `weight` to a frozen map and
never updates it; the whole "weight by calibrated track record, decays on drift"
principle (`00` §6.4, ROB-03) is proxied only by a static `burnIn` boolean. The
load-bearing claim — *chronically-drifting agents decay toward zero influence, so a
correlated confidently-wrong bloc loses its power to swing an outcome* — is currently
**unexercised**.

This module makes that claim falsifiable. Like every module in the suite, it is a
**verification artifact**, not a re-implementation: a bounded state machine whose
invariants are checked by typecheck + scenario tests + Apalache bounded model-checking,
reporting back to the prose specs via `FINDINGS.md` and (where it surfaces a genuine
prose gap) `specs/issues/`.

## Provenance — how this pass was scoped

This is workstream **W2** from a triage of what the Quint models reveal about the design.
The triage grouped eight findings into four workstreams:

- **W1** — Consensus round lifecycle (quorum redundancy, multi-round deadlock, deliberation/dispersion).
- **W2** — Reputation dynamics *(this doc)*.
- **W3** — Cross-module composition (commit→head, notifier→mailbox seams).
- **W4** — Security & cleanup (equivocation, dead `Throttled` state, `VReport` collapse).

W2 was chosen first: it is the highest-risk *standalone* hole (a headline design claim
with zero dynamic coverage) and, unlike W1, needs no design fork settled before it can
be modeled.

## Scope

Decisions locked during brainstorming:

| Decision | Choice |
|----------|--------|
| **Properties in scope** | (1) **Monotone decay-to-floor** — a chronically-wrong agent's weight is non-increasing and reaches the floor within bounded rounds. (2) **Swing-resistance** — a drift-flagged bloc's combined weight cannot clear the ⅔ pass threshold. |
| **Properties out of scope** | *Recovery* (a drifter regaining weight — model permits it structurally but proves nothing about it) and *calibration-gates-autonomy* (replacing the static `burnIn` flag). Deferred; this is a **punitive-decay** pass. |
| **Hosting** | New **standalone `reputation.qnt`** importing only `base`. Not an extension of `consensus.qnt` (which would entangle W2 with the unsettled W1 multi-round work and bloat a dense module). |
| **Ground truth** | A fully **abstract per-observation oracle** — an observation *is* the post-hoc reveal of whether an agent's vote matched reality (`07`/`08` in the real system). The proposal itself is not modeled, per the suite's "model by properties, not by concrete formula" convention. |
| **Fixture** | A **correlatable bloc `{1,2,3,4}`** (which `step` may drive wrong) plus a **single honest anchor `{5}`** (only ever observed right). Documented deliberate constraint — see §Fixture rationale. |
| **On findings** | Same convention as the rest of the suite: `FINDINGS.md` traceability rows; genuine prose gaps get a new `specs/issues/` file; `specs/*.md` prose bodies are edited only if the follow-up constraint permits (the suite has since lifted the "never edit prose" rule — see ROB-09). |

### Hosting options considered

- **Standalone `reputation.qnt` (chosen).** Isolated round-scored state machine, imports
  only `base`. Reputation *decay* is inherently multi-round, but this module supplies its
  own round-iteration structure abstractly (each `observe*` action is one scoring round),
  so it needs nothing from `consensus.qnt`'s single-round funnel. Matches the
  module-per-subsystem convention (reputation is `08`-owned). Swing-resistance is checked
  against `base`'s normative `passesOrdinary` — one abstraction layer removed from the
  live `decide`, accepted as the standard "abstract seam" trade-off.
- **Extend `consensus.qnt` with a real multi-round loop.** Most faithful (reputation feeds
  the live `decide` threshold), but drags in all of W1's rounds machinery, bloats a
  246-line dense module, raises MC cost, and couples W2's fate to the W1 fork. Rejected.
- **Scenario-only.** Prove decay via named `run` tests, drop the bounded-MC swing
  invariant. Surrenders the swing-resistance *guarantee*. Rejected.

## Model

### Types & state

```
// weight: reputation weight, an integer proxy in [0..CAP] (00 uses f32 in [0,1];
//         ints keep MC decidable, per base.qnt's CostUnit convention).
var weight:     AgentId -> int
// driftCount: consecutive rounds this agent voted against ground truth. Resets to 0
//             on any correct vote. Distinguishes a persistent drifter from a one-off miss.
var driftCount: AgentId -> int
```

Constants (tunable; the calibrated values are the point — see §Tuning finding):

```
pure val CAP         = 6   // max reputation weight
pure val DECAY       = 2   // weight lost per wrong round
pure val DRIFT_LIMIT = 3   // consecutive wrongs after which an agent is "tainted"/drift-flagged
pure val START       = 4   // initial weight for every council member
// derived: the provable weight ceiling for a tainted agent
pure val DRIFT_WEIGHT_CAP = max(0, CAP - DRIFT_LIMIT * DECAY)   // = 0 at these values
```

Council fixture: `{1,2,3,4}` = correlatable bloc, `{5}` = honest anchor. All start at
`START`.

### Actions

```
action init          // weight = Map(1..5 -> START), driftCount = all 0
action observeWrong(a): // weight' = max(0, weight[a] - DECAY); driftCount' = driftCount[a] + 1
action observeRight(a): // weight' = min(CAP, weight[a] + 1); driftCount' = 0
action idle          // no-op stutter (same model-completeness rationale as consensus/mailbox)
action step = any {
  nondet a = Set(1,2,3,4).oneOf() observeWrong(a),   // only the bloc may drift
  nondet a = Set(1,2,3,4,5).oneOf() observeRight(a),  // anyone may be observed correct
  idle,
}
```

The update rule is deliberately minimal integer dynamics — the smallest thing that lets
decay-to-floor be *reached* and swing-resistance be *checked*. It is not a calibration
formula; per suite convention the reputation aggregator is modeled by its properties.

### Fixture rationale (documented abstraction choice)

The honest anchor `{5}` is only ever observed right. This is a **deliberate constraint**,
not an oversight: it keeps total council weight from collapsing to zero, so
swing-resistance tests the *decay dynamics* rather than tripping on the degenerate
"entire council captured" state. A fully-drifted council (no honest weight left) is a
real but **different** threat — reputation cannot save it; recomposition / break-glass
does (ROB-04, workstream W1), which is explicitly out of scope here. This mirrors how
`consensus.qnt` fixes `familyOf` and `state_model.qnt` fixes GENESIS honesty by
construction. It is recorded as a modeling note in `FINDINGS.md`, not hidden.

### Invariants (`# VERIFY:`)

1. **`weightBounded`** — well-formedness / MC sanity:
   `weight.keys().forall(a => 0 <= weight.get(a) and weight.get(a) <= CAP)`.

2. **`driftDecaysWeight`** — *monotone decay-to-floor, in invariant form* (the coupling
   lemma): `driftCount[a] >= DRIFT_LIMIT implies weight[a] <= DRIFT_WEIGHT_CAP`. A
   persistent drifter's weight is provably bounded by the derived ceiling. Because
   `DRIFT_WEIGHT_CAP` is *defined* as `max(0, CAP - DRIFT_LIMIT*DECAY)`, this invariant
   holds **by construction** for any `DECAY` — it is a real *well-formedness* check (it
   catches update-rule bugs: a missing floor, decaying the wrong agent, an off-by-one in
   the streak counter), but it does **not** by itself catch a mis-tuned decay *rate*.
   That is `swingResistance`'s job — the two invariants have a deliberate division of
   labor.

3. **`swingResistance`** — *the headline, and the invariant that catches miscalibration*:
   `not passesOrdinary(taintedWeight, totalWeight)`, where
   `taintedWeight = Σ weight[a] for a in council with driftCount[a] >= DRIFT_LIMIT`
   and `totalWeight = Σ weight[a] over the council`. In words: **even if the entire
   drift-flagged bloc votes Approve, its combined weight cannot meet the ⅔ bar** — so a
   correlated persistently-wrong bloc cannot unilaterally carry a proposal. Checked
   against `base.passesOrdinary` (the same predicate `consensus.qnt`'s `decide` uses), so
   the swing test and the live threshold cannot silently diverge. Unlike
   `driftDecaysWeight`, this reasons in *absolute* threshold terms, so a too-slow `DECAY`
   (which merely raises the derived `DRIFT_WEIGHT_CAP`) leaves the bloc holding enough
   summed weight to clear ⅔ — a genuine, reachable counterexample.

### Scenarios (`run …Test`)

- **`chronicDriftReachesFloorTest`** — `observeWrong(1)` repeated `DRIFT_LIMIT` times;
  assert `weight[1] == 0`. Concrete decay-to-floor witness (proves the floor is
  *reachable*, not merely bounded).
- **`blocDefangedTest`** — drive the whole `{1,2,3,4}` bloc past `DRIFT_LIMIT`; assert
  `swingResistance` holds over a **non-empty tainted council** (non-vacuity witness — the
  invariant is otherwise trivially true while no agent is tainted).
- **`honestAnchorSurvivesTest`** — the honest anchor, observed right, retains/gains weight
  while the bloc decays; asserts `weight[5] >= START` and `totalWeight > 0` (keeps the
  swing check non-degenerate, and demonstrates the calibrated/rising side of the rule).

## Tuning finding this surfaces

The parameters above are chosen so the suite is **green**: `DRIFT_WEIGHT_CAP = 0`, so a
tainted bloc holds zero weight and `swingResistance` is robust.

The **value** is the coupling the model exposes. The safety of swing-resistance reduces
to a parameter-level constraint: in the worst case the whole bloc sits at the derived
ceiling, so we need `passesOrdinary(|bloc| * DRIFT_WEIGHT_CAP, totalWeight)` to be
**false**. At the calibrated values `DRIFT_WEIGHT_CAP = 0`, so this is trivially safe.
Set `DECAY = 1` (all else equal) and `DRIFT_WEIGHT_CAP` rises to `6 - 3 = 3`: a bloc
member that has climbed to `CAP` and then drifted `DRIFT_LIMIT = 3` rounds still holds
`3` weight, the 4-agent bloc holds `12`, and against a total of `18` (bloc `12` + honest
anchor at `6`) that clears the ⅔ bar (`3·12 = 36 ≥ 2·18 = 36`) — the confidently-wrong
bloc swings the outcome, and Apalache returns the concrete climb-then-drift trace. This
turns *"how fast must reputation decay relative to the consensus threshold and the
drift-detection lag"* from a prose assertion into a **checked constraint**. That
counterexample walkthrough will be the headline entry in the `FINDINGS.md` for this pass.

## Report-back deliverables

Matching the suite's existing convention:

- **`specs/quint/reputation.qnt`** — the module (with `# VERIFY:` header so `verify.sh`
  auto-discovers it; no infra change needed).
- **`specs/quint/README.md`** — new module-map row:
  `reputation.qnt  # 08 — reputation decay + swing-resistance`, and (if needed) an
  abstraction-conventions note for the honest-anchor fixture.
- **`specs/quint/FINDINGS.md`** — traceability rows for the 3 MC invariants + 3 scenarios
  (invariant → spec § → method → result), a modeling-note for the fixture constraint, and
  the decay/threshold **coupling** headline finding + its counterexample walkthrough.
- **`specs/issues/ROB-10-reputation-decay-threshold-coupling.md`** *(likely)* — `00` §6.4
  / ROB-03 assert drifters "decay toward zero influence" but never state the *quantitative
  precondition* (decay rate vs. pass threshold vs. drift-detection lag) that makes it true.
  The model makes that precondition explicit and checkable — a genuine prose-clarification
  candidate, in the same pattern as ROB-09. Filed only if the implementation confirms the
  prose is silent on it.

## Success criteria

- `reputation.qnt` typechecks, all 3 scenarios pass (`quint test`), and all 3 MC
  invariants verify `NoError` under Apalache at the module's declared bound.
- `blocDefangedTest` exercises `swingResistance` over a **non-empty tainted** council
  (the invariant is demonstrably non-vacuous).
- The `DECAY = 1` mutation is confirmed to produce an Apalache counterexample against
  `swingResistance` (or `driftDecaysWeight`) — proving the property is genuinely
  falsifiable and the calibrated parameters are load-bearing, not decorative.
- Full-suite gate stays green (`quint-typecheck`, `quint-test`, `quint-verify`).

## Out of scope (explicit)

- Recovery dynamics and any recovery invariant.
- Replacing / wiring into `consensus.qnt`'s static `burnIn` flag.
- Any change to `consensus.qnt`, the W1 multi-round lifecycle, or cross-module
  composition (W3).
- A concrete calibration formula for reputation (`f32` Bayesian update, class priors,
  decay half-life) — the model uses minimal integer dynamics and checks *properties*.
