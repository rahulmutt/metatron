# Design: Hierarchical Token Budgets for Metatron

> **Status:** Design (brainstorming output), 2026-07-01
> **Target:** a new subsystem spec `specs/10-budgets.md` plus threaded edits into `00`–`08`.
> **Depends on:** `00-overview.md` (canonical types, principles), `01-state-model.md`, `02-consensus.md`, `03-control-loop.md`, `04-runtime-and-harness.md`, `06-interaction-and-mailbox.md`, `07-observability.md`, `08-trust-and-security.md`.

---

## 1. Purpose & scope

Add **user-defined, hierarchical budgets** that let agents scope their work and pause or throttle when depleted, instead of relying solely on the single global soft `cost` signal that exists today (`03`).

The hierarchy is **global → per-agent-class → per-agent**. Each node carries two **orthogonal** quantities:

- **Stock** — cumulative cost a node may consume over the goal's lifetime.
- **Rate** — cost per unit time (burn-rate cap).

This is a genuine gap in the current specs. What exists is: a single global soft `cost` steering dimension (`03`), a best-effort per-task `Budget` on `TaskSpec` (`04`), RD-4 cost normalization + hard-cancel-at-threshold (`04`), and `exec.tokens_total` / `exec.cost_units_total` metering (`07`). None of these compose into a **hierarchical, user-defined budget tree with roll-up accounting and cooperative pause/throttle-on-depletion.**

The subsystem lands as one coherent spec (`specs/10-budgets.md`) with minimal edits threaded into the specs it touches (§8).

---

## 2. Data model

Budgets are denominated in a normalized **`CostUnit`** — the RD-4 common cost unit (`tokens × price + wallclock × rate`), with tokens as the dominant term so that wall-clock-billed and thin harnesses still account correctly (falling back to `wall-clock × tier-price`, flagged and reconciled, exactly as RD-4 already specifies).

Two homes, matching Metatron's desired/actual split:

- **Allocations = governed desired state.** Live in the **configuration layer** of the world-model (`01`); changed only by typed diffs decided under governance (§4).
- **Spend = measured actual.** Lives in the **accounting ledger** (`07`) as runtime state. It is **not** committed to the Merkle log, so metering never sits on the governance critical path.

Canonical types (added to `00` §7; Rust-flavored pseudotypes):

```rust
/// Normalized accounting currency (RD-4 cost unit; tokens dominate).
type CostUnit = f64;
type CostRate = f64;                 // CostUnit per second

/// A node in the budget hierarchy. Allocation only — spend lives in 07.
struct BudgetNode {
    scope:  BudgetScope,             // Global | Class(Role) | Agent(AgentId)
    stock:  StockBudget,
    rate:   RateBudget,
    parent: Option<BudgetNodeId>,
}

enum BudgetScope { Global, Class(Role), Agent(AgentId) }

/// Cumulative allocation. floor is guaranteed; burst_cap bounds draw from the
/// shared parent burst pool; shutdown_reserve is carved under the cap to fund a
/// clean stop (notify + drain + checkpoint).
struct StockBudget {
    floor:            CostUnit,      // reserved, guaranteed (may be 0)
    burst_cap:        CostUnit,      // max draw from the shared parent burst pool
    shutdown_reserve: CostUnit,      // reserved under the cap for clean shutdown
}

/// Flow allocation, implemented as a token bucket.
struct RateBudget {
    sustained:   CostRate,           // bucket refill rate
    burst_depth: CostUnit,           // bucket depth (instantaneous burst allowance)
}

/// The tree itself: part of the configuration layer (01).
struct BudgetTree { root: BudgetNodeId, nodes: Map<BudgetNodeId, BudgetNode> }
```

The existing `TaskSpec.budget: Budget` (`04`) becomes a **binding to the agent's `BudgetNode`** rather than a free-standing per-task ceiling, so per-task enforcement and the tree stay consistent.

