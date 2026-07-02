# Sentinel→Reputation Gate — Quint Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `specs/quint/sentinel.qnt` module that formally re-checks ROB-06 ("no single agent swings consensus" on the Sentinel path) — proving the k-of-n corroboration gate has no guard bug, while surfacing three indirect bypass paths as filed ROBs.

**Architecture:** A standalone bounded state machine (imports only `base`) modeling a council of 5 voters with integer reputation=vote weight, a Sentinel population split into a correlated bloc and an honest watcher, a k-of-n corroboration gate on slashing, a quorum-gated quarantine, and a single-Sentinel emergency-deopt→G1 retro-scoring path. Well-formedness invariants are model-checked with Apalache; the three attacks are proven reachable with concrete `run` witnesses. Findings report back via `FINDINGS.md` and new `specs/issues/` files. This is a verification artifact, not a re-implementation.

**Tech Stack:** Quint 0.32.0 (`npm:@informalsystems/quint`, pinned in `.mise.toml`), Apalache (JVM backend, `APALACHE_HOME`), Java temurin-21. Mise tasks: `quint-typecheck`, `quint-test`, `quint-verify`.

## Global Constraints

- **Toolchain, pinned:** Quint `0.32.0`, Java `temurin-21`, Apalache at `$APALACHE_HOME` — copied verbatim from `/workspace/.mise.toml`. Do not add or change dependencies.
- **Ids → bounded `int`.** All identifiers are small bounded integer domains chosen so Apalache terminates (per `specs/quint/README.md` abstraction conventions). Weights are integer proxies (00 uses f32; ints keep MC decidable, per `base.qnt`'s `CostUnit` convention).
- **Imports only `base`.** Cross-subsystem concepts (G0 verification, G1 outcome scoring) are abstract oracles/parameters, never real imports — so the module stays independently falsifiable. Threshold checks go through `base.passesOrdinary` so the model and the live `decide` cannot silently diverge.
- **`# VERIFY:` header convention.** The module's model-checked invariants are listed in a top-of-file `// # VERIFY: inv1, inv2, ...` comment so `verify.sh` auto-discovers them. No infra change is needed to add a module.
- **Idle stutter.** Every module includes a no-op `idle` action so Apalache's `step` never deadlocks once activity stops — a model-completeness artifact, not a weakening (same rationale as `reputation.qnt`/`consensus.qnt`/`mailbox.qnt`).
- **Report-back is additive by default.** New findings get `FINDINGS.md` rows and new `specs/issues/` files; `specs/*.md` prose bodies are edited only where a follow-up constraint explicitly permits (here: ticking one ROB-06 acceptance box).
- **Commit discipline:** frequent, one logical change per commit, conventional-commit prefixes (`feat(quint):`, `test(quint):`, `docs(quint):`, `docs(issues):`) matching the existing git log.

## File Structure

- **Create:** `specs/quint/sentinel.qnt` — the module. One responsibility: the Sentinel→reputation→vote-weight gate and its three bypass witnesses. Built up across Tasks 1–7.
- **Modify:** `specs/quint/README.md` — add the module-map row + abstraction note (Task 8).
- **Modify:** `specs/quint/FINDINGS.md` — traceability rows + the three attack findings (Task 9).
- **Create:** `specs/issues/ROB-11-sentinel-corroboration-independence.md`, `ROB-12-slash-quarantine-composition.md`, `ROB-13-emergency-deopt-g1-laundering.md`, `ROB-14-embargo-votes-total-leak.md`, `ROB-15-under-declare-telemetry-evasion.md` (Task 10).
- **Modify:** `specs/issues/ROB-06-sentinel-consensus-sidedoor.md` — tick the re-check acceptance box (Task 10).
- **Modify:** `specs/issues/README.md` — add the five new index rows (Task 10).

No test harness file is created: Quint `run` scenarios and `# VERIFY:` invariants live inside the `.qnt` module and are discovered by the existing `mise` tasks and `verify.sh`.

**Note on TDD in Quint:** the "failing test" for a state machine is a `run` scenario that references an action/invariant not yet defined (typecheck/test error), or an invariant witness that fails until the action wiring is correct. Each task writes the check first, runs it to observe the expected failure, adds the minimal model wiring, then re-runs to green.

---

### Task 1: Module scaffold — state, constants, fixtures, `init`, `weightBounded`

**Files:**
- Create: `specs/quint/sentinel.qnt`

**Interfaces:**
- Consumes: `base.AgentId`, `base.passesOrdinary`, `base.CAP`-style bounded-int convention (defines its own `CAP`).
- Produces: state vars `weight`, `status`, `findings`, `deoptStorm`, `lastSlashCorroborators`, `lastQuarantinePassedQuorum`; type `Status`; constants `CAP START SLASH K STORM_LIMIT G1_PENALTY`; fixtures `faction honest council sBloc sHonest guilty`; `action init`; helpers `maxInt`, `activeTotalWeight`, `factionApproveWeight`; invariant `weightBounded`.

- [ ] **Step 1: Write the module with state, fixtures, `init`, and the first invariant**

```quint
// # VERIFY: weightBounded
module sentinel {
  import base.* from "./base"

  // reputation weight IS voting weight (08 §3.3, OE-05); integer proxy in [0..CAP]
  // (00 uses f32; ints keep MC decidable, per base.qnt's CostUnit convention).
  var weight: AgentId -> int
  // aggregation membership: a Quarantined voter is dropped from aggregation (08 §3.6).
  type Status = Active | Quarantined
  var status: AgentId -> Status
  // the live corroboration window: (sentinelId, targetId) findings not yet consumed.
  var findings: Set[(AgentId, AgentId)]
  // manufactured trap telemetry against the standing proposal (the G1 laundering path).
  var deoptStorm: int
  // ghosts: record the gate arithmetic at fire time so well-formedness is an invariant.
  var lastSlashCorroborators: int
  var lastQuarantinePassedQuorum: bool

  pure val CAP         = 6   // max reputation/voting weight
  pure val START       = 4   // initial weight for every council member
  pure val SLASH       = 3   // weight removed by a corroborated slash
  pure val K           = 2   // k-of-n corroboration threshold (07 §5.9 / 08 §3.6)
  pure val STORM_LIMIT = 2   // deopt count past which G1 retro-scoring bites jurors
  pure val G1_PENALTY  = 2   // weight an approving juror loses to G1 retro-scoring

  pure def maxInt(a: int, b: int): int = if (a > b) a else b

  // council fixture: compromised faction {1,2} (sub-2/3 at init by construction)
  // vs. honest {3,4,5}. Sentinel ids offset 10x so the two id spaces never alias.
  pure val faction = Set(1, 2)
  pure val honest  = Set(3, 4, 5)
  pure val council = Set(1, 2, 3, 4, 5)
  pure val sBloc   = Set(101, 102)   // correlated Sentinels (share a base model)
  pure val sHonest = Set(103)        // one independent Sentinel
  pure val guilty  = Set()           // ground truth: NO council member is actually guilty

  action init = all {
    weight'                    = council.mapBy(_ => START),
    status'                    = council.mapBy(_ => Active),
    findings'                  = Set(),
    deoptStorm'                = 0,
    lastSlashCorroborators'    = 0,
    lastQuarantinePassedQuorum' = false,
  }

  // weight summed over Active voters only (Quarantined are out of aggregation).
  def activeTotalWeight =
    council.filter(a => status.get(a) == Active).fold(0, (s, a) => s + weight.get(a))
  // approve weight the compromised faction can muster from its Active members.
  def factionApproveWeight =
    faction.filter(a => status.get(a) == Active).fold(0, (s, a) => s + weight.get(a))

  // --- invariants ---
  val weightBounded =
    weight.keys().forall(a => 0 <= weight.get(a) and weight.get(a) <= CAP)

  // temporary stutter so the module typechecks/tests before step is built (Task 6).
  action idle = all {
    weight' = weight, status' = status, findings' = findings, deoptStorm' = deoptStorm,
    lastSlashCorroborators' = lastSlashCorroborators,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }
  action step = idle
}
```

- [ ] **Step 2: Typecheck to verify it is well-formed**

Run: `cd /workspace && mise run quint-typecheck 2>&1 | grep -A3 sentinel`
Expected: `== specs/quint/sentinel.qnt` prints, no `[QNT...]` error lines follow (Quint prints nothing on a clean typecheck; absence of error output is the pass signal).

- [ ] **Step 3: Sanity-run the module's tests (none yet, but init/step must be valid)**

Run: `cd /workspace && quint test specs/quint/sentinel.qnt`
Expected: PASS — 2 inherited `base` tests (`kernelClassificationTest`, `thresholdMathTest`) run and pass; 0 sentinel-specific tests yet.

- [ ] **Step 4: Verify `weightBounded` holds under Apalache at the (trivial) init+idle machine**

Run: `cd /workspace && quint verify --invariant=weightBounded specs/quint/sentinel.qnt`
Expected: `[ok]` / `NoError` — with only `init` and `idle`, all weights stay at `START=4`, inside `[0,6]`.

- [ ] **Step 5: Commit**

```bash
cd /workspace && git add specs/quint/sentinel.qnt
git commit -m "feat(quint): sentinel.qnt scaffold — state, fixtures, weightBounded"
```

---

### Task 2: `raiseFinding` action + `singleFindingInertTest`

**Files:**
- Modify: `specs/quint/sentinel.qnt`

**Interfaces:**
- Consumes: `findings`, `status`, `weight`, `sBloc`, `sHonest`, `guilty` (Task 1).
- Produces: `action raiseFinding(s, a)`; `run singleFindingInertTest`.

- [ ] **Step 1: Write the failing witness test first**

Add inside the module (below the invariants):

```quint
  // ROB-06's literal guarantee: a lone finding moves no weight and evicts no voter.
  run singleFindingInertTest =
    init.then(raiseFinding(101, 3))
        .then(all {
          assert(weight.get(3) == START and status.get(3) == Active
                 and findings == Set((101, 3))),
          weight' = weight, status' = status, findings' = findings,
          deoptStorm' = deoptStorm, lastSlashCorroborators' = lastSlashCorroborators,
          lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
        })
```

- [ ] **Step 2: Run the test to verify it fails (action undefined)**

Run: `cd /workspace && quint test specs/quint/sentinel.qnt 2>&1 | tail -5`
Expected: FAIL — a name-resolution/typecheck error referencing `raiseFinding` (not yet defined).

- [ ] **Step 3: Add the minimal `raiseFinding` action**

Insert above the `idle` action:

```quint
  // A bloc Sentinel may target ANY council member; an honest Sentinel only the guilty
  // (i.e. never, in this fixture — guilty = {}). Findings accumulate; no weight moves.
  action raiseFinding(s: AgentId, a: AgentId): bool = all {
    a.in(council),
    or {
      s.in(sBloc),
      s.in(sHonest) and a.in(guilty),
    },
    findings' = findings.union(Set((s, a))),
    weight' = weight, status' = status, deoptStorm' = deoptStorm,
    lastSlashCorroborators' = lastSlashCorroborators,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /workspace && quint test specs/quint/sentinel.qnt 2>&1 | tail -5`
Expected: PASS — `singleFindingInertTest` passes (3 tests total: 2 inherited + 1).

- [ ] **Step 5: Commit**

```bash
cd /workspace && git add specs/quint/sentinel.qnt
git commit -m "feat(quint): raiseFinding action + singleFindingInert witness"
```

---

### Task 3: `corroboratedSlash` + `g0Slash` + `slashRequiresCorroboration` invariant + `soundSlashReachableTest`

**Files:**
- Modify: `specs/quint/sentinel.qnt`

**Interfaces:**
- Consumes: `findings`, `weight`, `K`, `SLASH`, `guilty`, `maxInt` (Tasks 1–2).
- Produces: `action corroboratedSlash(a)`, `action g0Slash(a)`; helper `corroboratorsOf(a)`; invariant `slashRequiresCorroboration`; `run soundSlashReachableTest`.

- [ ] **Step 1: Add `slashRequiresCorroboration` to the `# VERIFY:` header**

Change line 1 of `specs/quint/sentinel.qnt` from:

```quint
// # VERIFY: weightBounded
```
to:
```quint
// # VERIFY: weightBounded, slashRequiresCorroboration
```

- [ ] **Step 2: Write the failing invariant + witness first**

Add the invariant beside `weightBounded`:

```quint
  // ROB-06 acceptance box #1, in invariant form: every slash that has occurred was
  // backed by >= K DISTINCT sentinels. Catches guard bugs (slash on one finding, an
  // off-by-one corroboration count). Expected to HOLD — the prose fix is literally correct.
  val slashRequiresCorroboration =
    lastSlashCorroborators == 0 or lastSlashCorroborators >= K
```

And the witness (keeps the invariant non-vacuous by reaching a real slash):

```quint
  // Non-vacuity witness: two DISTINCT sentinels corroborate, slash fires, invariant holds
  // over a non-empty slash. weight 4 -> max(0, 4-3) = 1.
  run soundSlashReachableTest =
    init.then(raiseFinding(101, 3)).then(raiseFinding(102, 3)).then(corroboratedSlash(3))
        .then(all {
          assert(weight.get(3) == 1 and lastSlashCorroborators >= K
                 and slashRequiresCorroboration),
          weight' = weight, status' = status, findings' = findings,
          deoptStorm' = deoptStorm, lastSlashCorroborators' = lastSlashCorroborators,
          lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
        })
```

- [ ] **Step 3: Run the test to verify it fails (actions undefined)**

Run: `cd /workspace && quint test specs/quint/sentinel.qnt 2>&1 | tail -5`
Expected: FAIL — name-resolution error referencing `corroboratedSlash`.

- [ ] **Step 4: Add `corroboratedSlash`, `g0Slash`, and the `corroboratorsOf` helper**

Add the helper beside `activeTotalWeight`:

```quint
  // distinct sentinels with a live finding on a.
  def corroboratorsOf(a: AgentId): Set[AgentId] =
    findings.filter(f => f._2 == a).map(f => f._1)
```

Add the two actions above `idle`:

```quint
  // The corroborated path: enabled only when >= K DISTINCT sentinels have live findings
  // on a. Applies SLASH, consumes a's findings, records the corroboration count (ghost).
  action corroboratedSlash(a: AgentId): bool = all {
    corroboratorsOf(a).size() >= K,
    weight' = weight.set(a, maxInt(0, weight.get(a) - SLASH)),
    findings' = findings.filter(f => f._2 != a),
    lastSlashCorroborators' = corroboratorsOf(a).size(),
    status' = status, deoptStorm' = deoptStorm,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }

  // The OR-branch oracle (07 §5.9): adjudication through the deterministic G0 gate.
  // Enabled only for the GUILTY (never, in this fixture). The SOUND path — present so the
  // model records that a legitimate single-source slash exists, gated on soundness not count.
  action g0Slash(a: AgentId): bool = all {
    a.in(guilty),
    weight' = weight.set(a, maxInt(0, weight.get(a) - SLASH)),
    findings' = findings.filter(f => f._2 != a),
    lastSlashCorroborators' = K,   // G0 adjudication is treated as fully-authorized
    status' = status, deoptStorm' = deoptStorm,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /workspace && quint test specs/quint/sentinel.qnt 2>&1 | tail -5`
Expected: PASS — `soundSlashReachableTest` passes (4 tests total).

- [ ] **Step 6: Commit**

```bash
cd /workspace && git add specs/quint/sentinel.qnt
git commit -m "feat(quint): corroboratedSlash/g0Slash + slashRequiresCorroboration invariant"
```

---

### Task 4: `quarantine` action + `quarantineRequiresQuorum` invariant

**Files:**
- Modify: `specs/quint/sentinel.qnt`

**Interfaces:**
- Consumes: `status`, `factionApproveWeight`, `activeTotalWeight`, `base.passesOrdinary` (Tasks 1–3).
- Produces: `action quarantine(a)`; invariant `quarantineRequiresQuorum`.

- [ ] **Step 1: Add `quarantineRequiresQuorum` to the `# VERIFY:` header**

Change line 1 to:

```quint
// # VERIFY: weightBounded, slashRequiresCorroboration, quarantineRequiresQuorum
```

- [ ] **Step 2: Write the invariant first**

Add beside the other invariants:

```quint
  // ROB-06 acceptance box #2's sibling on the EVICTION path: a quarantine fires only when
  // the faction can carry an ordinary (2/3) TypedDiff. Expected to HOLD — the finding
  // (ROB-12) is that the quorum itself is manufacturable, not that this guard is buggy.
  val quarantineRequiresQuorum =
    lastQuarantinePassedQuorum or council.forall(a => status.get(a) == Active)
```

- [ ] **Step 3: Run the test to confirm the invariant references an undefined action path (fails at witness stage in Task 5)**

Run: `cd /workspace && quint verify --invariant=quarantineRequiresQuorum specs/quint/sentinel.qnt 2>&1 | tail -5`
Expected: `NoError` — vacuously, since no action sets `status` to `Quarantined` yet (the invariant holds because the right disjunct is always true). This confirms the invariant is well-formed; Task 5's attack makes it non-vacuous.

- [ ] **Step 4: Add the `quarantine` action**

Add above `idle`:

```quint
  // Ordinary (2/3) quarantine of a Worker-grade voter (08 §3.6): enabled iff the faction's
  // Active approve weight passes passesOrdinary over the Active total. Drops a from
  // aggregation. Checked against base.passesOrdinary — the SAME predicate decide uses.
  action quarantine(a: AgentId): bool = all {
    a.in(council),
    status.get(a) == Active,
    passesOrdinary(factionApproveWeight, activeTotalWeight),
    status' = status.set(a, Quarantined),
    lastQuarantinePassedQuorum' = true,
    weight' = weight, findings' = findings, deoptStorm' = deoptStorm,
    lastSlashCorroborators' = lastSlashCorroborators,
  }
```

- [ ] **Step 5: Typecheck to confirm the action is well-formed**

Run: `cd /workspace && quint typecheck specs/quint/sentinel.qnt && echo TYPECHECK_OK`
Expected: `TYPECHECK_OK` (no `[QNT...]` errors).

- [ ] **Step 6: Commit**

```bash
cd /workspace && git add specs/quint/sentinel.qnt
git commit -m "feat(quint): quarantine action + quarantineRequiresQuorum invariant"
```

---

### Task 5: `emergencyDeopt` + `g1Score` (the G1 laundering path)

**Files:**
- Modify: `specs/quint/sentinel.qnt`

**Interfaces:**
- Consumes: `deoptStorm`, `STORM_LIMIT`, `G1_PENALTY`, `honest`, `weight`, `maxInt` (Tasks 1–4).
- Produces: `action emergencyDeopt(s)`, `action g1Score`.

- [ ] **Step 1: Add the `emergencyDeopt` action**

Add above `idle`:

```quint
  // ONE sentinel, NO corroboration — the blessed reversible authority (08 §3.6). Raises
  // the trap storm against the standing proposal. No DIRECT weight change (it is "reversible").
  action emergencyDeopt(s: AgentId): bool = all {
    or { s.in(sBloc), s.in(sHonest) },
    deoptStorm' = deoptStorm + 1,
    weight' = weight, status' = status, findings' = findings,
    lastSlashCorroborators' = lastSlashCorroborators,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }
```

- [ ] **Step 2: Add the `g1Score` action (retroactive G1 scoring — the laundering)**

Add above `idle`:

```quint
  // Retroactive G1 scoring (02 §6.2): once a trap storm is observed, every APPROVING juror
  // (the honest voters, here) is scored down against the G1 outcome. This is the seam: a
  // "reversible" deopt storm becomes an IRREVERSIBLE weight move — with NO corroboration.
  action g1Score: bool = all {
    deoptStorm >= STORM_LIMIT,
    weight' = weight.keys().mapBy(a =>
      if (a.in(honest)) maxInt(0, weight.get(a) - G1_PENALTY) else weight.get(a)),
    status' = status, findings' = findings, deoptStorm' = deoptStorm,
    lastSlashCorroborators' = lastSlashCorroborators,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }
```

- [ ] **Step 3: Typecheck to confirm both actions are well-formed**

Run: `cd /workspace && quint typecheck specs/quint/sentinel.qnt && echo TYPECHECK_OK`
Expected: `TYPECHECK_OK`.

- [ ] **Step 4: Confirm existing tests still pass (no regression)**

Run: `cd /workspace && quint test specs/quint/sentinel.qnt 2>&1 | tail -5`
Expected: PASS — still 4 tests (2 inherited + `singleFindingInertTest` + `soundSlashReachableTest`); the new actions are not yet exercised by a scenario.

- [ ] **Step 5: Commit**

```bash
cd /workspace && git add specs/quint/sentinel.qnt
git commit -m "feat(quint): emergencyDeopt + g1Score — the reversible-authority G1 seam"
```

---

### Task 6: Wire the full `step` and verify all invariants hold under it

**Files:**
- Modify: `specs/quint/sentinel.qnt`

**Interfaces:**
- Consumes: every action from Tasks 2–5.
- Produces: the real `action step` (replacing the Task 1 `step = idle`).

- [ ] **Step 1: Replace the placeholder `step` with the full nondeterministic step**

Replace `action step = idle` with:

```quint
  // The adversary's move set. sBloc may raise findings on anyone and self-corroborate;
  // honest sentinel only on the (empty) guilty set; slashes, quarantines, deopts, G1
  // scoring, and idle are all enabled per their guards.
  action step = any {
    nondet s = sBloc.union(sHonest).oneOf()
      nondet a = council.oneOf() raiseFinding(s, a),
    nondet a = council.oneOf() corroboratedSlash(a),
    nondet a = council.oneOf() g0Slash(a),
    nondet a = council.oneOf() quarantine(a),
    nondet s = sBloc.union(sHonest).oneOf() emergencyDeopt(s),
    g1Score,
    idle,
  }
```

- [ ] **Step 2: Typecheck**

Run: `cd /workspace && quint typecheck specs/quint/sentinel.qnt && echo TYPECHECK_OK`
Expected: `TYPECHECK_OK`.

- [ ] **Step 3: Run the full verify pass over the three well-formedness invariants**

Run: `cd /workspace && bash specs/quint/verify.sh 2>&1 | grep -A2 sentinel`
Expected: `== verify specs/quint/sentinel.qnt: weightBounded, slashRequiresCorroboration, quarantineRequiresQuorum` followed by `[ok]` / `NoError`. These three HOLD over the full step — the gate has no guard bug. (If Apalache is slow at default depth, add `// # VERIFY-MAX-STEPS: 8` under the header, matching how `consensus.qnt`/`mailbox.qnt` bound their passes; record the chosen depth in the commit message.)

- [ ] **Step 4: Commit**

```bash
cd /workspace && git add specs/quint/sentinel.qnt
git commit -m "feat(quint): wire full step; three well-formedness invariants verify NoError"
```

---

### Task 7: The three attack witnesses (`blocCaptureTest`, `slashThenQuarantineTest`, `g1LaunderingTest`)

**Files:**
- Modify: `specs/quint/sentinel.qnt`

**Interfaces:**
- Consumes: all actions + `factionApproveWeight`, `activeTotalWeight`, `passesOrdinary`, `honest`, `START` (Tasks 1–6).
- Produces: `run blocCaptureTest`, `run slashThenQuarantineTest`, `run g1LaunderingTest`.

- [ ] **Step 1: Write the bloc-capture witness**

Add below the existing `run`s. The correlated bloc {101,102} slashes honest voters 3,4,5 to zero (each 4→1→0 over two slashes), leaving faction {1,2}=8 as the only Active weight, which trivially passes ⅔:

```quint
  // ATTACK 1 (ROB-11): the correlated sentinel bloc {101,102} self-corroborates to slash
  // every honest voter to zero. slashRequiresCorroboration HOLDS throughout (K=2 met by the
  // correlated pair), yet the compromised faction reaches supermajority. Two independent
  // sentinels sharing a base model are treated as two witnesses — the side door reopens.
  run blocCaptureTest =
    init
      // 3 -> 0
      .then(raiseFinding(101, 3)).then(raiseFinding(102, 3)).then(corroboratedSlash(3))
      .then(raiseFinding(101, 3)).then(raiseFinding(102, 3)).then(corroboratedSlash(3))
      // 4 -> 0
      .then(raiseFinding(101, 4)).then(raiseFinding(102, 4)).then(corroboratedSlash(4))
      .then(raiseFinding(101, 4)).then(raiseFinding(102, 4)).then(corroboratedSlash(4))
      // 5 -> 0
      .then(raiseFinding(101, 5)).then(raiseFinding(102, 5)).then(corroboratedSlash(5))
      .then(raiseFinding(101, 5)).then(raiseFinding(102, 5)).then(corroboratedSlash(5))
      .then(all {
        assert(passesOrdinary(factionApproveWeight, activeTotalWeight)
               and slashRequiresCorroboration),
        weight' = weight, status' = status, findings' = findings, deoptStorm' = deoptStorm,
        lastSlashCorroborators' = lastSlashCorroborators,
        lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
      })
```

- [ ] **Step 2: Run it, expect PASS (the attack is reachable)**

Run: `cd /workspace && quint test specs/quint/sentinel.qnt 2>&1 | tail -6`
Expected: PASS — `blocCaptureTest` reaches faction supermajority while `slashRequiresCorroboration` holds. (If any honest weight remains and the assert fails, the counterexample is informative — but at START=4, SLASH=3, two slashes drive 4→1→0, so all three honest voters reach 0.)

- [ ] **Step 3: Write the slash-then-quarantine witness**

```quint
  // ATTACK 2 (ROB-12): once the manufactured quorum exists, quarantine an honest voter,
  // dropping it from aggregation entirely. quarantineRequiresQuorum HOLDS — but the quorum
  // was manufactured by the SAME bloc via slashing. Dual-set protection (08 §3.6) covers
  // only kernel REMOVAL, not Worker quarantine.
  run slashThenQuarantineTest =
    init
      .then(raiseFinding(101, 3)).then(raiseFinding(102, 3)).then(corroboratedSlash(3))
      .then(raiseFinding(101, 3)).then(raiseFinding(102, 3)).then(corroboratedSlash(3))
      .then(raiseFinding(101, 4)).then(raiseFinding(102, 4)).then(corroboratedSlash(4))
      .then(raiseFinding(101, 4)).then(raiseFinding(102, 4)).then(corroboratedSlash(4))
      .then(raiseFinding(101, 5)).then(raiseFinding(102, 5)).then(corroboratedSlash(5))
      .then(raiseFinding(101, 5)).then(raiseFinding(102, 5)).then(corroboratedSlash(5))
      .then(quarantine(3))
      .then(all {
        assert(status.get(3) == Quarantined and quarantineRequiresQuorum),
        weight' = weight, status' = status, findings' = findings, deoptStorm' = deoptStorm,
        lastSlashCorroborators' = lastSlashCorroborators,
        lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
      })
```

- [ ] **Step 4: Write the G1-laundering witness**

Single sentinel 101, no corroboration, drives deoptStorm to STORM_LIMIT then G1-scores honest jurors down — while `slashRequiresCorroboration` is never violated (no slash occurred):

```quint
  // ATTACK 3 (ROB-13): sentinel 101 ALONE storms deopts (reversible authority, no
  // corroboration), then G1 retro-scoring drops every honest juror's weight. NO slash
  // occurs, so slashRequiresCorroboration is never violated — the k-of-n gate is intact
  // AND bypassed. "Reversible" is not "consequence-free". honest voter 3: 4 -> 2.
  run g1LaunderingTest =
    init.then(emergencyDeopt(101)).then(emergencyDeopt(101)).then(g1Score)
        .then(all {
          assert(weight.get(3) == START - G1_PENALTY and lastSlashCorroborators == 0
                 and slashRequiresCorroboration),
          weight' = weight, status' = status, findings' = findings, deoptStorm' = deoptStorm,
          lastSlashCorroborators' = lastSlashCorroborators,
          lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
        })
```

- [ ] **Step 5: Run all tests, expect all PASS**

Run: `cd /workspace && quint test specs/quint/sentinel.qnt 2>&1 | tail -8`
Expected: PASS — 7 sentinel tests total (2 inherited + `singleFindingInertTest`, `soundSlashReachableTest`, `blocCaptureTest`, `slashThenQuarantineTest`, `g1LaunderingTest`).

- [ ] **Step 6: Commit**

```bash
cd /workspace && git add specs/quint/sentinel.qnt
git commit -m "test(quint): three attack witnesses — bloc capture, slash+quarantine, G1 laundering"
```

---

### Task 8: Update `specs/quint/README.md`

**Files:**
- Modify: `specs/quint/README.md`

**Interfaces:**
- Consumes: the finished `sentinel.qnt`.
- Produces: module-map row + abstraction note; forward-scope line updated.

- [ ] **Step 1: Add the module-map row**

In the ```` ``` ```` module-map block, after the `reputation.qnt` line, add:

```
  sentinel.qnt            # 07/08 — Sentinel->reputation gate; ROB-06 re-check  — written, verified
```

- [ ] **Step 2: Update the module count and forward-scope prose**

In the paragraph beginning "All six modules above are implemented and green", change "six" to "seven" and add `sentinel.qnt` to any enumerated list. In the forward-scope paragraph ("Other subsystems (`03`, `04`, `05`, `07`, `09`, ...)"), change it to note `07` is now partially covered by `sentinel.qnt` (the Sentinel→reputation gate), leaving `03`, `04`, `05`, `09` and the rest of `07`/`08` out of scope.

- [ ] **Step 3: Add an abstraction note (after the `reputation.qnt` abstraction note)**

```markdown
**Abstraction note (`sentinel.qnt`):** ground-truth guilt is the empty set and the one
honest Sentinel `{103}` only ever targets the guilty, so the honest-Sentinel and G0 paths
never fire in the adversarial `step` — deliberately isolating "can the compromised path move
weight without a sound justification?". Those paths are kept non-vacuous by dedicated
witnesses (`singleFindingInertTest`, `soundSlashReachableTest`). Sentinel ids are offset
10x from council ids so the two id spaces never alias in the `findings` pair set.
```

- [ ] **Step 4: Verify the README renders and references are correct**

Run: `cd /workspace && grep -c "sentinel.qnt" specs/quint/README.md`
Expected: `3` or more (module map + count paragraph + abstraction note).

- [ ] **Step 5: Commit**

```bash
cd /workspace && git add specs/quint/README.md
git commit -m "docs(quint): README module map — sentinel.qnt (07/08, ROB-06 re-check)"
```

---

### Task 9: Update `specs/quint/FINDINGS.md`

**Files:**
- Modify: `specs/quint/FINDINGS.md`

**Interfaces:**
- Consumes: the finished module + the real gate results (run from Task 6/7 output).
- Produces: a new `### 2.x sentinel.qnt` traceability subsection, a new headline-findings entry, and a full-suite-gate update note.

- [ ] **Step 1: Capture the real gate output (do not fabricate)**

Run and keep the output:

```bash
cd /workspace && mise run quint-typecheck 2>&1 | tail -3
mise run quint-test 2>&1 | tail -3
mise run quint-verify 2>&1 | grep -A2 sentinel
```
Expected: typecheck exit 0; test count increased by 5 sentinel scenarios; verify shows `sentinel.qnt` invariants `NoError` with a real wall time.

- [ ] **Step 2: Add the traceability subsection**

After the `reputation.qnt` traceability subsection (§2.6), add a `### 2.7 sentinel.qnt (07/08 — Sentinel→reputation gate)` table with one row per invariant/scenario, using the exact captured results:

```markdown
### 2.7 sentinel.qnt (`07`/`08` — Sentinel→reputation gate; ROB-06 re-check)

| Invariant / Test | Spec § | Method | Result | Note |
|---|---|---|---|---|
| weightBounded | `08` §3.3 (reputation weight domain) | MC | holds | integer proxy in [0,CAP] |
| slashRequiresCorroboration | `07` §5.9 / `08` §3.6 (k-of-n before weight moves) | MC | holds | ROB-06 acceptance box #1 — the literal fix is correct |
| quarantineRequiresQuorum | `08` §3.6 (Worker quarantine = ordinary ⅔) | MC | holds | guard is correct; quorum is manufacturable (ROB-12) |
| singleFindingInertTest | `07` §3.3 (a lone finding is inert) | scenario | holds | ROB-06's literal guarantee |
| soundSlashReachableTest | `07` §5.9 (corroborated slash exists) | scenario | holds | non-vacuity witness for slashRequiresCorroboration |
| blocCaptureTest | ROB-06 / ROB-11 | scenario | **attack reachable** | correlated Sentinel bloc → faction supermajority; gate not violated |
| slashThenQuarantineTest | ROB-06 / ROB-12 | scenario | **attack reachable** | honest voter quarantined by manufactured quorum |
| g1LaunderingTest | ROB-06 / ROB-13 | scenario | **attack reachable** | single Sentinel moves weight via emergency-deopt→G1; no slash, gate intact |
```

- [ ] **Step 3: Add the headline finding entry**

In the headline-findings section (§3), add a finding **F7** summarizing: the ROB-06 re-check *confirmed* the direct path (no guard bug — all three well-formedness invariants hold) but *surfaced three indirect bypass paths* (ROB-11/12/13), each demonstrated by a concrete reachable witness. Note the two prose-only findings (ROB-14/15) came from the same read.

- [ ] **Step 4: Update the full-suite gate counts (§1)**

Add an **_Update (sentinel.qnt):_** marker under §1.1/§1.2/§1.3 recording the new module counts (8 files, 7 verified modules) and the captured sentinel verify row, matching the exact numbers from Step 1.

- [ ] **Step 5: Commit**

```bash
cd /workspace && git add specs/quint/FINDINGS.md
git commit -m "docs(quint): FINDINGS — sentinel.qnt traceability + F7 (ROB-06 re-check)"
```

---

### Task 10: File the five ROB issues + tick ROB-06 + update issues index

**Files:**
- Create: `specs/issues/ROB-11-sentinel-corroboration-independence.md`
- Create: `specs/issues/ROB-12-slash-quarantine-composition.md`
- Create: `specs/issues/ROB-13-emergency-deopt-g1-laundering.md`
- Create: `specs/issues/ROB-14-embargo-votes-total-leak.md`
- Create: `specs/issues/ROB-15-under-declare-telemetry-evasion.md`
- Modify: `specs/issues/ROB-06-sentinel-consensus-sidedoor.md`
- Modify: `specs/issues/README.md`

**Interfaces:**
- Consumes: the frontmatter schema from `specs/issues/README.md` (`id, title, severity, category, status, affected_specs, review_verdict`) and the ROB-06/ROB-10 file shape.
- Produces: five new issue files, an updated ROB-06, and six new index rows.

- [ ] **Step 1: Create ROB-11 (corroboration independence)**

```markdown
---
id: ROB-11
title: k-of-n Sentinel corroboration has no independence requirement
severity: high
category: robustness
status: open
affected_specs: [07-observability.md, 08-trust-and-security.md]
review_verdict: CONFIRMED
---

# ROB-11 — k-of-n Sentinel corroboration has no independence requirement

## Problem

ROB-06's resolution requires **k-of-n Sentinel corroboration** before a finding moves
reputation/vote weight (07 §5.9, 08 §3.6). But neither spec requires the corroborating
Sentinels to be **decorrelated**. Sentinels are LLM-backed and can share a base model, so
a correlated bloc of k Sentinels is a single logical watcher — and `sentinel.qnt`'s
`blocCaptureTest` shows the bloc self-corroborating to slash every honest voter to zero,
reaching faction supermajority while `slashRequiresCorroboration` holds throughout.

## Why it matters

02 imposes exactly this decorrelation discipline on Genesis voters (ROB-02, red-team lane,
measured-decorrelation precondition). The Sentinel path has no equivalent, so ROB-06's fix
closes the *single*-Sentinel door but leaves it open k-wide to a correlated bloc.

## Proposed change

Require corroborating Sentinels to be measurably decorrelated (distinct base
model/class, or a dispersion floor on their findings), mirroring 02's voter-independence
precondition; or route bloc-correlated corroboration through G0 adjudication instead.

## Acceptance

- [ ] Corroboration counts only decorrelated Sentinels toward k.
- [ ] `sentinel.qnt` `blocCaptureTest` no longer reaches faction supermajority under the
      strengthened gate.
- [ ] Related: ROB-06 (parent), ROB-02 (voter independence).
```

- [ ] **Step 2: Create ROB-12 (slash→quarantine composition)**

```markdown
---
id: ROB-12
title: Slash-then-quarantine composes into honest-voter eviction
severity: high
category: robustness
status: open
affected_specs: [07-observability.md, 08-trust-and-security.md]
review_verdict: CONFIRMED
---

# ROB-12 — Slash-then-quarantine composes into honest-voter eviction

## Problem

Corroborated slashing shifts the reputation-weighted ⅔ quorum; a Worker quarantine is an
ordinary (⅔) TypedDiff (08 §3.6). `sentinel.qnt`'s `slashThenQuarantineTest` shows a
Sentinel bloc first manufacturing quorum by slashing honest voters, then using that quorum
to **quarantine** an honest voter — dropping it from aggregation entirely.
`quarantineRequiresQuorum` holds, because the quorum is real; it was just manufactured.

## Why it matters

The dual-set minority protection (08 §3.6) guards only kernel **removal**, not Worker
quarantine. So the composition slash→quarantine evicts honest voters through a path no
single guard rejects — a strictly stronger outcome than the weight-nudge ROB-06 considered.

## Proposed change

Extend anti-weaponization to quarantine: require the evidence trail plus a quorum computed
on **pre-slash** weights for a quarantine that follows recent Sentinel-driven slashes, or
gate Worker quarantine behind the dual-set protection when the quorum shifted via slashing.

## Acceptance

- [ ] A quarantine cannot be carried purely on quorum manufactured by recent slashes.
- [ ] `sentinel.qnt` `slashThenQuarantineTest` no longer quarantines an honest voter.
- [ ] Related: ROB-06 (parent), ROB-11 (the slashing precondition).
```

- [ ] **Step 3: Create ROB-13 (emergency-deopt G1 laundering)**

```markdown
---
id: ROB-13
title: Emergency deopt launders a single Sentinel's opinion into vote weight via G1
severity: high
category: robustness
status: open
affected_specs: [07-observability.md, 08-trust-and-security.md, 02-consensus.md]
review_verdict: CONFIRMED
---

# ROB-13 — Emergency deopt launders a single Sentinel's opinion into vote weight via G1

## Problem

ROB-06 bounds auto-ratified Sentinel authority to **reversible** actions — e.g. emergency
deopt — with no corroboration required (08 §3.6). But 02 §6.2 scores votes retroactively
against **G1 ground truth, which includes observed trap storms**. `sentinel.qnt`'s
`g1LaunderingTest` shows one Sentinel storming deopts (no corroboration) and the subsequent
G1 retro-scoring dropping every approving juror's weight — an un-corroborated single-Sentinel
path into vote weight. `slashRequiresCorroboration` is never violated: no slash occurs.

## Why it matters

"Reversible" is not "consequence-free". A reversible action that manufactures the telemetry
G1 scoring reads becomes an *irreversible* weight move, bypassing the k-of-n gate ROB-06
installed on the *slashing* path — the same side door, one hop removed.

## Proposed change

Either exclude Sentinel-triggered deopt storms from G1 retro-scoring credit, or require the
same k-of-n corroboration before deopt-derived G1 signal is allowed to move reputation.

## Acceptance

- [ ] A single Sentinel's emergency deopts cannot, via G1, move any juror's weight.
- [ ] `sentinel.qnt` `g1LaunderingTest` no longer drops honest-juror weight.
- [ ] Related: ROB-06 (parent), `02` §6.2 (G1 scoring).
```

- [ ] **Step 4: Create ROB-14 (embargo misses votes_total) — prose-only**

```markdown
---
id: ROB-14
title: Blind-vote embargo omits the consensus.votes_total counter
severity: medium
category: robustness
status: open
affected_specs: [07-observability.md]
review_verdict: CONFIRMED
---

# ROB-14 — Blind-vote embargo omits the consensus.votes_total counter

## Problem

07 §2.1's worked example increments `consensus.votes_total{verdict}` at vote-cast time. The
blind-vote embargo (07 §3.9) buffers the `BlindVoteCast` event and `vote.cast` span and
delays `dispersion`/`posterior` to `DecisionReached` — but never mentions the counter. A
live per-verdict counter leaks the running tally to a not-yet-voted Genesis member, letting
them correlate — defeating the decorrelation §3.9 exists to protect.

## Why it matters

This is an internal inconsistency in the plane that is supposed to *protect* the blind-vote
invariant. The leak is coarse (counts, not identities) but still correlating.

## Proposed change

Add `consensus.votes_total` to the embargo: buffer per-verdict increments and release them
on `DecisionReached`, alongside `dispersion`/`posterior`. One-line addition to §3.9's list.

## Acceptance

- [ ] §3.9 explicitly embargoes `consensus.votes_total` until the blind round closes.
- [ ] The §2.1 example is reconciled with the embargo rule.
```

- [ ] **Step 5: Create ROB-15 (under-declare evasion) — prose-only**

```markdown
---
id: ROB-15
title: Under-declaring telemetry capability is a blessed detection-evasion path
severity: medium
category: robustness
status: open
affected_specs: [07-observability.md, 08-trust-and-security.md]
review_verdict: CONFIRMED
---

# ROB-15 — Under-declaring telemetry capability is a blessed detection-evasion path

## Problem

07 §5.7 states "under-declaring is fine" (extra telemetry is a bonus, not a violation). 07
§3.5.4 says consumers treat a low-`coverage_ratio` source as higher-variance — a Sentinel
**raises its detection threshold** rather than firing on a source it can barely see. Composed,
an adversarial agent minimizes its **declared** capability to dim its own telemetry and buy a
higher Sentinel detection threshold — coverage is treated as honesty-neutral but is
adversary-controlled.

## Why it matters

The graceful-degradation design assumes low coverage is benign (a poor harness), never
strategic. An agent that *wants* to avoid scrutiny is rewarded for declaring less.

## Proposed change

Make declared capability a floor an agent cannot lower unilaterally (or treat a *drop* in
declared capability as itself a `DriftDetected`/anomaly signal, not a threshold relaxation),
so under-declaration cannot be used to purchase detection leniency.

## Acceptance

- [ ] A drop in declared telemetry capability does not raise the Sentinel detection threshold
      for that source (or is itself flagged).
- [ ] §5.7 / §3.5.4 are reconciled against the adversarial-under-declaration case.
```

- [ ] **Step 6: Tick the ROB-06 re-check acceptance box**

In `specs/issues/ROB-06-sentinel-consensus-sidedoor.md`, change the acceptance line:

```markdown
- [ ] The "no single agent swings consensus" invariant is re-checked against this path.
```
to:
```markdown
- [x] The "no single agent swings consensus" invariant is re-checked against this path.
      Re-checked formally in `specs/quint/sentinel.qnt`: the direct path is confirmed
      (all three well-formedness invariants hold — no guard bug), and the re-check surfaced
      three indirect bypass paths, filed as ROB-11 (corroboration independence), ROB-12
      (slash→quarantine composition), and ROB-13 (emergency-deopt G1 laundering).
```

- [ ] **Step 7: Add the six index rows to `specs/issues/README.md`**

In the Robustness table (after the ROB-10 row), add:

```markdown
| [ROB-11](./ROB-11-sentinel-corroboration-independence.md) | high | k-of-n Sentinel corroboration has no independence requirement |
| [ROB-12](./ROB-12-slash-quarantine-composition.md) | high | Slash-then-quarantine composes into honest-voter eviction |
| [ROB-13](./ROB-13-emergency-deopt-g1-laundering.md) | high | Emergency deopt launders a single Sentinel's opinion into vote weight via G1 |
| [ROB-14](./ROB-14-embargo-votes-total-leak.md) | medium | Blind-vote embargo omits the consensus.votes_total counter |
| [ROB-15](./ROB-15-under-declare-telemetry-evasion.md) | medium | Under-declaring telemetry capability is a blessed detection-evasion path |
```

(Also flip the ROB-06 index row's implied state if the index tracks status — leave the row text as-is; ROB-06 stays `resolved`, now with its re-check discharged.)

- [ ] **Step 8: Verify all five files exist and frontmatter parses**

Run: `cd /workspace && for n in 11 12 13 14 15; do head -3 specs/issues/ROB-$n-*.md; echo ---; done`
Expected: each prints its `---` / `id: ROB-NN` / `title:` frontmatter opening.

- [ ] **Step 9: Commit**

```bash
cd /workspace && git add specs/issues/
git commit -m "docs(issues): file ROB-11..15 from sentinel.qnt; tick ROB-06 re-check box"
```

---

### Task 11: Final full-suite gate + plan-completion verification

**Files:** none (verification only).

- [ ] **Step 1: Run the complete gate from the repo root**

Run:
```bash
cd /workspace && mise run quint-typecheck && mise run quint-test && mise run quint-verify
```
Expected: all three exit 0. Typecheck: 8 `.qnt` files clean. Test: prior count + 5 new sentinel scenarios, 0 failing. Verify: every module `NoError`, including the `sentinel.qnt` row with its three invariants.

- [ ] **Step 2: Confirm the attack scenarios are genuinely exercised (non-vacuity)**

Run: `cd /workspace && quint test specs/quint/sentinel.qnt --verbosity=3 2>&1 | grep -Ei "blocCapture|slashThenQuarantine|g1Laundering|passed|ok"`
Expected: all three attack tests listed as passing — confirming each reaches its asserted attack state, not a vacuous early exit.

- [ ] **Step 3: Confirm the working tree is clean and all work committed**

Run: `cd /workspace && git status --short && git log --oneline -11`
Expected: clean working tree (or only unrelated pre-existing `.mise.toml` change); the last ~10 commits are Tasks 1–10.

- [ ] **Step 4: Final commit if any doc counts drifted (optional)**

If Step 1 revealed a count in `FINDINGS.md`/`README.md` that no longer matches the real gate output, correct it and commit:

```bash
cd /workspace && git add specs/quint/ && git commit -m "docs(quint): reconcile suite counts with final gate output"
```

---

## Self-Review

**Spec coverage** (design doc §Scope → task):
- Single-finding inertness → Task 2 (`singleFindingInertTest`). ✓
- Corroboration gate well-formedness → Task 3 (`slashRequiresCorroboration`). ✓
- Quarantine quorum well-formedness → Task 4 (`quarantineRequiresQuorum`). ✓
- Attack 1 bloc capture → Task 7 + ROB-11 (Task 10). ✓
- Attack 2 slash→quarantine → Task 7 + ROB-12 (Task 10). ✓
- Attack 3 G1 laundering → Task 5 (actions) + Task 7 (witness) + ROB-13 (Task 10). ✓
- G0 sound-path non-vacuity → Task 3 (`g0Slash` + `soundSlashReachableTest`). ✓
- Prose-only issues 4 & 5 → Task 10 (ROB-14, ROB-15). ✓
- Report-back: README (Task 8), FINDINGS (Task 9), ROB-06 tick + index (Task 10). ✓
- All deliverables in design doc §Report-back are covered.

**Placeholder scan:** no "TBD"/"handle edge cases"/"similar to Task N" — every code step shows complete Quint. The only conditional is Task 6 Step 3's optional `VERIFY-MAX-STEPS` fallback, which gives the exact directive and the precedent modules to copy.

**Type consistency:** state var names (`weight`, `status`, `findings`, `deoptStorm`, `lastSlashCorroborators`, `lastQuarantinePassedQuorum`), constants (`CAP START SLASH K STORM_LIMIT G1_PENALTY`), fixtures (`faction honest council sBloc sHonest guilty`), and helpers (`maxInt`, `activeTotalWeight`, `factionApproveWeight`, `corroboratorsOf`) are used identically across Tasks 1–7. Every `run`'s trailing `all { ... }` assigns all six state vars (Quint requires every `var` be assigned in an action) — checked consistent across all five scenarios. Action guards reference only fixtures/vars defined in Task 1. The `# VERIFY:` header grows monotonically (Task 1 → 3 → 4) to exactly the three model-checked invariants.
