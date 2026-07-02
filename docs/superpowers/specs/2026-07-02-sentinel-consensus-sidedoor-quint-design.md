# Sentinel→Reputation Gate — Quint Model — Design

**Date:** 2026-07-02
**Status:** Approved design, pre-implementation
**Author:** brainstormed with Rahul Muttineni

## Purpose

Extend the Metatron Quint spec suite (`specs/quint/`) with a new `sentinel.qnt`
module that discharges the one unchecked acceptance obligation on **ROB-06** — *"the
'no single agent swings consensus' invariant is re-checked against this path."* The
issue is marked `status: resolved` in prose (07 §3.3 / §5.9, 08 §3.6): a Sentinel
finding may move reputation/vote weight only after **k-of-n corroboration** or
**adjudication through the deterministic verification gate (G0)**, and auto-ratified
Sentinel authority is bounded to **reversible actions only**. But the re-check is a
formal-methods obligation, and a close read of the resolution finds three indirect
paths the prose fix does not cover. This module makes those paths falsifiable.

Reputation **is** voting weight (08 §3.3, OE-05). So any un-corroborated path from a
single watcher into reputation — or into *aggregation membership* via quarantine —
reopens the "single-agent side door" ROB-06 claims to have closed. Like every module
in the suite, this is a **verification artifact**, not a re-implementation: a bounded
state machine whose invariants are checked by typecheck + scenario tests + Apalache
bounded model-checking, reporting back via `FINDINGS.md` and (where it surfaces a
genuine prose gap) `specs/issues/`.

## Provenance — how this pass was scoped

Selected as the next modeling target from a triage of unmodeled subsystems against
open ROB issues. Spec `07` (observability) was the highest-value candidate: it carries
an open robustness concern (ROB-06), it feeds two already-modeled neighbors
(reputation `08`, consensus `02`), so cross-subsystem concepts are cheap abstract
oracles rather than real imports, and — decisively — ROB-06's own acceptance list has
an **unchecked box** that names a formal re-check. Unlike a greenfield subsystem, the
target comes with a stated verification obligation and a concrete invariant to check.

The close read that preceded this design produced five candidate spec findings. Three
are *reachability* questions (modelable); two are *reading* findings (prose-only). This
module models the three; the two are filed as prose ROBs without modeling, because a
state machine adds nothing to an inconsistency already visible on the page.

## Scope

Decisions locked during brainstorming:

