# Reputation Dynamics (W2) — Quint Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone `specs/quint/reputation.qnt` module that makes the Metatron reputation-weighting claim falsifiable — chronically-drifting agents decay to the floor, and a drift-flagged bloc cannot clear the ⅔ consensus threshold.

**Architecture:** A bounded, round-scored Quint state machine. State is two integer maps (`weight`, `driftCount`) over a 5-member council. Two update actions (`observeWrong`/`observeRight`) apply minimal integer decay/gain dynamics; three invariants (`weightBounded`, `driftDecaysWeight`, `swingResistance`) are bounded-model-checked by Apalache. Imports only `base` for the normative threshold predicates. Does not touch any other module.

**Tech Stack:** Quint 0.24.0 (pinned via `.mise.toml`, npm backend), Apalache 0.47.2 (JVM, `quint verify` backend), Temurin 21. Runner: mise tasks `quint-typecheck` / `quint-test` / `quint-verify`.

## Global Constraints

- **Quint version:** `0.24.0` exactly (`.mise.toml` `npm:@informalsystems/quint`). Honor its stdlib quirks: `Map.set(k,v)` requires `k` to already be a key (use `.put()` for a fresh key); there is no `getOrElse` (guard with `.keys().contains(...)` or a `k.in(m.keys())` check); a `val` binding inside `all { }` scopes over only the single next comma-item (wrap dependents in a nested `all { }`); a `val` whose body contains a lambda (`=>`) must be hoisted to a top-level `def`, not chained after another `val`.
- **Comments:** Quint has no `#` comments. The `# VERIFY:` directive lives *inside* a normal `//` line comment: `// # VERIFY: ...`.
- **Test naming:** `quint test` only runs `run`/`test` definitions whose name ends in `Test` (else silently skipped).
- **Verify discovery:** `verify.sh` loops over `specs/quint/*.qnt` and reads the first `// # VERIFY:` line per file — dropping the new module with that header auto-includes it in `quint-verify`. No `.mise.toml` or `verify.sh` edit is needed.
- **Abstraction conventions (from `specs/quint/README.md`):** ids are bounded ints; no crypto; model aggregators by their *properties*, not concrete formulas; domain bounds exist so bounded MC terminates. `00-overview.md` is normative for shared vocabulary (imported from `base`).
- **Parameters (design §Model, load-bearing):** `CAP=6`, `DECAY=2`, `DRIFT_LIMIT=3`, `START=4` ⟹ derived `DRIFT_WEIGHT_CAP = max(0, CAP - DRIFT_LIMIT*DECAY) = 0`. These are chosen so the suite is green; the `DECAY=1` mutation is a deliberate falsifiability probe (Task 6), not a shipped state.
- **Council fixture:** correlatable bloc `{1,2,3,4}`, honest anchor `{5}`. Only the bloc may be driven wrong in `step`; the anchor keeps total weight positive so `swingResistance` is non-degenerate.
- **Design source of truth:** `docs/superpowers/specs/2026-07-01-reputation-dynamics-quint-design.md`.

---

## File Structure

- **Create `specs/quint/reputation.qnt`** — the entire module (types, state, actions, invariants, scenarios, `// # VERIFY:` header). Self-contained; imports only `base`. This is the sole code artifact.
- **Modify `specs/quint/README.md`** — add one module-map row + a one-line abstraction note for the honest-anchor fixture.
- **Modify `specs/quint/FINDINGS.md`** — add traceability rows (3 MC + 3 scenarios), the fixture modeling-note, and the decay/threshold coupling headline finding.
- **Create `specs/issues/ROB-10-reputation-decay-threshold-coupling.md`** — filed only after Task 6 confirms the prose is silent on the quantitative decay/threshold precondition.

The module is built test-first: each invariant/scenario is a task that adds the property, drives it red where possible, then makes it green. Because Quint invariants are declarative, the "red" step for an MC invariant is a *deliberate mutation* that produces a counterexample, reverted before commit — this is how the suite proves non-vacuity (see `state_model.qnt` F2, `mailbox.qnt` F5 precedent).

---

