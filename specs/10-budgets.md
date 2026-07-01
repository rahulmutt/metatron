# Metatron — Budgets (cost governance)

> **Status:** Research architecture specification (v0.1)
> **Audience:** Implementers of the Execution plane, the Observability plane, and the Interaction plane.
> **Scope:** This document specifies the **hierarchical budget subsystem** of Metatron — user-defined, tree-structured cost limits that agents respect by pausing or throttling when depleted, rather than relying solely on the single global soft signal. It owns the enforcement protocol, the deterministic notifier contract, and the runtime accounting types. Canonical allocation types live in `00` §7; this spec references them and does not redefine them.
> **Anchor:** Where this spec and `00-overview.md` disagree on vocabulary or a shared type, the overview wins.

---

## 1. Purpose

Metatron today provides a single global soft `cost` steering dimension (`03`) and a best-effort per-task `Budget` on `TaskSpec` (`04`). Neither composes into a **hierarchical, user-defined budget tree with roll-up accounting and cooperative pause/throttle-on-depletion**. This subsystem fills that gap.

The hierarchy is **global → per-agent-class → per-agent**. Each node carries two **orthogonal** quantities:

- **Stock** — cumulative cost a node may consume over the goal's lifetime.
- **Rate** — cost per unit time (burn-rate cap).

Budgets are denominated in `CostUnit` — the RD-4 normalized accounting currency defined in `00` §7. The existing `cost` soft signal and per-task `Budget` are not replaced; they are layered above and below (respectively) the hard caps this subsystem enforces. The `cost` setpoint continues to do smooth day-to-day steering; the budget tree is the safety envelope the controller aims never to reach.

---

## 2. Concepts

### 2.1 Two quantities

**Stock** and **rate** are orthogonal: a node can be stock-flush but rate-throttled, or rate-flush but near its stock cap. Each is governed and metered independently.

- **Stock** is cumulative. Spend accumulates monotonically over the goal's lifetime; recovery requires a user top-up or reallocation.
- **Rate** is instantaneous. Enforcement is smooth back-pressure (throttle / delay dispatch); breach is transient and self-heals as the token bucket refills.

### 2.2 The two homes

Matching Metatron's desired/actual split:

- **Allocations = governed desired state.** Live in the **configuration layer** of the world-model (`01`), changed only by typed diffs decided under governance (§3.2 below).
- **Spend = measured actual.** Lives in the **accounting ledger** (`07`) as runtime state. It is **not** committed to the Merkle log, so metering never sits on the governance critical path.

### 2.3 Reserved floor + shared burst