---

## 3. Allocation semantics — reserved floor + shared burst

Per subtree:

- Each child gets a guaranteed **floor** (Σ child floors ≤ parent allocation) it can always spend into, plus the right to draw from a shared **burst pool** (the parent's headroom above the floors) up to its own `burst_cap`.
- A node is constrained when **either** its own `burst_cap` **or** the parent burst pool is exhausted.

Why this shape (not hard partition, not pure overcommit):

- **Kernel agents (Guardian, Genesis) get non-zero floors → governance stays funded under budget pressure.** A runaway Worker loop cannot drain the pool to the point where Guardians can't run the mailbox to ask for more budget, or Genesis can't vote to retire the runaway. This preserves the core invariant that the steering loop is wrapped *around* the reconciliation loop and must never be starved by it. Mirrors the existing "degrade safely / never block indefinitely / founder break-glass" philosophy.
- **Dynamic classes (Worker, Compiler, Sentinel) run mostly on burst → no per-spawn allocation write, bounded per-agent blast radius.** Their burn is lumpy and their population churns; hard per-agent partition would strand budget across a constantly-reorganizing org-chart and require a governance write on every spawn. The per-agent `burst_cap` still contains a single runaway.

**Rate uses the same shape via a token bucket** per node: `sustained` is the refill rate (the "floor" analog), `burst_depth` is the depth (the "burst" analog). A **class-level bucket doubles as admission control** on spawns — if the Worker class is at its collective rate cap, new worker spawns queue rather than thundering-herd.

Degenerate settings recover the simpler models, so operators can dial the whole spectrum per branch with no new machinery:

- `burst_cap = floor` → hard partition (guaranteed, non-overlapping slice).
- `floor = 0` → pure shared pool (overcommit).

---

## 4. Governance integration — tiered writes

The budget tree is governed state, so allocations change via **typed diffs authored by Guardians** and slotted into the existing write-path tiering by blast radius:

- **Full council consensus** (constitutional-adjacent, ¾-style threshold) for: raising the **global ceiling**, and changing **kernel floors**. These are high-blast-radius / hard-to-reverse.
- **Single Guardian + post-hoc audit** (optimistic concurrency on the head) for: routine **per-agent / per-class top-ups within the existing global pool**. Reversible, low blast radius — this is the common case, and routing it through full consensus would reintroduce the UX-03 throughput bottleneck.

The steering loop's `EscalateToUser{BudgetOverrun}` control action and any reallocation suggestions become ordinary Guardian-authored proposals — no new actuation path.

---

## 5. Enforcement

Enforcement lives in the execution plane (`04`) and reads the accounting ledger (`07`).

| Breach | Signal | Action | Recovery |
|---|---|---|---|
| **Stock** soft threshold (`cap − shutdown_reserve`) | ledger roll-up crosses threshold | deterministic **notify** (§6) → cooperative **drain to atomic boundary** → **checkpoint** if the harness exposes checkpoint/preempt (`04`), else **freeze** → **hard-cancel backstop** (RD-4) after a bounded grace timeout | user top-up / reallocation; resume from snapshot, or re-plan from last committed state |
| **Rate** cap | token bucket empty | **throttle** — delay dispatch / shed concurrency; **no** notify (transient, self-healing) | automatic as the bucket refills |
| **Sustained rate** | `03` persistently-stuck counter trips (rate dimension out of tolerance too long) | escalate to user (cap is mis-set, or a runaway is sustained not spiky) | user raises cap / retires agent |

Design rationale:

- **Act at a soft threshold, below the hard cap.** The `shutdown_reserve` carved under each node's cap funds the clean stop (the notification, finishing the atomic step, checkpointing). Acting only at 100% would leave nothing to pay for stopping cleanly. This is the node-level analog of the kernel floor, and mirrors the `cost` setpoint `r_cost = 0.8` (act before the ceiling).
- **Cooperative drain to an atomic boundary** (finish the current tool call / turn, then stop) prevents hard-cancelling mid-call through the `mcp-auth-proxy` (`09`) and leaving a half-applied external side effect.
- **Freeze-and-replan is always safe** because durable progress already lives in committed Merkle state (`01`); the reconciliation loop is level-triggered and idempotent, so a frozen worker resumes by re-planning — exactly how `04` already recovers a restarted agent. A harness snapshot is a bonus, never a correctness dependency.
- **Hard-cancel is the mandatory backstop, not the default.** A runaway loop or a non-cooperative thin harness that blows through the grace window is force-cancelled (RD-4). Same "cooperative, bounded-timeout → forceful fallback" shape as the escalation-timeout→degrade-safely (`06`) and the consensus-stall grace window (ROB-05).
- **Rate breaches must not escalate while transient.** Throttling is smooth back-pressure that self-heals as the bucket refills; only *sustained* throttling — caught by the existing persistently-stuck counter (`03`) — is worth a user's attention. Non-cooperative harnesses can't be slowed mid-session, so a sustained rate breach on such a harness falls back to the stock hard-cancel path.

The protocol is **uniform across classes**, with the soft-threshold band and grace timeout as **per-class tunables** (kernel agents rarely hit it thanks to their floors; workers are the common case).

---

## 6. Deterministic budget notifier

A deterministic (non-LLM) reflex that guarantees the user is told when budget is insufficient — even when there is no budget left to spend on telling them.

- **Off-budget infrastructure.** Draws from *no* budget node, so it is self-funding and un-starvable — defense-in-depth *beneath* the kernel floor, not competing with it. Removes the chicken-and-egg where notifying about exhaustion would itself cost budget.
- **Typed template, computed from the ledger.** A schema-validated mailbox item (`06`) whose every field is derived from the accounting ledger (`07`): which node depleted, spend vs. cap, what work is blocked, and the user's options (top up global / reallocate / cancel). No subjective content → no LLM (determinism-first, principle 2; constrain-the-output-space, principle 1).
- **Advisory ⇒ no consensus.** A notification is not a state mutation, so it skips governance entirely — no throughput cost.
- **Debounced** with the existing deadband / hysteresis / cooldown machinery (`03`), so it fires once per depletion event, not repeatedly as spend jitters around the threshold.
- **Two-tier escalation.** The deterministic reflex is the guaranteed **floor of service** (fires at zero cost, always). If reserved-floor budget remains, the Guardian LLM *additionally* sends a richer, contextual escalation (why it happened, recommended reallocation). Guaranteed baseline + best-effort enrichment — the Tier-0/Tier-1 JIT split applied to notifications.
- **Determinism as a security property.** A drifting or compromised LLM cannot corrupt or fabricate the one message a real funding/operational decision rests on. Cross-references `08`.

**Depletion sequence:** threshold crossed → deterministic reflex notifies (zero-cost) → affected work drains/pauses (§5) → optional Guardian enrichment within the floor → user responds (top up / reallocate / cancel) → resume. Dovetails with the existing "wait under bounded escalation-timeout, then degrade safely" mailbox pattern (`06`).

---

## 7. Steering-loop relationship (`03`)

- The existing soft **`cost`** dimension stays as a *proportional* signal layered **above** the hard stock caps. The caps are the safety floor the controller aims never to reach; the soft signal does the smooth day-to-day steering (retire workers, prefer cheaper JIT tiers, narrow council).
- **Rate caps are the enforcement complement to the deferred D-term.** `03` already reasons about "burn-rate spikes (runaway loops)"; the token bucket *acts* on them in the same cycle, before the stock budget is drained. Detection (`03`) and enforcement (`10`) are separated cleanly.
- A formal **`burn_rate` control dimension** in the `ErrorVector` is noted as an **optional upgrade, deferred** until a measured need — consistent with the spec's proportional-first stance and the deferral of the D-term (OE-01).

---

## 8. Threaded edits (per the "new spec + thread" decision)

| Spec | Edit |
|---|---|
| `00-overview.md` | Add `CostUnit`, `BudgetNode`, `StockBudget`, `RateBudget`, `BudgetTree`, `BudgetScope` to canonical types; glossary entries (stock vs. rate budget, budget tree, shutdown reserve, deterministic notifier, token bucket). |
| `01-state-model.md` | Budget tree is part of the **configuration layer**; allocations are typed diffs; **spend ledger is runtime, not committed** — clarify the desired(allocation)/actual(spend) split. |
| `02-consensus.md` | Budget reallocation as a typed proposal; tiering by blast radius (global-ceiling / kernel-floor = higher threshold; in-pool top-ups = single-Guardian + audit). |
| `03-control-loop.md` | `cost` soft-signal / hard-cap relationship; sustained-throttle escalation via the persistently-stuck counter; `burn_rate` as an optional deferred dimension. |
| `04-runtime-and-harness.md` | Enforcement protocol (soft threshold, drain-to-boundary, checkpoint-or-freeze, grace, hard-cancel backstop, throttle for rate); link `TaskSpec.budget` to the `BudgetNode`; extend RD-4. |
| `06-interaction-and-mailbox.md` | User sets/overrides stock & rate budgets via the Interaction plane; deterministic notifier + templated mailbox item; resume-on-top-up flow. |
| `07-observability.md` | Accounting substrate: per-node ledger + roll-up; per-node/class/agent spend and burn-rate gauges; the notifier reads from here. |
| `08-trust-and-security.md` | Reallocation authority; notifier determinism as a trust/anti-forgery property. |

---

## 9. Resolved decisions

- **Ownership:** governed state (configuration layer) with **tiered writes** — reuses the existing write-path machinery. *(Rejected: always-consensus (UX-03 throughput risk); Guardian-owned overlay (budget authority outside propose≠dispose and the audit trail).)*
- **Allocation model:** **reserved floor + shared burst**, with a token bucket for rate. *(Rejected: hard partition — strands budget across a churning org-chart and needs a write per spawn; pure overcommit — a runaway can starve the kernel and deadlock governance.)*
- **Depletion behavior:** layered — soft threshold → cooperative drain → checkpoint-or-freeze → hard-cancel backstop; throttle (not pause) for rate. *(Rejected: always-hard-cancel (loses partial work, unsafe mid external call); checkpoint-required (thin harnesses can't).)*
- **Notifier:** deterministic, off-budget, typed-template, two-tier.
- **Rate:** first-class alongside stock, via token bucket; throttle on breach, escalate only on sustained throttle.
- **Unit:** normalized `CostUnit` (RD-4), tokens dominant.
- **Spec structure:** new `specs/10-budgets.md` + threaded edits.

---

## 10. Open questions

- **Burst-pool fairness.** Arbitration when several agents contend for the shared burst pool: FIFO vs. reputation-weighted vs. task-priority. *(New.)*
- **Cross-user scoping.** Is the global pool per-`UserPrincipal` or shared across users? Ties into the existing open cross-user *values*-arbitration question (`06`).
- **Shutdown-reserve / soft-threshold sizing.** Per-class defaults for the reserve that funds a clean stop, and the soft-threshold band.
- **`burn_rate` as a formal control dimension.** Whether it graduates into the `ErrorVector` alongside the deferred integral/derivative work (OE-01).

---

## 11. Relationships

Depends on `00` (types, principles), `01` (config layer, desired/actual split), `02` (tiered write path), `04` (harness capabilities, RD-4, reconciliation recovery), `07` (metering substrate). Feeds `03` (cost/rate signals, escalation) and `06` (user budget-setting, notifier/mailbox). Cross-references `08` (reallocation authority, notifier determinism as trust) and `09` (clean-boundary drain protects in-flight external calls).