### Task 1: Module scaffold — types, state, `init`, and a smoke invariant

**Files:**
- Create: `specs/quint/reputation.qnt`

**Interfaces:**
- Consumes: `base` exports `AgentId` (= `int`), `passesOrdinary(approveW, totalW): bool`, `passesConstitutional`, `isKernel`. Import with `import base.* from "./base"`.
- Produces: module `reputation` with vars `weight: AgentId -> int`, `driftCount: AgentId -> int`; constants `CAP`, `DECAY`, `DRIFT_LIMIT`, `START`, `DRIFT_WEIGHT_CAP`; helper `max2(a,b): int`; action `init`; invariant `weightBounded`.

- [ ] **Step 1: Write the module with state, constants, `init`, and the `weightBounded` invariant**

Create `specs/quint/reputation.qnt`:

```quint
// # VERIFY: weightBounded
module reputation {
  import base.* from "./base"

  // reputation weight, integer proxy in [0..CAP] (00 uses f32 in [0,1]; ints keep MC
  // decidable, mirroring base.qnt's CostUnit convention). driftCount = consecutive
  // rounds voting against ground truth; resets to 0 on any correct vote.
  var weight: AgentId -> int
  var driftCount: AgentId -> int

  pure val CAP         = 6
  pure val DECAY       = 2
  pure val DRIFT_LIMIT = 3
  pure val START       = 4
  // derived: provable weight ceiling for a tainted agent (= 0 at these params)
  pure val DRIFT_WEIGHT_CAP = maxInt(0, CAP - DRIFT_LIMIT * DECAY)

  pure def maxInt(a: int, b: int): int = if (a > b) a else b
  pure def minInt(a: int, b: int): int = if (a < b) a else b

  // council: correlatable bloc {1,2,3,4} + honest anchor {5}
  pure val bloc    = Set(1, 2, 3, 4)
  pure val council = Set(1, 2, 3, 4, 5)

  action init = all {
    weight'     = council.mapBy(_ => START),
    driftCount' = council.mapBy(_ => 0),
  }

  // --- invariants ---
  val weightBounded =
    weight.keys().forall(a => 0 <= weight.get(a) and weight.get(a) <= CAP)
}
```

- [ ] **Step 2: Typecheck to verify the scaffold is well-formed**

Run: `mise run quint-typecheck 2>&1 | grep -A3 reputation.qnt`
Expected: `== specs/quint/reputation.qnt` followed by no `[QNT...]` error lines (Quint prints nothing on a clean typecheck).

If `mapBy` is unavailable in 0.24.0, fall back to an explicit literal:
`weight' = Map(1 -> START, 2 -> START, 3 -> START, 4 -> START, 5 -> START)` (and the analogous `Map(1 -> 0, ...)` for `driftCount'`). Re-run the typecheck.

- [ ] **Step 3: Verify `weightBounded` holds at `init` (no `step` yet)**

Run: `quint verify --invariant=weightBounded specs/quint/reputation.qnt`
Expected: `[ok] No violation found` (only `init` is reachable; all weights = `START = 4`, within `[0,6]`).

Note: benign `io.netty`/gRPC shutdown stack-trace noise may print — it is Apalache's local health-check probe and does not affect the `[ok]` outcome (documented in `FINDINGS.md` §1.3).

- [ ] **Step 4: Commit**

```bash
git add specs/quint/reputation.qnt
git commit -m "feat(quint): reputation.qnt scaffold — state, params, weightBounded"
```

---

### Task 2: `observeWrong` / `observeRight` actions + `step`, keep `weightBounded` green

**Files:**
- Modify: `specs/quint/reputation.qnt`

**Interfaces:**
- Consumes: vars and constants from Task 1.
- Produces: actions `observeWrong(a: AgentId): bool`, `observeRight(a: AgentId): bool`, `idle: bool`, and `step` (an `any { }` over them). After this task the model has a non-trivial reachable state space.

- [ ] **Step 1: Add the two update actions, `idle`, and `step`**

Insert after `init` in `specs/quint/reputation.qnt`:

