# Metatron Quint spec suite — FINDINGS.md

Traceability report for the modular Quint spec suite in `specs/quint/`. This is the
suite's report-back to the prose specs (see `specs/quint/README.md` and the design doc
`docs/superpowers/specs/2026-07-01-metatron-quint-spec-suite-design.md`). It records,
for every model-checked invariant and every scenario test across all five modules:
what was checked, against which spec section, by what method, and the result.

**No `specs/*.md` prose body was edited to produce this report.** This file and the one
new file under `specs/issues/` (§4 below) are additive-only.

---

## 1. Full-suite gate — captured, real, 2026-07-01

All three gates were run to completion from the repo root (`/workspace/.claude/worktrees/metatron-quint-spec-suite`), foreground, real output captured (no results fabricated or assumed).

### 1.1 `mise run quint-typecheck`

Exit code 0. All 5 modules (`base.qnt`, `budgets.qnt`, `consensus.qnt`, `mailbox.qnt`,
`smoke.qnt`, `state_model.qnt` — 6 files) typecheck cleanly (Quint prints nothing on a
clean typecheck; absence of `[QNT...]` error output + exit 0 is the pass signal, consistent
with every prior task report in this suite).

### 1.2 `mise run quint-test`

Exit code 0. **28 test-invocations passing, 0 failing**, across 6 files (20 unique scenarios
— `base`'s 2 scenarios are transitively re-run by every module that `import`s it):

| Module | Passing | Breakdown |
|---|---|---|
| base.qnt | 2 | kernelClassificationTest, thresholdMathTest |
| budgets.qnt | 6 | (2 inherited) + runawayWorkerRespectsKernelFloorTest, depletionAlwaysNotifiesTest, cannotSkipToCancelTest, reserveCarvedUnderCapTest |
| consensus.qnt | 7 | (2 inherited) + refutedRejectsNoVoteTest, authorCannotVoteTest, ordinaryPassPathTest, correlatedCouncilCannotAutoCommitTest, breakGlassGatedTest |
| mailbox.qnt | 6 | (2 inherited) + answerRoutesToOwnQuestionTest, leakedTokenRejectedTest, neverAnsweredResolvesTest, precedenceBreaksTieTest |
| smoke.qnt | 1 | countsUpTest |
| state_model.qnt | 6 | (2 inherited) + casSerializesTest (10000 randomized runs), cycleRejectedTest, blockedCannotFinishTest, i3EvasionRejectedTest |

### 1.3 `mise run quint-verify` (Apalache 0.47.2, bounded model checking)

Ran in the **background**, foreground-polled to completion (not backgrounded-and-abandoned) — total wall clock **~10m0s**. `specs/quint/verify.sh` runs under `set -euo pipefail`, so any module failure would have stopped the whole run; it ran to the end, confirming all 6 passes below completed. Every pass below is verbatim `[ok] No violation found` — **zero counterexamples in the final, shipped state of the suite** (the counterexamples that *were* found during development, F1-F5, are documented in §3 and were all fixed before this run).

| # | Pass | Invariants | Depth | Outcome | Wall time |
|---|---|---|---|---|---|
| 1 | `budgets.qnt` | stockNeverExceedsCap, childFloorsFitParent, kernelFloorAvailable, bucketWithinCapacity, layeredStopOrdering, notifierIsOffBudget | default (Apalache default bound, reached step 10) | **NoError** | 76.3s |
| 2 | `consensus.qnt` `[max-steps=10]` | proposerNotDisposer, verifyBeforeVote, refutedNeverCommits, quorumAndThreshold, noAutonomousLowCoverageHighBlast, mechanicalTiering, breakGlassOnlyOnDeadlock | 10 | **NoError** | 409.8s (~6m50s) |
| 3 | `mailbox.qnt` `[max-steps=6]` | corrInjective, answerClearsOwnNode, gatingConsistent, bindingIs1to1, precedenceNoDeadlock | 6 | **NoError** | 30.5s |
| 4 | `smoke.qnt` | nonNegative | default | **NoError** | 4.4s |
| 5 | `state_model.qnt` (default step) | headReachable, linearSpine, gapFreeTime, constitutionalIffKernel, constitutionalFlagHonest | default (reached step 10) | **NoError** | 29.7s |
| 6 | `state_model.qnt` `[step=taskStep, max-steps=4]` | taskDagAcyclic, blockedTaskSafety | 4 | **NoError** | 8.2s |

**Result: every module is green at its declared (possibly bounded) depth. No STOP condition was hit — the suite gate is fully passing.**

(Benign `io.netty`/gRPC/HTTP2 stack-trace noise appears throughout the log — this is Apalache's local gRPC health-check probe failing harmlessly on shutdown, documented as expected in every prior task report and the README; it does not affect the `NoError` outcomes above.)

---

## 2. Traceability table — one row per checked invariant / scenario

Columns: `Invariant | Spec §` | `Method` | `Result` | `Note`. Grouped by module. **Method** is `MC` (Apalache bounded model check, `quint verify`), `scenario` (a named `run ...Test`, `quint test`), or `sim` (randomized simulation — `casSerializesTest` runs the scenario 10000x via Quint's built-in test-repeat).

### 2.1 base.qnt (no `# VERIFY:` — shared vocabulary only, no state machine to MC)

| Invariant / Test | Spec § | Method | Result | Note |
|---|---|---|---|---|
| kernelClassificationTest | `00` §3 Agent Taxonomy (kernel vs. dynamic roles) | scenario | holds | `isKernel(Guardian) and isKernel(Genesis) and not isKernel(Worker)` |
| thresholdMathTest | `02` §9.1 (ordinary 2/3) / §9.2 (constitutional 3/4) | scenario | holds | `passesOrdinary(2,3) and not passesConstitutional(2,3)` |

### 2.2 budgets.qnt (`10` — hierarchical stock + rate budgets)

| Invariant / Test | Spec § | Method | Result | Note |
|---|---|---|---|---|
| stockNeverExceedsCap | `10` §2.3 (reserved floor + shared burst; subtree roll-up <= cap) | MC | holds | |
| childFloorsFitParent | `10` §2.3 (sum of child floors <= parent allocation) | MC | holds | Single-state property (only reads `tree`, which no action mutates) — checked once at State 0, correctly not re-checked by Apalache's incremental optimization. |
| kernelFloorAvailable | `10` §2.3 ("Kernel agents ... receive non-zero floors, so governance stays funded under budget pressure") | MC | holds (after fix) | **See F1 (§3).** Apalache found a genuine counterexample against the brief's original `breaksKernelFloor` guard; fixed. |
| bucketWithinCapacity | `10` §2.4 (token bucket depth) | MC | holds | |
| layeredStopOrdering | `10` §3.3 (soft-threshold -> notify -> drain -> freeze -> hard-cancel ladder) | MC | holds | Non-vacuous supporting property (`status != Running implies notices >= 1`); the true no-skip transition guarantee is proven by `cannotSkipToCancelTest`, not by this single-state invariant alone (documented in-file). |
| notifierIsOffBudget | `10` §3.4 (deterministic, off-budget, exactly-once notifier) | MC | holds | Strengthened from the brief's `notices >= 0` tautology to an exact-count biconditional (`notices == count(non-Running nodes)`); inductive and falsifiable. |
| runawayWorkerRespectsKernelFloorTest | `10` §2.3 (ROB-05-adjacent: a runaway Worker cannot starve the kernel floor) | scenario | holds | Worker (node 2) charges 3x5; kernel-class node 1's floor stays available. |
| depletionAlwaysNotifiesTest | `10` §3.3 / §3.4 | scenario | holds | 17x5=85 charges cross the soft threshold (90-5); exactly one notice, node -> Notified. |
| cannotSkipToCancelTest | `10` §3.3 (no `Running -> Cancelled` skip) | scenario | holds | `.then(hardCancel(2).fail())` — guard genuinely disabled while Running. |
| reserveCarvedUnderCapTest | `10` §2.3 | scenario | holds | Reserve carved under cap at `init`. |

### 2.3 state_model.qnt (`01` — Merkle log, typed diffs, CAS head)

| Invariant / Test | Spec § | Method | Result | Note |
|---|---|---|---|---|
| headReachable | `01` §3.1 / §4.6 (head-advance protocol) | MC (default step, depth 10) | holds | |
| linearSpine | `01` §3.1 / §4.6 (no two committed nodes on the head's ancestor chain share a parent) | MC (default step, depth 10) | holds | |
| gapFreeTime | `01` §4.7 LogicalTime | MC (default step, depth 10) | holds | |
| constitutionalIffKernel | `01` §4.2, invariant **I3** ("`constitutional` is set iff any op mutates `KernelSet`") | MC (default step, depth 10) | holds | Strengthened from the brief's `... or true` tautology; added a `touchedKernel` witness field, raw `stage` set honest-by-construction (design choice (i) — I3 is an *enforced* safety property, not merely a checked-path property). |
| constitutionalFlagHonest | `01` §4.2 I3 (GENESIS root honesty) | MC (default step, depth 10) | holds | Distinct from the biconditional above: GENESIS is non-constitutional and non-kernel-touching. |
| taskDagAcyclic | `01` §4.2, invariant **I4** ("Task-graph dependency edges remain acyclic") | MC (`step=taskStep`, max-steps=4) | holds (after fix) | **See F2 (§3).** Non-vacuous under `taskStep` only (default `step` never populates `tasks`, so the default-pass MC of this invariant would be vacuous — hence the step-override pass). |
| blockedTaskSafety | `01` §4.2, invariant **I6** ("A task with a Pending `blocked_on` question may not transition to InProgress/Done") | MC (`step=taskStep`, max-steps=4) | holds | Non-vacuous under `taskStep` (see F2 note on why the default pass alone would be insufficient). |
| casSerializesTest | `01` §4.3 (optimistic concurrency preconditions) / §4.6 (CAS head-advance) | sim (10000 runs) | holds | Two candidates race against the same head; only one wins, `linearSpine and headReachable` hold post-CAS. |
| cycleRejectedTest | `01` §4.2 I4 | scenario | holds | Non-empty 2-task+edge map; a cycle-creating `addDep(2,1)` is guard-disabled. |
| blockedCannotFinishTest | `01` §4.2 I6 | scenario | holds | Real blocked, InProgress task; `setTaskDone` guard-disabled. |
| i3EvasionRejectedTest | `01` §4.2 I3 | scenario | holds | `stageChecked` with a false `isConst` flag against a kernel-touching op is guard-disabled. |

### 2.4 mailbox.qnt (`06` — blocking mailbox, correlation tokens; `08` §3.9 binding table)

| Invariant / Test | Spec § | Method | Result | Note |
|---|---|---|---|---|
| corrInjective | `06` §3.8 (correlation token -> unique QuestionId) | MC (max-steps=6) | holds | |
| answerClearsOwnNode | `06` §3.4 (answering a Question clears its gating edge) | MC (max-steps=6) | holds | |
| gatingConsistent | `06` §3.4 (gating edge <-> node-Blocked correspondence) / §2.4 (high-stakes hold-and-degrade) | MC (max-steps=6) | holds (after 2 fixes) | **See F4 and F5 (§3) — F5 is a genuine SAFETY bug.** Generalized (Task 8) from "gated iff some Open question" to "gated iff some Open **or safe-held Closed** question," a conservative extension. |
| bindingIs1to1 | `08` §3.9 (deterministic `(channel_kind, native_id) -> ExternalUserId` binding; per-channel, not global, per decision 3 / §6 item 3 of `06`) | MC (max-steps=6) | holds | Strengthened from a brief-form tautology to genuine per-channel injectivity; mutation-proven falsifiable (a same-channel collision mutant triggers a counterexample). |
| precedenceNoDeadlock | `06` §3.7 ("Cross-user precedence — deterministic, deadlock-free") | MC (max-steps=6) | holds | Strengthened to order-independence of the tie-break winner; mutation-proven (a first-arg-wins tie-break falsifies it). |
| answerRoutesToOwnQuestionTest | `06` §3.4 | scenario | holds | |
| leakedTokenRejectedTest | `06` §3.8 ("correlation token is not an authorization credential") / `08` T13 | scenario | holds | Unauthorized user with a valid token is rejected by the `may_answer` scope check. |
| neverAnsweredResolvesTest | `06` §2.4 (bounded escalation-timeout -> hold-and-degrade-safely; "no high-stakes path blocks indefinitely") | scenario | holds | A high-stakes Question that is never answered reaches the `Closed` fallback and the gated node **stays Blocked** (never proceeds on the irreversible action). |
| precedenceBreaksTieTest | `06` §3.7 | scenario | holds | |

### 2.5 consensus.qnt (`02` — 6-layer funnel, propose!=dispose, quorum)

| Invariant / Test | Spec § | Method | Result | Note |
|---|---|---|---|---|
| proposerNotDisposer | `00` §3 (separation of powers: Guardian proposes, Genesis disposes) / `02` §3.1 | MC (max-steps=10) | holds | |
| verifyBeforeVote | `02` §4.2 ("deterministic verification — first"; a vote may be cast only after `Residual`/`Certified`) | MC (max-steps=10) | holds | Exercised over both Ordinary and Constitutional tiers (Task 10 made `tier` non-constant, closing a Task-9-flagged coverage gap). |
| refutedNeverCommits | `02` §4.2 | MC (max-steps=10) | holds | |
| quorumAndThreshold | `02` §9.1 (ordinary 2/3) / §9.2 (constitutional 3/4) / §10.1 (quorum vs. threshold) | MC (max-steps=10) | holds | |
| noAutonomousLowCoverageHighBlast | `02` §5.1 (ROB-01 red-team lane / ROB-02 measured diversity), §6.6 / §11.10 (ROB-03 burn-in gates autonomy) | MC (max-steps=10) | holds | **ROB validation** — a high-blast proposal cannot auto-commit under low coverage / low diversity / burn-in; must Escalate. |
| mechanicalTiering | `02` §11.9 (UX-03: tier assignment is mechanical, not Guardian discretion) | MC (max-steps=10) | holds | `tier == Routine implies not blastHigh` — `classify` pins them together. |
| breakGlassOnlyOnDeadlock | `02` §10.4 / §11.11 (ROB-04 break-glass gated on mechanically-detected deadlock) | MC (max-steps=10) | holds | **ROB validation.** See §5 modeling-notes caveat on `detectDeadlock`'s over-approximation. |
| refutedRejectsNoVoteTest | `02` §4.2 | scenario | holds | |
| authorCannotVoteTest | `00` §3 propose!=dispose | scenario | holds | |
| ordinaryPassPathTest | `02` §9.1 | scenario | holds | Genuine 4-Approve/1-Reject round reaches Committed (non-vacuity witness for `quorumAndThreshold`/`refutedNeverCommits`). |
| correlatedCouncilCannotAutoCommitTest | `02` §5.1 (ROB-01/02/03 headline) | scenario | holds | One-family, all-Approve, high-blast, low-coverage council -> **Escalated**, not Committed. |
| breakGlassGatedTest | `02` §10.4 (ROB-04) | scenario | holds | Break-glass is guard-disabled at genesis (before any deadlock is detected). |

### 2.6 smoke.qnt (toolchain scaffold — no spec §, infra only)

| Invariant / Test | Spec § | Method | Result | Note |
|---|---|---|---|---|
| nonNegative | — (toolchain smoke test) | MC | holds | Proves the pinned Quint/Apalache toolchain runs end-to-end. |
| countsUpTest | — | scenario | holds | |

**Row count: 46** (26 MC invariant rows + 20 scenario/sim rows) across all 5 verified modules plus `base`'s 2 imported scenarios.

---

## 3. Headline findings — plan-code bugs the model surfaced (F1-F5)

These are the suite's core value: real bugs in the plan's Quint transcription, each caught
by Apalache returning a genuine counterexample, each fixed with a minimal, documented diff
(the invariant text itself was never weakened to force a pass — only the buggy action/guard
was corrected). All five are **modeling/transcription artifacts in this Quint suite's own
code**, not defects in the `specs/*.md` prose (judged individually in §4).

**F1 — budgets.qnt, `kernelFloorAvailable` (Task 3).** The original `breaksKernelFloor` guard
computed a kernel node's post-charge headroom using the **pre-charge** `subtreeSpend`,
omitting `+ amt` on the charged node's own ancestor-or-self path. Apalache found a 5-step
trace where repeated direct charges to the Guardian-class kernel node (node 1, floor 20,
cap 40) walked `stockSpent` to 21, leaving headroom `40-21=19 < 20`. **Fixed**: added the
missing `+ amt` term, mirroring the sibling `wouldExceedCap` predicate. Method: MC.

**F2 — state_model.qnt, `taskDagAcyclic` (Task 6).** The brief's `reaches` predicate is
reflexive (`reaches(t,t)` trivially true for every task), so `taskDagAcyclic = forall t: not reaches(t,t)`
was violated the instant any task existed — Apalache confirmed this once the task layer was
driven. **Fixed**: kept `reaches` reflexive (correct for `addDep`'s cycle guard, which only
calls it with `d != t`) and added a strict (>=1-edge) `reachesStrict` for the acyclicity check
itself. Method: MC.

**F3 — state_model.qnt, `addTask` (Task 6).** The brief's `addTask` called `tasks.set(t, ...)`
on a brand-new key; Quint 0.24.0's `Map.set` requires the key to already exist (runtime
`QNT507`). **Fixed**: `tasks.put(t, ...)`. Method: typecheck/runtime (caught by `quint test`).

**F4 — mailbox.qnt, `gatingConsistent` (Task 7).** The brief's `deliverAnswer` unconditionally
cleared `nodeBlocked` for the answered question's `gatesNode`. Apalache found a counterexample:
with **two Open questions gating the same node**, answering one blindly cleared the node's
block even though the other question was still Open and still gating it. **Fixed**: clear the
block only when `anotherOpenGate` (later generalized, see F5) finds no other question still
actively gating the node. Method: MC.

**F5 — mailbox.qnt, `gatingConsistent` (Task 8) — HEADLINE SAFETY BUG.** F4's fix was
incomplete: `gatingConsistent` (and its two helper predicates) modeled only ONE legitimate
block-reason (an Open question), but the design (`06` §2.4) has a SECOND — a high-stakes
question that has safe-held into `Closed` via `timeoutHighStakes` (the bounded
escalation-timeout "hold and degrade safely" fallback) still must keep its node Blocked.
Concretely: node 10 gated by q1 (Open, high-stakes) and q2 (Open). `timeoutHighStakes(q1)` ->
q1 Closed, node correctly still held. `deliverAnswer(q2)` -> q2 Answered; the F4-era
`anotherOpenGate` counted only `Open`, saw q1 was `Closed` (not `Open`), returned false, and
**wrongly cleared `nodeBlocked[10]`** — releasing a node that was still supposed to be
safe-held onto its irreversible action, directly contradicting `06` §2.4's "never proceeds on
the irreversible action" guarantee. **This is a genuine reachable safety violation the model
caught, not a tautology or a vacuous check** — it was hidden in an earlier iteration by
excluding `timeoutHighStakes` from the verified `step` relation; re-including it was required
to surface the bug rather than hide it. **Fixed**: generalized all three "what counts as an
active gate" predicates (`gatingConsistent`, `deliverAnswer`'s clear-rule, and
`answerClearsOwnNode`'s helper) from `Open`-only to `Open or Closed` (a conservative extension —
reduces exactly to the prior form whenever no `Closed` question exists), and added
`timeoutHighStakes` into the verified `step`. Re-verified: all 5 mailbox invariants NoError,
non-vacuously exercising `Closed` states. Method: MC. **This finding is the strongest
candidate for a genuine spec-prose clarification — see §4.**

---

## 4. Spec-gap judgment and issue filing

Per task instructions, each finding above was judged: is it a real gap/ambiguity in the
`specs/*.md` **prose** (something worth clarifying there), or a modeling/transcription
artifact in this Quint suite's own plan code (now fixed, no prose defect)?

- **F1, F2, F3, F4 — modeling/transcription artifacts, NOT spec gaps.** In each case the
  *invariant* (the thing `specs/*.md` actually requires — kernel floor protection, I4
  acyclicity, and the F4 two-Open-questions case) was correctly stated; the bug was in the
  Quint *action/guard* code that was supposed to enforce it, introduced during transcription
  from the plan into Quint 0.24.0 syntax (an off-by-one-transaction arithmetic slip, a
  reflexive-closure mixup, a stdlib `set`-vs-`put` API mistake, an incomplete first-pass
  guard). The prose specs (`01`, `10`) do not need clarification for any of these — no issue
  filed.

- **F5 — GENUINE SPEC-PROSE CLARIFICATION CANDIDATE. Issue filed.** `06` §3.4 states, in
  singular per-event terms: "creating a Question marks its target progress node `Blocked`;
  answering or closing a Question clears the block." Read literally, this describes clearing
  the block as a consequence of *a* Question resolving, without addressing what happens when
  **multiple Questions gate the same progress node** and they resolve into *different* states
  at different times (one still-Open, one safe-held-`Closed` per §2.4's hold-and-degrade
  fallback). §2.4 states the high-stakes fallback "stays `Blocked` ... never proceeds on the
  irreversible action," but neither §2.4 nor §3.4 explicitly says that a node's `Blocked`
  state must be treated as the **conjunction of all its active gating Questions** (not
  overwritten by the resolution of any single one). This is exactly the ambiguity the Quint
  model's F4/F5 counterexamples exploited. Filed:
  **`specs/issues/ROB-09-mailbox-safe-hold-multigate.md`** (new file; `specs/*.md` prose left
  untouched, per the hard constraint).

No other `violated`/`caveat` rows exist in the final suite (all 46 rows in §2 are `holds`),
so F1-F5 are the complete set of judged findings.

---

## 5. Bounded-MC caveat (honest disclosure)

**Every invariant in §2 marked `MC` is a bounded model check, not a proof of an unbounded /
inductive property.** All are checked under the small, fixed domains declared in
`base.qnt` (`MAX_AGENTS = 3`, `MAX_USERS = 2`, `COUNCIL_N = 5`, `MAX_DEPTH = 4`, plus each
module's own small fixed fixture — e.g. budgets' 3-node tree, mailbox's 2-question/2-node/
2-user pool, consensus's 5-seat council + break-glass widening to 7), and at the depth bound
Apalache actually explored:

| Module | Verify depth | Bound source |
|---|---|---|
| budgets.qnt | Apalache default (reached step 10, "You may increase --max-steps") | unbounded-by-declaration but only 10-deep BFS actually run |
| state_model.qnt (default step) | Apalache default (reached step 10) | same |
| state_model.qnt (`taskStep`) | **max-steps = 4** (declared) | `# VERIFY-STEP-MAX-STEPS: 4` — the combined CAS+task-graph state space is intractable at default depth in reasonable time |
| mailbox.qnt | **max-steps = 6** (declared) | `# VERIFY-MAX-STEPS: 6` — default depth 10 was INTRACTABLE for mailbox's tuple-keyed maps (held through state 8, no `NoError` in 280s); depth 6 is sound and covers the bounded 2-question/2-user/2-node domain |
| consensus.qnt | **max-steps = 10** (declared) | `# VERIFY-MAX-STEPS: 10` — ~6m50s at this depth; not deepened further for tractability |
| smoke.qnt | Apalache default | trivial single-counter model |

A property violation that only manifests **beyond** the explored depth, or outside the
declared bounded domains (more than 3 agents, more than 5+2 council seats, etc.), cannot be
ruled out by this suite. This is disclosed as a limitation of bounded model checking, not
papered over — consistent with every per-task report's own "Concerns" section.

---

## 6. Modeling notes (not findings — honest disclosure of abstraction choices)

- **`quorumMet` is non-discriminating in consensus.qnt (Task 9 note).** `decide`'s guard
  requires `votes.keys().size() == council.size()` (all 5/7 cast — a "blind round" completes
  only when everyone has voted), so `quorumMet = votes.size()*2 > council.size()` is always
  true (10 > 5) by the time `decide` fires. This is a **faithful modeling choice**, not a bug:
  the bounded model always drives full-participation rounds; `quorumMet` is kept as a real,
  separately-named predicate (matching `02` §10.1's quorum/threshold distinction) for
  spec-fidelity even though this particular fixture never exercises the "quorum missed"
  branch.
- **`detectDeadlock` over-approximates "deadlock" in consensus.qnt (Task 10 reviewer note).**
  Its guard (`not deadlockDetected and outcome != Committed`) is enabled at genesis, before any
  council round has even run — so it can "detect" a deadlock on a fresh/never-attempted round,
  not only a genuinely persistently-split one (`02` §10.4's actual trigger: persistent split
  across `max_rounds` / cannot raise quorum / chronically high dispersion). This makes
  `breakGlassOnlyOnDeadlock` **sound but weaker than the full ROB-04 narrative** — it proves
  "council widened implies *some* mechanical deadlock flag was set," not "council widened
  implies a *persistent, multi-round* split occurred." Flagged for a future tightening
  (require a completed uncommitted round, or a round counter) rather than treated as a defect
  here — the invariant genuinely holds either way, just over a broader (safer-to-satisfy)
  antecedent than the prose's precise trigger.
- **`idle` no-op stutter actions (mailbox.qnt, consensus.qnt).** Added to `step`'s `any{}` in
  both modules solely so Apalache's transition relation never deadlocks once the bounded id
  pool is exhausted or a terminal `outcome` is reached — a model-completeness artifact of
  small fixed domains, not a weakening of any invariant (every invariant is still checked at
  every state, including idle ones).

---

## 7. ROB / adversarial validations that HELD

Beyond the F1-F5 bug-catches, the suite positively validated a set of adversarial/robustness
properties from `specs/issues/` — these are confirmations the design property holds under the
bounded model, recorded here as evidence (not new findings):

| Property | Spec / issue | Module | Evidence |
|---|---|---|---|
| A correlated (single-family), confidently-wrong council cannot auto-commit a high-blast, low-coverage proposal | ROB-01, ROB-02, ROB-03 (`02` §5.1, §11.10) | consensus.qnt | `correlatedCouncilCannotAutoCommitTest` + `noAutonomousLowCoverageHighBlast` MC |
| Break-glass council recovery is gated on mechanically-detected deadlock, not freely invocable | ROB-04 (`02` §10.4) | consensus.qnt | `breakGlassGatedTest` + `breakGlassOnlyOnDeadlock` MC (see §6 caveat on `detectDeadlock`'s breadth) |
| A runaway Worker cannot drain the pool below the kernel (Guardian/Genesis) floor | ROB-05-adjacent (`10` §2.3) | budgets.qnt | `runawayWorkerRespectsKernelFloorTest` + `kernelFloorAvailable` MC |
| A leaked/guessed correlation token cannot answer another principal's blocking Question | `08` T13, `06` §3.8 | mailbox.qnt | `leakedTokenRejectedTest` |
| Optimistic-concurrency CAS serializes competing commits (no double-advance) | `01` §4.3/§4.6 | state_model.qnt | `casSerializesTest` (10000 sim runs) + `linearSpine`/`headReachable` MC |
| I3 (constitutional-iff-kernel-touching) | `01` §4.2 | state_model.qnt | `constitutionalIffKernel` MC + `i3EvasionRejectedTest` |
| I4 (task DAG acyclicity) | `01` §4.2 | state_model.qnt | `taskDagAcyclic` MC (taskStep) + `cycleRejectedTest` |
| I6 (blocked task cannot reach Done) | `01` §4.2 | state_model.qnt | `blockedTaskSafety` MC (taskStep) + `blockedCannotFinishTest` |
| A never-answered high-stakes Question resolves to a bounded safe fallback (never blocks indefinitely) and the gated node holds rather than proceeding | UX-04 (`06` §2.4) | mailbox.qnt | `neverAnsweredResolvesTest` |

---

## 8. Summary

- Suite gate: **typecheck 5/5 modules clean, test 28/28 (20 unique scenarios) passing,
  verify 6/6 passes NoError** — the suite is fully green as shipped.
- 46 invariant/scenario rows traced to spec sections in §2 (26 model-checked, 20
  scenario/sim-checked); all 46 currently `holds`.
- 5 real plan-code bugs (F1-F5) were caught and fixed during development; F5 is a genuine
  reachable safety bug (a safe-held high-stakes block could be wrongly released under a
  multi-gate interaction), now fixed and re-verified.
- Of the 5, only F5 reflects a genuine ambiguity in the `specs/*.md` prose (an implicit,
  never-stated multi-gate conjunction rule) — filed as
  `specs/issues/ROB-09-mailbox-safe-hold-multigate.md`. F1-F4 are modeling/transcription
  artifacts in this suite's own Quint code; no spec-prose issue filed for them.
- All checks are bounded model checks over small fixed domains (§5) — not unbounded/inductive
  proofs. This is disclosed, not hidden.