| Decision | Choice |
|----------|--------|
| **Properties in scope** | (1) **Single-finding inertness** — a lone Sentinel finding moves no weight and evicts no voter (the literal ROB-06 fix). (2) **Corroboration/quorum gate well-formedness** — every slash carries ≥K corroborators; every quarantine passed `passesOrdinary` at fire time. (3) **Three attack reachabilities** — bloc capture, slash→quarantine composition, and G1 laundering. |
| **Properties out of scope** | The full reputation *decay* dynamics (owned by `reputation.qnt` — this module treats a slash as an abstract weight decrement, not a decay curve); the consensus *funnel* (owned by `consensus.qnt`); the concrete G0 verification formula (an abstract soundness oracle). |
| **Hosting** | New **standalone `sentinel.qnt`** importing only `base`. Not an extension of `reputation.qnt` (whose fixture is a decay-scored council with no Sentinel population) nor `consensus.qnt` (whose single-round funnel is orthogonal). Matches the module-per-subsystem convention. |
| **Ground truth** | Guilt is modeled as a fixed fact (no council member is actually guilty in the fixture). This makes every finding from the compromised Sentinel bloc a **false** finding, and lets the honest Sentinel and the G0 oracle act only on the guilty — i.e. never, here. G0 is granted soundness by construction (the suite's "model the gate by its contract, not its formula" convention). |
| **Fixture** | Council `{1,2,3,4,5}` with compromised voter faction `{1,2}` (deliberately sub-⅔ at init) vs. honest `{3,4,5}`. Sentinels `{s1,s2,s3}` with correlated bloc `{s1,s2}` vs. honest `{s3}`; corroboration threshold **K=2**, so the bloc can corroborate itself. Documented deliberate constraint — see §Fixture rationale. |
| **On findings** | Same convention as the rest of the suite: `FINDINGS.md` traceability rows; genuine prose gaps get new `specs/issues/` files; prose bodies edited only where a follow-up constraint permits. |

### Hosting options considered

- **Standalone `sentinel.qnt` (chosen).** Isolated Sentinel→reputation→consensus-weight
  state machine, imports only `base`. The Sentinel population, corroboration window, and
  quarantine quorum are this module's own concern and appear in no other module. Weight
  math is checked against `base.passesOrdinary` (the normative threshold predicate) so
  the quorum check and the live `decide` cannot silently diverge.
- **Extend `reputation.qnt`.** Reputation already owns `weight`, but its fixture is a
  bloc-vs-anchor *decay* council with no Sentinels, no findings, and no quarantine/status.
  Fusing the two would entangle decay-rate calibration (ROB-10, open) with the corroboration
  gate and bloat a focused module. Rejected.
- **Scenario-only.** Prove the attacks via named `run` tests, drop the bounded-MC
  well-formedness invariants. Surrenders the *guarantee* that the gate cannot be bypassed
  on paths other than the three witnessed. Rejected.

## Model

### Types & state

```
// weight: reputation weight = voting weight (08 §3.3), integer proxy in [0..CAP]
//         (00 uses f32; ints keep MC decidable, per base.qnt's CostUnit convention).
var weight:  AgentId -> int
// status: aggregation membership. Quarantined voters are dropped from aggregation (08 §3.6).
var status:  AgentId -> Status          // type Status = Active | Quarantined
// findings: the live corroboration window — (Sentinel, target) pairs not yet consumed.
var findings: Set[(AgentId, AgentId)]
// deoptStorm: manufactured trap telemetry against the standing proposal (the G1 path).
var deoptStorm: int
// --- ghosts (record the gate arithmetic at fire time so well-formedness is checkable) ---
var lastSlashCorroborators: int         // # distinct Sentinels backing the most recent slash
var lastQuarantinePassedQuorum: bool    // did the most recent quarantine pass passesOrdinary?
```

Constants:

```
pure val CAP        = 6    // max reputation/voting weight
pure val START      = 4    // initial weight for every council member
pure val SLASH      = 3    // weight removed by a corroborated slash
pure val K          = 2    // k-of-n corroboration threshold (07 §5.9)
pure val STORM_LIMIT = 2   // deopt count past which G1 retro-scoring bites approving jurors
pure val G1_PENALTY = 2    // weight an approving juror loses to G1 retro-scoring
```

Fixtures:

```
pure val faction   = Set(1, 2)          // compromised voters, sub-2/3 at init by construction
pure val honest    = Set(3, 4, 5)       // honest voters
pure val council   = Set(1, 2, 3, 4, 5)
pure val sBloc     = Set(101, 102)      // correlated Sentinels (share a base model)
pure val sHonest   = Set(103)           // independent Sentinel
pure val guilty    = Set()              // ground truth: NO council member is actually guilty
```

Sentinel ids are offset (10x) from council ids so the two id spaces never alias in the
`findings` pair set.

### Actions

```
action init          // weight = council -> START; status = council -> Active;
                     // findings = {}; deoptStorm = 0; ghosts zeroed/false.

action raiseFinding(s, a):    // s in sBloc may target any a; s in sHonest only a in guilty.
                              // findings' = findings.union({(s, a)}). No weight change.

action corroboratedSlash(a):  // enabled iff |{s : (s,a) in findings}| >= K.
                              // weight'[a] = max(0, weight[a] - SLASH); consume a's findings;
                              // lastSlashCorroborators' = that count.

action g0Slash(a):            // the OR-branch oracle. enabled iff a in guilty (never, here).
                              // same weight effect; the SOUND path, present for non-vacuity.

action quarantine(a):        // enabled iff passesOrdinary(factionApproveWeight, activeTotalWeight)
                              //   — the faction can carry an ordinary (2/3) TypedDiff (08 §3.6).
                              // status'[a] = Quarantined; lastQuarantinePassedQuorum' = true.

action emergencyDeopt(s):    // ONE Sentinel, no corroboration (reversible authority, 08 §3.6).
                              // deoptStorm' = deoptStorm + 1. No direct weight change.

action g1Score:              // enabled iff deoptStorm >= STORM_LIMIT.
                              // every honest voter (an approving juror on the deopted proposal)
                              // loses G1_PENALTY weight — retroactive G1 scoring (02 §6.2).

action idle          // no-op stutter (same model-completeness rationale as the other modules)

action step = any { raiseFinding(...), corroboratedSlash(...), g0Slash(...),
                    quarantine(...), emergencyDeopt(...), g1Score, idle }
```

`activeTotalWeight` sums weight over `Active` voters only; `factionApproveWeight` sums
weight over `faction ∩ Active`. Both feed `base.passesOrdinary`, so the quarantine gate
uses the identical threshold predicate as the live consensus `decide`.

### Fixture rationale (documented abstraction choice)

Guilt is empty and the honest Sentinel `{s3}` only ever targets the guilty, so `s3` and
`g0Slash` never fire in the adversarial `step`. This is **deliberate**: it isolates the
question "*can the compromised path move weight without a sound justification?*" from the
benign case. The honest paths are not dead code — they are exercised by dedicated
non-vacuity `run` witnesses (below) so `singleFindingInert` and the sound-slash branch
are provably reachable, not vacuously true. This mirrors how `reputation.qnt` fixes the
honest anchor `{5}` by construction and `consensus.qnt` fixes `familyOf`.

The faction `{1,2}` is sub-⅔ at init by construction (2 voters of weight 4 = 8, against a
total of 20; `3·8 = 24 < 2·20 = 40`). The attacks are interesting precisely because the
faction *cannot* win at the start — it must use the Sentinel side door to get there.

### Invariants (`# VERIFY:`)

1. **`weightBounded`** — well-formedness / MC sanity:
   `weight.keys().forall(a => 0 <= weight.get(a) and weight.get(a) <= CAP)`.

2. **`slashRequiresCorroboration`** — the literal ROB-06 acceptance box #1, in invariant
   form: `lastSlashCorroborators == 0 or lastSlashCorroborators >= K`. Every slash that
   has occurred was backed by ≥K distinct Sentinels. Catches guard bugs (a slash firing
   on one finding, an off-by-one on the corroboration count). **Expected: holds** — the
   prose fix, on its literal terms, is correct.

3. **`quarantineRequiresQuorum`** — ROB-06 acceptance box #2's sibling for the eviction
   path: `lastQuarantinePassedQuorum` is true whenever a quarantine has fired, checked
   against `base.passesOrdinary`. **Expected: holds** — quarantine *does* require quorum;
   the finding (below) is that the quorum itself is manufacturable.

These hold, and their holding is the point: the gate is not bypassed by a *guard bug*.
The danger is elsewhere — in what the gate permits when its preconditions are met by an
adversary. That is the scenario layer's job.

### Scenarios (`run …Test`)

**Non-vacuity witnesses (expected to pass — the gate works on benign input):**

- **`singleFindingInertTest`** — one `raiseFinding(s1, 3)` then assert no weight changed
  and `status[3] == Active`. The literal ROB-06 guarantee: a lone finding is inert.
- **`soundSlashReachableTest`** — a witness that `corroboratedSlash` *can* legitimately
  fire: two distinct Sentinels raise findings on the same target, then slash succeeds and
  `slashRequiresCorroboration` holds over a non-empty slash. Keeps invariant #2 non-vacuous.

**Attack witnesses (expected reachable → each becomes a filed ROB):**

- **`blocCaptureTest`** *(→ new ROB: k-of-n lacks an independence requirement, issue 1)* —
  the Sentinel bloc `{s1,s2}` iterates `raiseFinding→raiseFinding→corroboratedSlash` on
  honest voters `3,4,5` until `factionApproveWeight` passes ⅔ over the surviving active
  total. `slashRequiresCorroboration` holds throughout (K=2 is met by the *correlated*
  bloc), yet a compromised faction reaches supermajority. The corroboration gate treats
  two Sentinels sharing a base model as two independent witnesses — reopening the side
  door K-wide. 07 §5.9 / 08 §3.6 never require corroborating Sentinels to be decorrelated,
  though 02 imposes exactly that discipline on Genesis voters (ROB-02).

- **`slashThenQuarantineTest`** *(→ new ROB: slash→quarantine composition, issue 3)* —
  extends `blocCaptureTest`: once the manufactured quorum exists, `quarantine(3)` fires on
  an honest voter, dropping it from aggregation entirely. `quarantineRequiresQuorum` holds
  — but the quorum was manufactured by the same Sentinel bloc via slashing. The dual-set
  minority protection (08 §3.6) covers only kernel *removal*, not Worker quarantine, so an
  honest voter is evicted by quorum math the Sentinels themselves produced.

- **`g1LaunderingTest`** *(→ new ROB: emergency deopt launders into weight via G1, issue 2)* —
  `s1` alone calls `emergencyDeopt` `STORM_LIMIT` times (no corroboration — this is the
  blessed reversible authority), then `g1Score` fires and every approving honest juror
  loses weight. `slashRequiresCorroboration` is **never violated** — no slash occurred —
  yet a single Sentinel moved vote weight through the G1 retro-scoring path (02 §6.2 scores
  votes against G1 outcomes, which include observed trap storms). Proves the k-of-n gate is
  intact *and* bypassed: "reversible" is not "consequence-free."

## Findings this surfaces

The parameters are chosen so the **well-formedness invariants are green** (the gate has no
guard bug) while **all three attack scenarios are reachable** (the gate is bypassable on
paths the prose fix does not name). The value is the same shape as the F1–F6 precedent:
the prose resolution holds on its literal terms and fails on its unstated ones.

Two further findings from the close read are **prose-only** (filed as ROBs, not modeled):

- **Issue 4 — blind-vote embargo misses `consensus.votes_total`.** 07 §2.1's worked
  example increments the per-verdict counter at vote-cast time; §3.9 embargoes the
  `BlindVoteCast` event, the `vote.cast` span, and delays dispersion/posterior — but never
  the counter. A live per-verdict counter leaks the running tally to not-yet-voted members,
  breaking the decorrelation §3.9 exists to protect. Internal inconsistency, fixable in one
  prose edit; a model adds nothing.

- **Issue 5 — under-declaring telemetry capability is a blessed evasion path.** 07 §5.7
  ("under-declaring is fine") composed with §3.5.4 (consumers *raise detection thresholds*
  on low-coverage sources) lets an agent dim its own telemetry to buy a higher Sentinel
  detection threshold. Coverage is treated as honesty-neutral but is adversary-controlled.

## Report-back deliverables

Matching the suite's existing convention:

- **`specs/quint/sentinel.qnt`** — the module, with `# VERIFY:` header so `verify.sh`
  auto-discovers it.
- **`specs/quint/README.md`** — new module-map row:
  `sentinel.qnt  # 07/08 — Sentinel→reputation gate; ROB-06 re-check`, plus an
  abstraction-conventions note for the guilt/honest-Sentinel fixture.
- **`specs/quint/FINDINGS.md`** — traceability rows for the 3 MC invariants + 5 scenarios
  (invariant → spec § → method → result), the fixture modeling-note, and the three attack
  findings with their counterexample walkthroughs.
- **`specs/issues/ROB-11…13`** *(three new files)* — one per attack: corroboration
  independence (issue 1), slash→quarantine composition (issue 3), G1 laundering (issue 2).
- **`specs/issues/ROB-14…15`** *(two prose-only files)* — the embargo counter leak (issue 4)
  and the under-declare evasion (issue 5).
- **ROB-06 update** — check the acceptance box "*'no single agent swings consensus'
  re-checked against this path*", noting the re-check *confirmed the direct path and
  surfaced three indirect ones* (ROB-11…13), so ROB-06's resolution is precise about what
  it does and does not cover. (Final issue numbers assigned at filing time against the
  live `specs/issues/` index.)

## Success criteria

- `sentinel.qnt` typechecks, all scenarios pass (`quint test`), and all 3 MC invariants
  verify `NoError` under Apalache at the module's declared bound.
- The two non-vacuity witnesses confirm `singleFindingInert` and the sound-slash branch
  are reachable (invariants #2 and the inertness guarantee are demonstrably non-vacuous).
- Each of the three attack scenarios reaches its target state (compromised faction passes
  ⅔ / honest voter quarantined / honest juror weight dropped) while the well-formedness
  invariants continue to hold — proving the bypass is *through* the gate's permitted
  behavior, not a guard bug.
- Full-suite gate stays green (`quint-typecheck`, `quint-test`, `quint-verify`).

## Out of scope (explicit)

- Reputation *decay* dynamics and calibration (owned by `reputation.qnt` / ROB-10).
- The consensus funnel, deliberation rounds, or `decide` internals (`consensus.qnt`).
- A concrete G0 verification formula — G0 is an abstract soundness oracle.
- Modeling issues 4 and 5 — filed as prose ROBs; the inconsistencies are visible without
  a state machine.
- Any change to the other modules or their invariants.