```quint
  // one scoring round for agent a whose vote went AGAINST ground truth
  action observeWrong(a: AgentId): bool = all {
    a.in(weight.keys()),
    weight'     = weight.set(a, maxInt(0, weight.get(a) - DECAY)),
    driftCount' = driftCount.set(a, driftCount.get(a) + 1),
  }
  // one scoring round for agent a whose vote MATCHED ground truth
  action observeRight(a: AgentId): bool = all {
    a.in(weight.keys()),
    weight'     = weight.set(a, minInt(CAP, weight.get(a) + 1)),
    driftCount' = driftCount.set(a, 0),
  }
  // no-op stutter so `step` never deadlocks for Apalache once activity stops — a
  // model-completeness artifact of the bounded fixture, not a weakening of any
  // invariant (every invariant is still checked at every state, idle ones included).
  // Same rationale as consensus.qnt / mailbox.qnt idle actions.
  action idle: bool = all { weight' = weight, driftCount' = driftCount }

  // only the bloc {1,2,3,4} may be driven wrong; the honest anchor {5} is only ever
  // observed right, keeping total council weight positive so swingResistance stays a
  // non-degenerate check of the decay dynamics (design §Fixture rationale).
  action step = any {
    nondet a = bloc.oneOf() observeWrong(a),
    nondet a = council.oneOf() observeRight(a),
    idle,
  }
```

- [ ] **Step 2: Typecheck**

Run: `quint typecheck specs/quint/reputation.qnt`
Expected: no `[QNT...]` error output, exit 0.

- [ ] **Step 3: Model-check `weightBounded` over the full step relation**

Run: `quint verify --invariant=weightBounded specs/quint/reputation.qnt`
Expected: `[ok] No violation found`. (`observeWrong` floors at 0; `observeRight` caps at `CAP`; so weights never leave `[0,6]` under any reachable trace.)

- [ ] **Step 4: Sanity-check the update rule with a throwaway trace (optional, not committed)**

Run: `quint run --max-steps=5 --invariant=weightBounded specs/quint/reputation.qnt`
Expected: a random 5-step trace prints and ends `[ok]` — confirms `step` actually advances state (weights move) rather than only `idle`-ing.

- [ ] **Step 5: Commit**

```bash
git add specs/quint/reputation.qnt
git commit -m "feat(quint): reputation observe actions + step; weightBounded holds over step"
```

---

### Task 3: `driftDecaysWeight` invariant (decay-to-floor, coupling lemma)

**Files:**
- Modify: `specs/quint/reputation.qnt`

**Interfaces:**
- Consumes: `driftCount`, `weight`, `DRIFT_LIMIT`, `DRIFT_WEIGHT_CAP`.
- Produces: invariant `driftDecaysWeight`; adds it to the `// # VERIFY:` header.

- [ ] **Step 1: Add the invariant**

Insert in the invariants block of `specs/quint/reputation.qnt`:

```quint
  // A persistent drifter's weight is provably bounded by the derived ceiling. Because
  // DRIFT_WEIGHT_CAP is DEFINED as max(0, CAP - DRIFT_LIMIT*DECAY), this holds by
  // construction for any DECAY — it is a WELL-FORMEDNESS check (catches update-rule
  // bugs: a missing floor, decaying the wrong agent, an off-by-one streak counter). It
  // does NOT by itself catch a mis-tuned decay RATE — that is swingResistance's job
  // (Task 5). Deliberate division of labor (design §Invariants).
  val driftDecaysWeight =
    weight.keys().forall(a =>
      driftCount.get(a) >= DRIFT_LIMIT implies weight.get(a) <= DRIFT_WEIGHT_CAP)
```

- [ ] **Step 2: Add `driftDecaysWeight` to the VERIFY header**

Change line 1 of `specs/quint/reputation.qnt` from:
`// # VERIFY: weightBounded`
to:
`// # VERIFY: weightBounded, driftDecaysWeight`

- [ ] **Step 3: Prove it is non-vacuous by a deliberate mutation (RED)**

Temporarily break the flooring in `observeWrong` — change `maxInt(0, weight.get(a) - DECAY)` to `weight.get(a) - DECAY` (no floor). Then:

