# Metatron Quint Spec Suite — Design

**Date:** 2026-07-01
**Status:** Approved design, pre-implementation
**Author:** brainstormed with Rahul Muttineni

## Purpose

Build a **modular set of formal specifications in [Quint](https://quint-lang.org)**
that *actively test* the load-bearing ideas in the Metatron research architecture
(`specs/*.md`) for **feasibility and spec correctness**. Each subsystem is modeled
as a state machine whose claimed invariants are exercised by randomized simulation,
named scenario tests (including adversarial ones drawn from the `ROB-*`/`OE-*`/`UX-*`
issue backlog), and bounded model-checking (Apalache). The goal is to falsify
spec claims where they don't hold and to document what does.

This is a **verification artifact**, not a re-implementation. It sits alongside the
prose specs and reports back to them.

## Scope

Decisions locked during brainstorming:

| Decision | Choice |
|----------|--------|
| **Coverage** | Core governance spine: shared base (from `00`) + `01` state-model, `02` consensus, `06` interaction/mailbox, `10` budgets. Other subsystems (`03`, `04`, `05`, `07`, `08`, `09`) are out of scope for this pass; the suite is designed to extend to them later. |
| **Rigor** | Full bar: type-checking + invariants + named `run`/scenario tests (incl. adversarial) + randomized simulation + **Apalache bounded model-checking** on core safety invariants. |
| **On findings** | Document + file issues. A `FINDINGS.md` traceability report records every invariant → spec § → holds/violated/caveat. Genuine gaps get an appended note in `specs/issues/`. **Prose spec bodies (`specs/*.md`) are left untouched.** |
| **Architecture** | Shared base + independent per-subsystem modules (Option A below). |

### Architecture options considered

- **A — Shared base + 4 independent modules (chosen).** One `base.qnt` mirroring
  `00`'s canonical types; each subsystem is a self-contained state machine importing
  *only* base. Cross-subsystem concepts are modeled as abstract oracles/parameters,
  not real imports. Keeps each subsystem falsifiable in isolation and model-checkable
  independently. The abstract seams are themselves documented assumptions.
- **B — One integrated end-to-end model.** More faithful to cross-plane interaction
  but the state-space product makes MC intractable and loses the "test each idea in
  isolation" property. Rejected.
- **C — Genuinely composed modules** (e.g. consensus advances a real state-model head).
  Couples verification — a bug in one blocks checking another, MC cost climbs. Rejected.

## Layout & tooling

```
specs/quint/
  base.qnt              # canonical types from 00 (shared vocabulary)
  state_model.qnt       # 01 — Merkle log, typed diffs, CAS head
  consensus.qnt         # 02 — 6-layer funnel, propose≠dispose, quorum
  mailbox.qnt           # 06 — blocking mailbox, correlation tokens, precedence
  budgets.qnt           # 10 — hierarchical stock+rate, layered stop
  README.md             # how to run, abstraction conventions, module map
  FINDINGS.md           # traceability: invariant → spec § → holds / violated
```

- **Install via mise** (per devkit developer-environment): pin `quint` (npm) and
  **Apalache** (JVM), the latter required for the `--verify` bounded-MC bar.
- **Named tasks** (mise `[tasks]`, per devkit navigable-codebases):
  - `quint-typecheck` — typecheck every module.
  - `quint-test` — run all `run`/scenario tests across modules.
  - `quint-verify` — Apalache MC on each module's core safety invariants.
  - One aggregate task runs the whole suite so completion claims have real output.

## Abstraction conventions

Formal models are only meaningful if their abstractions are explicit. These live in
`base.qnt` and `README.md`:

- **Ids** (`Hash`, `AgentId`, `BudgetNodeId`, …) → **bounded `int`** over small
  domains (≤3 agents, ≤2 users, a 5-member council, ≤4-deep commit chain) chosen so
  Apalache terminates.
- **Crypto is not modeled.** `Signature`/`QuorumCertificate` collapse to an abstract
  `verifyQuorum(signers, kernelSet)` predicate. We test the protocol, not Ed25519.
- **LLM stochasticity** → nondeterministic `any` choice over voter verdicts, with an
  explicit **correlation parameter** (shared `model_family`) so ROB-01/ROB-02 are
  expressible.
- **Merkle collections** → plain Quint maps/sets (the bespoke HAMT/MST is dropped in
  OE-04 regardless).
- **The consensus aggregator** is modeled by its *properties* (monotone,
  weight-bounded, `<0.5`→0, floored ≥0) rather than a concrete formula — the exact
  correlation-aware form is an open research question (`02` §12).
- **`00` is normative.** Where a module's vocabulary could diverge, base follows `00`.

## Per-module content

Each module = state variables + actions (`step`) + **safety invariants**
(Apalache-checked) + **temporal/liveness** properties (bounded, fairness-lite) +
named **`run` scenario tests**, including **adversarial** ones from the issue backlog.

### `base.qnt` — shared vocabulary (from `00`)

Ported canonical types: `AgentId`, agent roles (Guardian/Genesis/Worker/Compiler/
Sentinel) with the kernel/dynamic split, `Layer`, `CostUnit`/`CostRate`, `LogicalTime`,
`ExternalUserId` (distinct principal type from `AgentId`), `ChannelKind`. Shared
helpers and the abstraction constants (domain bounds). No behavior — types + `pure def`
helpers only.

### `state_model.qnt` — `01` state-model

- **State:** `head`, content-addressed `store`, staged candidate commits.
- **Safety invariants:** head reachable from genesis via parent chain; **linear spine**
  (no two accepted commits share a parent — tests CAS serialization); gap-free monotonic
  `LogicalTime`; **replay determinism** (folding diffs re-derives each `state_root`);
  diff invariants I1–I7 (no dangling refs, acyclic task DAG, `constitutional` set **iff**
  KernelSet touched, blocked-task safety I6, legal status transitions, target/ops match).
- **Liveness:** head eventually advances under competing candidates (no head deadlock);
  answered questions eventually unblock gated tasks.
- **Adversarial:** N concurrent candidates → exactly one head, never a double-advance;
  a `constitutional=false` diff mutating KernelSet must be rejected (I3 evasion);
  `AddTaskDep` cycle rejected (I4); drive a `blocked_on:Pending` task to `Done` (must be
  impossible, I6).

### `consensus.qnt` — `02` consensus

- **State:** a proposal record moving through the 6 layers — typed proposal, verification
  verdict (Refuted/Certified/Residual), council, sealed/revealed votes, reputation weights,
  deliberation round, outcome (Committed/Rejected/Escalated); write-tier (Routine/Ordinary/
  Constitutional); burn-in flag.
- **Safety invariants:** **proposer ≠ disposer** (no agent authors *and* votes);
  **verify-before-vote** (no vote before `Residual`/constitutional-carve-out); Refuted ⇒
  never commits; pass requires **both** `posterior ≥ threshold` **and**
  `participating_weight ≥ quorum_weight`; ⅔ ordinary vs ¾ constitutional; constitutional
  carve-out (no Certified fast-path for kernel changes); break-glass only under mechanical
  deadlock and not self-ratified; **no single agent swings weight** (ROB-06 k-of-n).
- **Liveness:** every proposal → Committed|Rejected|Escalated (never blocks forever);
  bounded deliberation (`max_rounds`); bounded escalation → hold-and-degrade, no silent
  irreversible progression.
- **Adversarial:** ROB-01 (correlated confident-wrong council + low verification coverage
  must **not** autonomously commit; low dispersion ≠ correctness); ROB-02 (single-family
  quorum is not an independent quorum — high-blast-radius holds/escalates); ROB-03
  (burn-in blocks low-coverage high-blast-radius at genesis/after recomposition); ROB-04
  (persistent deadlock always has an actuator — no livelock); UX-03 (tier assignment is
  mechanical — a Guardian cannot self-classify a consequential/irreversible/constitutional
  change as Routine to dodge the council; unknown reversibility ⇒ escalate).

### `mailbox.qnt` — `06` interaction & mailbox

- **State (keyed by `ExternalUserId`):** questions + `QuestionState`, open-question index
  `(user, qid)`, `CorrelationToken → QuestionId` map, binding table
  `(ChannelKind, native_id) → ExternalUserId`, per-user `AuthorizationScope` (rank,
  may_answer), progress-node `Blocked/Ready` flags, logical clock.
- **Safety invariants:** injective `CorrelationToken → QuestionId`; a delivered Answer
  clears **exactly** its gated node; `may_answer` authorization required (a token match
  alone never authorizes — T13); **1:1 identity binding**; tenancy isolation (one user's
  open questions never surface in another's mailbox except explicit fan-out); gating
  consistency (node Blocked iff an Open question gates it); **unknown-reversibility ⇒
  HighStakes ⇒ never auto-proceeds** (ROB-07).
- **Liveness:** no question stays `Open` forever (answered | escalated up precedence |
  bounded-timeout fallback); **deterministic (rank, first-committed) precedence never
  deadlocks**; low-stakes blocked work always eventually proceeds; blocking one node
  never stalls unrelated nodes.
- **Adversarial:** never-answering human oracle (UX-04 — every wait bounded); leaked/guessed
  `CorrelationToken` used to answer another principal's question (rejected by `may_answer`);
  channel spoofing via forged `(channel_kind, native_id)`; false-merge of two genuinely
  different ambiguities fanning one wrong Answer; two authorized users mutually blocking on
  a shared goal (precedence breaks it).

### `budgets.qnt` — `10` budgets

- **State:** `tree` of `BudgetNode` allocations (governed), `ledger` of `NodeSpend`
  (runtime, not committed), per-node execution status (Running/Notified/Draining/Frozen/
  Cancelled/Throttled), notifier outbox, logical clock.
- **Safety invariants:** `stock_spent ≤ cap` always (hard-cancel backstop guarantees the
  ceiling even for non-cooperative harnesses); Σ child floors ≤ parent allocation;
  hierarchical roll-up remains ≥0; **kernel floor always available under adversarial spend**
  (a runaway Worker can never drain below the Guardian/Genesis floor); `bucket_level ≤
  burst_depth`; **layered-stop ordering respected** (no Running→Cancelled skip except the
  grace-expiry backstop); **notifier is off-budget / un-starvable** (fires even at zero
  global balance and never decrements any ledger entry); fast-path top-up can never mutate
  global ceiling or kernel floors (only the constitutional path can).
- **Liveness:** a depleted stock node eventually reaches Frozen|Cancelled within bounded
  grace; a throttled rate node self-heals on refill; every depletion event yields **exactly
  one** `BudgetNotice`; a frozen node resumes after a top-up/reallocation remedy.
- **Adversarial:** runaway worker vs kernel floor (ROB-05 scenario — the Guardian still runs
  the mailbox to request more budget under a consensus stall); adversarially-small
  `shutdown_reserve` that cannot fund a clean stop (boundary test on the reserve-sizing
  invariant — is the reserve always sufficient to fund notify+drain+checkpoint?);
  deadlocked council can't raise the ceiling, yet notifier + kernel floor still hold (ROB-04).

## Findings handling

- `FINDINGS.md` — one row per invariant: module, spec §, method (MC/sim/scenario),
  result (**holds / violated / caveat**), and for violations the minimal counterexample
  trace Apalache produced.
- Genuine gaps get an appended note in `specs/issues/` — a new `ROB-*`/`OE-*`-style file,
  or an addendum to the existing issue the model stresses.
- **`specs/*.md` prose bodies are not modified.**

## Build order & validation

Incremental, one module at a time, each fully green before the next:

**base → budgets → state_model → mailbox → consensus**

(budgets is the most self-contained warm-up; consensus is the richest, done last.)
For each module: typecheck → `run` scenarios pass → Apalache MC on its safety invariants
clean (or the counterexample is recorded as a finding). No module is "done" until
`quint-verify` runs and its output is shown.

## Out of scope

- Subsystems `03` (control-loop — continuous dynamics), `04` (runtime/harness),
  `05` (agent-JIT), `07` (observability — data-model-heavy), `08` (trust/security beyond
  the `06` binding table), `09` (mcp-auth-proxy). The suite is structured to add these as
  later modules.
- Modeling cryptography, the Merkle HAMT/MST engine, or concrete LLM behavior.
- Editing prose spec bodies (`specs/*.md`).
```