Per subtree, each child gets a guaranteed **floor** it can always spend into — the invariant is Σ child floors ≤ parent allocation — plus the right to draw from a shared **burst pool** (the parent's headroom above the floors) up to its own `burst_cap`. A node is constrained when **either** its own `burst_cap` **or** the parent burst pool is exhausted.

**Kernel agents (Guardian, Genesis) receive non-zero floors**, so governance stays funded under budget pressure. A runaway Worker loop cannot drain the pool to the point where Guardians cannot run the mailbox to ask for more budget, or Genesis cannot vote to retire the runaway. This preserves the core invariant that the steering loop wraps the reconciliation loop and must never be starved by it.

**Dynamic classes (Worker, Compiler, Sentinel) run mostly on burst** — no per-spawn allocation write, bounded per-agent blast radius. Their burn is lumpy and their population churns; hard per-agent partition would strand budget across a constantly-reorganizing org-chart and require a governance write on every spawn. The per-agent `burst_cap` still contains a single runaway.

Degenerate settings recover simpler models:

- `burst_cap = floor` → hard partition (guaranteed, non-overlapping slice).
- `floor = 0` → pure shared pool (overcommit).

Operators can dial the full spectrum per branch with no new machinery.

### 2.4 Token bucket for rate

Rate uses the same floor/burst shape via a **token bucket** per node: `sustained` is the refill rate (the floor analog), `burst_depth` is the bucket depth (the burst analog). A **class-level bucket doubles as admission control** on spawns — if the Worker class is at its collective rate cap, new worker spawns queue rather than thundering-herd.

---

## 3. Detailed design

### 3.1 Allocation semantics

A `BudgetNode` (defined in `00` §7) holds a `StockBudget` and a `RateBudget`. Stock allocation is governed state in the configuration layer (`01`); spend rolls up from leaf to root in the runtime ledger (`07`). Roll-up is additive: a parent node's effective remaining stock is its own cap minus the sum of all descendant spend. Rate accounting is per-node, not roll-up — each bucket is recharged independently at its own `sustained` rate.

The existing `TaskSpec.budget` (`04`) becomes a **binding to the agent's `BudgetNode`** rather than a free-standing per-task ceiling, keeping per-task enforcement and the tree consistent.

### 3.2 Governance — tiered writes

The budget tree is governed state. Allocations change via **typed diffs authored by Guardians** and slotted into the existing write-path tiering by blast radius:

- **Full council consensus** (constitutional-adjacent, ¾-style threshold per `02` §9.2) for: raising the **global ceiling** and changing **kernel floors**. These are high-blast-radius, hard-to-reverse changes.
- **Single Guardian + post-hoc audit** (optimistic concurrency on the head, per `02` §9.4) for: routine **per-agent / per-class top-ups within the existing global pool**. Reversible, low blast radius — the common case. Routing routine top-ups through full consensus would reintroduce the UX-03 throughput bottleneck.

The steering loop's `EscalateToUser{BudgetOverrun}` control action and any reallocation suggestions become ordinary Guardian-authored proposals — no new actuation path.

### 3.3 Enforcement

Enforcement lives in the execution plane (`04`) and reads the accounting ledger (`07`). The protocol is **uniform across classes**, with the soft-threshold band and grace timeout as **per-class tunables**.

| Breach | Signal | Action | Recovery |
|---|---|---|---|
| **Stock** soft threshold (`cap − shutdown_reserve`) | ledger roll-up crosses threshold | deterministic **notify** → cooperative **drain to atomic boundary** → **checkpoint** if harness supports it (`04`), else **freeze** → **hard-cancel backstop** (RD-4) after bounded grace | user top-up / reallocation; resume from snapshot or re-plan from committed state |
| **Rate** cap | token bucket empty | **throttle** (delay dispatch / shed concurrency); *no* notify | automatic as the bucket refills |
| **Sustained rate** | `03` persistently-stuck counter trips | escalate to user | user raises cap / retires agent |

Design rationale:

- **Act at a soft threshold, below the hard cap.** The `shutdown_reserve` carved under each node's cap funds the clean stop (the notification, finishing the atomic step, checkpointing). Acting only at 100% would leave nothing to pay for stopping cleanly. This is the node-level analog of the kernel floor, and mirrors the `cost` setpoint `r_cost = 0.8` (act before the ceiling).
- **Cooperative drain to an atomic boundary** (finish the current tool call / turn, then stop) prevents hard-cancelling mid-call through the `mcp-auth-proxy` (`09`) and leaving a half-applied external side effect.
- **Freeze-and-replan is always safe** because durable progress already lives in committed Merkle state (`01`); the reconciliation loop is level-triggered and idempotent, so a frozen worker resumes by re-planning — exactly how `04` already recovers a restarted agent. A harness snapshot is a bonus, never a correctness dependency.
- **Hard-cancel is the mandatory backstop, not the default.** A runaway loop or a non-cooperative thin harness that blows through the grace window is force-cancelled (RD-4). This is the same cooperative-bounded-timeout → forceful-fallback shape as the escalation-timeout → degrade-safely pattern (`06`) and the consensus-stall grace window (ROB-05).

### 3.4 The deterministic notifier

A deterministic (non-LLM) reflex guarantees the user is informed when budget is insufficient — even when no budget remains to fund the notification itself.

- **Off-budget infrastructure.** Draws from no budget node, so it is self-funding and un-starvable — defense-in-depth beneath the kernel floor. Eliminates the chicken-and-egg where notifying about exhaustion would itself cost budget.
- **Typed template, computed from the ledger.** A schema-validated mailbox item (`06`) whose every field is derived from the accounting ledger (`07`): which node depleted, spend vs. cap, what work is blocked, and the user's options. No subjective content → no LLM (determinism-first, principle 2; constrain-the-output-space, principle 1).
- **Advisory ⇒ no consensus.** A notification is not a state mutation, so it skips governance entirely — no throughput cost.
- **Debounced** with the existing deadband / hysteresis / cooldown machinery (`03`), so it fires once per depletion event, not repeatedly as spend jitters around the threshold.
- **Two-tier escalation.** The deterministic reflex is the guaranteed **floor of service** (fires at zero cost, always). If reserved-floor budget remains, the Guardian LLM *additionally* sends a richer, contextual escalation (why it happened, recommended reallocation). Guaranteed baseline + best-effort enrichment — the Tier-0/Tier-1 JIT split applied to notifications.
- **Determinism as a security property.** A drifting or compromised LLM cannot corrupt or fabricate the one message a real funding or operational decision rests on. Cross-references `08`.

**Depletion sequence:** threshold crossed → deterministic reflex notifies (zero-cost) → affected work drains/pauses (§3.3) → optional Guardian enrichment within the floor → user responds (top up / reallocate / cancel) → resume. Dovetails with the existing "wait under bounded escalation-timeout, then degrade safely" mailbox pattern (`06`).

### 3.5 Steering-loop relationship

The existing soft **`cost`** dimension (`03`) stays as a *proportional* signal layered **above** the hard stock caps. The caps are the safety floor the controller aims never to reach; the soft signal does the smooth day-to-day steering (retire workers, prefer cheaper JIT tiers, narrow council).

**Rate caps are the enforcement complement to the deferred D-term.** `03` already reasons about burn-rate spikes (runaway loops); the token bucket *acts* on them in the same cycle, before the stock budget is drained. Detection (`03`) and enforcement (`10`) are separated cleanly.

A formal **`burn_rate` control dimension** in the `ErrorVector` is noted as an **optional upgrade, deferred** until a measured need — consistent with the spec's proportional-first stance and the deferral of the D-term (OE-01).

---

## 4. Interfaces & schemas

**Allocation types** (`CostUnit`, `CostRate`, `BudgetTree`, `BudgetNodeId`, `BudgetNode`, `BudgetScope`, `StockBudget`, `RateBudget`) are canonical types defined in `00` §7. This spec references them and does not redefine them.

This spec owns the following **runtime types** (not committed to the Merkle log; live in the accounting ledger `07`):

```rust
/// Runtime accounting (07), NOT committed to the Merkle log.
struct BudgetLedger { spend: Map<BudgetNodeId, NodeSpend> }
struct NodeSpend {
    stock_spent: CostUnit,           // cumulative, rolls up to parent
    bucket_level: CostUnit,          // current token-bucket fill (rate)
    last_refill: LogicalTime,
}

/// Emitted by the enforcement path when a node crosses a threshold.
enum BudgetBreach {
    StockSoft { node: BudgetNodeId, spent: CostUnit, cap: CostUnit },
    RateThrottle { node: BudgetNodeId },
    RateSustained { node: BudgetNodeId },   // persistently-stuck (03)
}

/// The deterministic notifier's typed, schema-validated mailbox item (06).
/// Every field is computed from the ledger — no LLM.
struct BudgetNotice {
    node: BudgetNodeId,
    scope: BudgetScope,
    spent: CostUnit,
    cap: CostUnit,
    blocked_work: Vec<TaskId>,
    options: Vec<BudgetRemedy>,      // TopUpGlobal | Reallocate | Cancel
}
enum BudgetRemedy { TopUpGlobal, Reallocate, Cancel }
```

---

## 5. Resolved decisions

- **Ownership:** governed state (configuration layer) with **tiered writes** — reuses the existing write-path machinery. *(Rejected: always-consensus — UX-03 throughput risk; Guardian-owned overlay — budget authority outside propose≠dispose and the audit trail.)*
- **Allocation model:** **reserved floor + shared burst**, with a token bucket for rate. *(Rejected: hard partition — strands budget across a churning org-chart and needs a write per spawn; pure overcommit — a runaway can starve the kernel and deadlock governance.)*
- **Depletion behavior:** layered — soft threshold → cooperative drain → checkpoint-or-freeze → hard-cancel backstop; throttle (not pause) for rate. *(Rejected: always-hard-cancel — loses partial work, unsafe mid external call; checkpoint-required — thin harnesses cannot checkpoint.)*
- **Notifier:** deterministic, off-budget, typed-template, two-tier. *(Rejected: LLM-authored notification — fabrication risk on the one message a real funding/operational decision rests on; on-budget notifier — deadlocks at zero balance.)*
- **Rate:** first-class alongside stock, via token bucket; throttle on breach, escalate only on sustained throttle. *(Rejected: rate-pause-not-throttle — unnecessary for transient, self-healing breaches.)*
- **Unit:** normalized `CostUnit` (RD-4), tokens dominant. *(Rejected: raw-token denomination — breaks wall-clock-billed and thin harnesses.)*

---

## 6. Open questions & ambiguities

- **Burst-pool fairness.** Arbitration when several agents contend for the shared burst pool at once: FIFO vs. reputation-weighted vs. task-priority. Resolution will affect `BudgetNode` scheduling at the parent level.
- **Cross-user scoping.** Is the global pool per-`UserPrincipal` or shared across users? Ties into the existing open cross-user values-arbitration question in `06`.
- **Shutdown-reserve / soft-threshold sizing.** Per-class defaults for the reserve that funds a clean stop, and the width of the soft-threshold band. Requires empirical data from workload profiling.
- **`burn_rate` as a formal control dimension.** Whether it graduates into the `ErrorVector` alongside the deferred integral/derivative work (OE-01). Deferred pending a measured need.

---

## 7. Relationships to other specs

**Depends on:**

- `00` — canonical types (`CostUnit`, `BudgetNode`, `StockBudget`, `RateBudget`, `BudgetTree`, `BudgetScope`); first principles (determinism-first, constrain-the-output-space, cooperative-bounded-timeout).
- `01` — budget tree lives in the configuration layer; allocations are typed diffs; spend ledger is runtime, not committed to the Merkle log.
- `02` — tiered write path (¾-consensus for global ceiling / kernel floors; single-Guardian + audit for routine top-ups).
- `04` — enforcement protocol executes here; harness capability negotiation governs whether checkpoint is available; `TaskSpec.budget` binds to a `BudgetNode`; RD-4 cost normalization and hard-cancel backstop.
- `07` — metering substrate; per-node `BudgetLedger` + roll-up; the deterministic notifier reads exclusively from here.

**Feeds:**

- `03` — `cost` soft-signal / hard-cap relationship; sustained-throttle escalation via the persistently-stuck counter; `burn_rate` as a deferred optional dimension.
- `06` — user sets/overrides stock and rate budgets via the Interaction plane; `BudgetNotice` is a mailbox item; resume-on-top-up flow.

**Cross-references:**

- `08` — reallocation authority and governance; notifier determinism as a trust and anti-forgery property.
- `09` — cooperative drain to an atomic boundary protects in-flight `mcp-auth-proxy` calls from hard-cancel mid-call.