Run: `quint verify --invariant=driftDecaysWeight specs/quint/reputation.qnt`
Expected: `[violation] Found an issue` with a counterexample trace where a bloc agent's `driftCount >= 3` but its weight is negative (e.g. `-2`), violating `weight <= DRIFT_WEIGHT_CAP = 0`. This confirms the invariant actually constrains reachable states.

- [ ] **Step 4: Revert the mutation and confirm GREEN**

Restore `observeWrong` to `maxInt(0, weight.get(a) - DECAY)`. Then:

Run: `quint verify --invariant="weightBounded, driftDecaysWeight" specs/quint/reputation.qnt`
Expected: `[ok] No violation found` for both. (From any start ≤ `CAP=6`, three decays of 2 reach 0 ≤ `DRIFT_WEIGHT_CAP`.)

- [ ] **Step 5: Commit**

```bash
git add specs/quint/reputation.qnt
git commit -m "feat(quint): driftDecaysWeight invariant (decay-to-floor coupling lemma)"
```

---

### Task 4: `chronicDriftReachesFloorTest` scenario (concrete decay-to-floor witness)

**Files:**
- Modify: `specs/quint/reputation.qnt`

**Interfaces:**
- Consumes: `init`, `observeWrong`, `weight`, `driftCount`.
- Produces: `run chronicDriftReachesFloorTest` — proves the floor is *reachable*, not merely bounded.

- [ ] **Step 1: Write the scenario**

Insert a `// --- scenarios ---` section at the end of the module body:

```quint
  // --- scenarios ---
  // Decay-to-floor is REACHED, not just bounded: agent 1, observed wrong DRIFT_LIMIT
  // times from START=4 (4 -> 2 -> 0 -> 0), lands at weight 0 with driftCount 3.
  run chronicDriftReachesFloorTest =
    init.then(observeWrong(1)).then(observeWrong(1)).then(observeWrong(1))
        .then(all {
          assert(weight.get(1) == 0 and driftCount.get(1) == DRIFT_LIMIT),
          weight' = weight, driftCount' = driftCount,
        })
```

- [ ] **Step 2: Run the scenario to verify it passes**

Run: `quint test specs/quint/reputation.qnt`
Expected: output lists `chronicDriftReachesFloorTest` under passing tests, plus the two `base`-inherited tests (`kernelClassificationTest`, `thresholdMathTest`), `ok` / `0 failed`.

- [ ] **Step 3: Verify the assertion is real by tightening it to a wrong value (RED, then revert)**

Temporarily change `weight.get(1) == 0` to `weight.get(1) == 1`. Run `quint test specs/quint/reputation.qnt` — expected: `chronicDriftReachesFloorTest` **fails** (actual weight is 0). Revert to `== 0` and re-run — expected: passes again.

- [ ] **Step 4: Commit**

```bash
git add specs/quint/reputation.qnt
git commit -m "test(quint): chronicDriftReachesFloorTest — decay reaches the floor"
```

---

### Task 5: `swingResistance` invariant (headline) + `blocDefangedTest`

**Files:**
- Modify: `specs/quint/reputation.qnt`

**Interfaces:**
- Consumes: `weight`, `driftCount`, `DRIFT_LIMIT`, `council`, `base.passesOrdinary`.
- Produces: defs `taintedWeight`, `totalWeight`; invariant `swingResistance`; scenario `blocDefangedTest`; `swingResistance` added to the VERIFY header.

- [ ] **Step 1: Add the summed-weight helpers and the invariant**

Insert in the invariants block:

```quint
  // summed weight of drift-flagged agents (tainted = a persistent drifter)
  def taintedWeight =
    council.filter(a => driftCount.get(a) >= DRIFT_LIMIT)
           .fold(0, (s, a) => s + weight.get(a))
  def totalWeight = council.fold(0, (s, a) => s + weight.get(a))

  // HEADLINE: even if the ENTIRE drift-flagged bloc votes Approve, its combined weight
  // cannot meet the 2/3 ordinary threshold — a correlated, persistently-wrong bloc
  // cannot unilaterally carry a proposal (the ROB-02 "correlated bloc loses its teeth"
  // claim). Checked against base.passesOrdinary — the SAME predicate consensus.qnt's
  // `decide` uses — so the swing test and the live threshold cannot silently diverge.
  // Reasons in ABSOLUTE threshold terms, so a too-slow DECAY (which merely raises the
  // derived DRIFT_WEIGHT_CAP) is caught here as a reachable counterexample (Task 6).
  val swingResistance = not(passesOrdinary(taintedWeight, totalWeight))
```

- [ ] **Step 2: Add `swingResistance` to the VERIFY header**

Change line 1 to:
`// # VERIFY: weightBounded, driftDecaysWeight, swingResistance`

- [ ] **Step 3: Add the non-vacuity scenario (tainted council is non-empty)**

Insert in the scenarios section:

```quint
  // Non-vacuity witness for swingResistance: drive the WHOLE bloc {1,2,3,4} past
  // DRIFT_LIMIT so the tainted set is non-empty, then assert the invariant holds over a
  // real tainted council (each bloc agent at weight 0; anchor 5 still at START).
  run blocDefangedTest =
    init.then(observeWrong(1)).then(observeWrong(2)).then(observeWrong(3)).then(observeWrong(4))
        .then(observeWrong(1)).then(observeWrong(2)).then(observeWrong(3)).then(observeWrong(4))
        .then(observeWrong(1)).then(observeWrong(2)).then(observeWrong(3)).then(observeWrong(4))
        .then(all {
          assert(council.filter(a => driftCount.get(a) >= DRIFT_LIMIT) == bloc
                 and swingResistance),
          weight' = weight, driftCount' = driftCount,
        })
```

- [ ] **Step 4: Run scenarios + model-check the invariant (GREEN)**

Run: `quint test specs/quint/reputation.qnt`
Expected: `blocDefangedTest` passes (tainted set equals `bloc`; `taintedWeight = 0`, so `passesOrdinary(0, totalWeight)` is false, `swingResistance` true).

Run: `quint verify --invariant=swingResistance specs/quint/reputation.qnt`
Expected: `[ok] No violation found`. At the calibrated params `DRIFT_WEIGHT_CAP = 0`, so any tainted agent has weight 0 and `taintedWeight` is always 0 while the honest anchor keeps `totalWeight > 0`.

- [ ] **Step 5: Commit**

```bash
git add specs/quint/reputation.qnt
git commit -m "feat(quint): swingResistance invariant + blocDefangedTest (ROB-02 teeth)"
```

---

### Task 6: Falsifiability probe — confirm `DECAY=1` breaks `swingResistance`; decide on ROB-10

**Files:**
- Modify (temporarily, reverted): `specs/quint/reputation.qnt`
- Create (conditionally): `specs/issues/ROB-10-reputation-decay-threshold-coupling.md`

**Interfaces:**
- Consumes: the finished module from Task 5.
- Produces: a captured Apalache counterexample proving the parameters are load-bearing; optionally a new issue file.

- [ ] **Step 1: Mutate `DECAY` to 1 and capture the counterexample (does NOT get committed)**

Temporarily change `pure val DECAY = 2` to `pure val DECAY = 1`. Then:

Run: `quint verify --invariant=swingResistance specs/quint/reputation.qnt`
Expected: `[violation] Found an issue` with a counterexample: a bloc agent climbs to `CAP=6` (via `observeRight`) then drifts `DRIFT_LIMIT=3` rounds at `DECAY=1` to weight 3; the 4-agent bloc holds `12`; against `totalWeight = 18` (bloc 12 + anchor 6), `passesOrdinary(12, 18)` is true (`3·12 = 36 ≥ 2·18 = 36`), so `swingResistance` is violated.

Save the trace: re-run with `--out-itf=/tmp/decay1-counterexample.itf.json` appended, for the FINDINGS write-up in Task 8.

- [ ] **Step 2: Revert `DECAY` to 2 and confirm GREEN again**

Restore `pure val DECAY = 2`. Run: `quint verify --invariant=swingResistance specs/quint/reputation.qnt`
Expected: `[ok] No violation found`. Confirm `git diff specs/quint/reputation.qnt` is empty (mutation fully reverted).

- [ ] **Step 3: Check whether the prose states the decay/threshold precondition**

Run: `grep -rn -iE "decay|drift|reputation" specs/00-overview.md specs/08-trust-and-security.md specs/issues/ROB-03-reputation-inert-at-genesis.md`
Read the hits. Decision rule: if none states a *quantitative* coupling between decay rate, the consensus pass threshold, and drift-detection lag (they assert "decays toward zero influence" qualitatively only), the prose has a genuine gap → create ROB-10 in Step 4. If some section already states the quantitative precondition, skip Step 4 and note in FINDINGS (Task 8) that the prose already covers it.

- [ ] **Step 4: (Conditional) File ROB-10**

Only if Step 3 found the prose silent. Create `specs/issues/ROB-10-reputation-decay-threshold-coupling.md` following the existing issue format (see `specs/issues/ROB-09-mailbox-safe-hold-multigate.md` for structure — front-matter `status:`, a "What / Why / Evidence / Suggested clarification" body). Content: the model shows reputation's "decay to zero influence" claim holds only when `|bloc| * max(0, CAP - DRIFT_LIMIT*DECAY)` stays below the ⅔ margin of total weight; the `DECAY=1` counterexample (Step 1) is the evidence; suggested clarification is to state the decay-rate precondition (or a reference to where it is tuned) alongside the qualitative claim in `00` §6.4 / ROB-03.

- [ ] **Step 5: Commit (issue file only, if created)**

```bash
git add specs/issues/ROB-10-reputation-decay-threshold-coupling.md
git commit -m "docs(issues): file ROB-10 — reputation decay/threshold coupling precondition"
```

If Step 3 determined no issue is warranted, skip this commit and record the rationale in Task 8 instead.

---

### Task 7: `honestAnchorSurvivesTest` scenario (swing check stays non-degenerate)

**Files:**
- Modify: `specs/quint/reputation.qnt`

**Interfaces:**
- Consumes: `init`, `observeRight`, `observeWrong`, `weight`, `totalWeight`, `START`.
- Produces: `run honestAnchorSurvivesTest`.

- [ ] **Step 1: Write the scenario**

Insert in the scenarios section:

```quint
  // The honest anchor, observed right, retains (>= START) its weight while the bloc
  // decays — keeping totalWeight > 0 so swingResistance is never the degenerate
  // "whole council captured, totalWeight = 0" case (design §Fixture rationale).
  run honestAnchorSurvivesTest =
    init.then(observeRight(5)).then(observeWrong(1)).then(observeWrong(2))
        .then(all {
          assert(weight.get(5) >= START and totalWeight > 0),
          weight' = weight, driftCount' = driftCount,
        })
```

- [ ] **Step 2: Run the scenario**

Run: `quint test specs/quint/reputation.qnt`
Expected: all four scenarios pass (`chronicDriftReachesFloorTest`, `blocDefangedTest`, `honestAnchorSurvivesTest`, + inherited base tests), `0 failed`.

- [ ] **Step 3: Commit**

```bash
git add specs/quint/reputation.qnt
git commit -m "test(quint): honestAnchorSurvivesTest — anchor keeps totalWeight positive"
```

---

### Task 8: Report-back — README module map, FINDINGS traceability, full-suite gate

**Files:**
- Modify: `specs/quint/README.md`
- Modify: `specs/quint/FINDINGS.md`

**Interfaces:**
- Consumes: the finished, green module + the Task 6 counterexample trace.
- Produces: updated suite documentation; a verified full-suite gate.

- [ ] **Step 1: Add the module-map row to README**

In `specs/quint/README.md`, in the `## Module map` code block, add under the `budgets.qnt` line:

```
  reputation.qnt         # 08 — reputation decay + swing-resistance          — written, verified
```

And in the coverage prose, note that `reputation.qnt` (from `08`) extends the suite beyond the original four-module spine, and add a one-line abstraction note: the honest-anchor fixture (`{5}` observed-right-only) is a deliberate bound that scopes swing-resistance to the sub-majority-bloc threat (full council capture is break-glass/ROB-04 territory, out of scope).

- [ ] **Step 2: Run the full suite gate and capture real results**

Run: `mise run quint-typecheck && mise run quint-test && mise run quint-verify`
Expected: typecheck clean (no `[QNT...]`); `quint test` shows the 3 new scenarios passing across all modules; `quint verify` prints `[ok] No violation found` for `reputation.qnt`'s three invariants (`weightBounded, driftDecaysWeight, swingResistance`) plus every pre-existing module still green.

Record the actual invariant results and wall-clock from THIS run — do not copy numbers from a prior run.

- [ ] **Step 3: Add FINDINGS traceability rows + the headline coupling finding**

In `specs/quint/FINDINGS.md`:
- Add a new `### 2.6 reputation.qnt` subsection (renumber the existing smoke subsection) with one row per invariant/scenario: `weightBounded` (`08`/`00` §7 `Reputation`, MC, holds), `driftDecaysWeight` (`00` §6.4 / ROB-03, MC, holds), `swingResistance` (`00` §6.3/§6.4, ROB-01/ROB-02, MC, holds), and the three scenarios.
- Add the `reputation.qnt` verify row to the §1.3 gate table with the real wall-clock from Step 2.
- Add a headline-finding entry (in the §3 style) describing the decay/threshold **coupling** the model exposes, using the Task 6 `DECAY=1` counterexample as evidence, and cross-referencing ROB-10 (or noting the prose already covers it, per Task 6 Step 3).
- Update the row-count and test-count totals in §2 and §8.

- [ ] **Step 4: Commit**

```bash
git add specs/quint/README.md specs/quint/FINDINGS.md
git commit -m "docs(quint): report-back reputation.qnt — README map + FINDINGS traceability"
```

---

## Self-Review

**Spec coverage** (design doc §§ → tasks):
- §Model state/constants → Task 1. §Actions/update rule → Task 2. §Fixture rationale → Tasks 2 (step constraint) + 7 (anchor scenario).
- §Invariants: `weightBounded` → Task 1; `driftDecaysWeight` → Task 3; `swingResistance` → Task 5.
- §Scenarios: `chronicDriftReachesFloorTest` → Task 4; `blocDefangedTest` → Task 5; `honestAnchorSurvivesTest` → Task 7.
- §Tuning finding (DECAY=1 counterexample) → Task 6. §Report-back deliverables (module, README, FINDINGS, ROB-10) → Tasks 1–7 (module), Task 6 (ROB-10), Task 8 (README/FINDINGS).
- §Success criteria: typecheck/test/verify green → Task 8 gate; non-vacuous swing → Task 5 Step 3–4; DECAY=1 falsifiability → Task 6; suite stays green → Task 8. All covered.

**Placeholder scan:** no TBD/TODO; every code step shows complete Quint; every run step gives an exact command + expected output. The one conditional (ROB-10 in Task 6) has an explicit decision rule and a documented fallback, not a vague "handle appropriately."

**Type/name consistency:** `weight`/`driftCount` (maps `AgentId -> int`); `CAP`/`DECAY`/`DRIFT_LIMIT`/`START`/`DRIFT_WEIGHT_CAP` (constants); `bloc`/`council` (`Set[int]`); `maxInt`/`minInt` (helpers); `observeWrong`/`observeRight`/`idle`/`step` (actions); `weightBounded`/`driftDecaysWeight`/`swingResistance` (invariants); `taintedWeight`/`totalWeight` (defs) — names are used identically across Tasks 1–8. `passesOrdinary` matches `base.qnt`'s exported signature. Header directive `// # VERIFY:` grows monotonically (Task 1 → 3 → 5) and is read by the existing `verify.sh` loop.

**Note on `mapBy`:** Task 1 Step 2 includes an explicit `Map(...)` literal fallback in case Quint 0.24.0's stdlib name differs — the plan does not hard-depend on `mapBy`.
