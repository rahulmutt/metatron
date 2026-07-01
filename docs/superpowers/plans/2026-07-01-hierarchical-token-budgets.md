# Hierarchical Token Budgets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author a new subsystem spec `specs/10-budgets.md` for user-defined hierarchical (global → per-class → per-agent) stock+rate budgets, and thread the required cross-references into specs `00`–`08` and `README.md`.

**Architecture:** This is a **documentation/spec repository** (pure Markdown, no code, no test framework). "Implementation" = authoring one new spec file plus precise cross-reference edits into existing specs. The canonical types land in `00` first (the repo's rule is *"when any spec disagrees with `00`, `00` wins"*), then `10-budgets.md` is authored against them, then each consuming spec gets its threaded edit, then a final repo-wide consistency pass.

**Tech Stack:** Markdown. Rust-flavored pseudotypes in code blocks (repo convention). No build/test toolchain — the "test cycle" for each task is a **verification step** (grep/inspection with expected output) confirming the edit landed, cross-references resolve, and conventions hold.

**Source of truth for content:** the committed design doc `docs/superpowers/specs/2026-07-01-hierarchical-token-budgets-design.md` (commit `3b39393`). This plan gives the exact structural placement, the exact canonical type blocks, and verbatim insertion text; where a section needs full prose, it cites the design-doc section to expand from. Do **not** re-derive design decisions — they are resolved in the design doc §9.

## Global Constraints

- **`00` wins on vocabulary.** All shared types go in `00` §7 and all shared terms in `00` §8 *before* any other spec references them. Consuming specs reference, never redefine. (`00` §preamble)
- **Section structure for a subsystem spec:** `Purpose → Concepts → Detailed design → Interfaces & schemas → Resolved decisions → Open questions & ambiguities → Relationships to other specs`. (README "Conventions"; matches `04`, `03`.)
- **Code blocks are Rust-flavored pseudotypes.** (README "Conventions")
- **Denomination unit is `CostUnit`** = RD-4 normalized cost (`tokens × price + wallclock × rate`), tokens dominant. Never denominate a budget in raw tokens in normative text. (design doc §2; `04` RD-4)
- **Spend is runtime, not committed.** Allocations live in the configuration layer (`01`); measured spend lives in the `07` ledger and is never written to the Merkle log. (design doc §2)
- **Issues directory is for the adversarial review only.** New open questions go in the spec's own *Open questions* section, not as new `specs/issues/*` files. (README, issues/README.md)
- **Cross-reference style:** bare spec number in backticks, e.g. `` (`07`) ``, matching existing prose.

---

### Task 1: Canonical budget types & glossary in `00`

**Files:**
- Modify: `specs/00-overview.md` — §7 Canonical Interfaces & Types (ends line 299, before `## 8. Glossary`); §8 Glossary (lines 303-339); §9 diagram (lines 344-368).

**Interfaces:**
- Produces (every later task depends on these exact names/shapes): `CostUnit`, `CostRate`, `BudgetTree`, `BudgetNodeId`, `BudgetNode`, `BudgetScope`, `StockBudget`, `RateBudget`. Field names are load-bearing: `StockBudget { floor, burst_cap, shutdown_reserve }`, `RateBudget { sustained, burst_depth }`, `BudgetNode { scope, stock, rate, parent }`.

- [ ] **Step 1: Add the budget type group to `00` §7.** Insert this block at the end of §7's code (immediately before the closing of the last code fence at line ~298, after the `McpAuthProxy` trait — as a new comment group):

````rust
// ---- Budgets (10) ----
/// Normalized accounting currency: the RD-4 common cost unit
/// (tokens × price + wallclock × rate), tokens dominant. See 04 (RD-4), 07.
type CostUnit = f64;
type CostRate = f64;                 // CostUnit per second

/// The budget hierarchy. Part of the CONFIGURATION layer (01); governed state.
/// Allocation only — measured spend is runtime, in the 07 ledger (never committed).
struct BudgetTree { root: BudgetNodeId, nodes: Map<BudgetNodeId, BudgetNode> }
type BudgetNodeId = Hash;

struct BudgetNode {
    scope:  BudgetScope,             // Global | Class(Role) | Agent(AgentId)
    stock:  StockBudget,
    rate:   RateBudget,
    parent: Option<BudgetNodeId>,    // None at the Global root
}
enum BudgetScope { Global, Class(Role), Agent(AgentId) }   // Role = the 00 §3 taxonomy role

/// Cumulative allocation. `floor` is guaranteed (may be 0); `burst_cap` bounds
/// draw from the shared parent burst pool; `shutdown_reserve` is carved under
/// the cap to fund a clean stop (notify + drain + checkpoint). See 10.
struct StockBudget { floor: CostUnit, burst_cap: CostUnit, shutdown_reserve: CostUnit }

/// Flow allocation as a token bucket: `sustained` = refill rate, `burst_depth` = depth.
struct RateBudget { sustained: CostRate, burst_depth: CostUnit }
````

- [ ] **Step 2: Add glossary rows to `00` §8.** Insert these rows into the table (alphabetical-ish placement is fine; the table is not strictly sorted):

```markdown
| **Budget tree / `BudgetNode`** | The governed global→class→agent hierarchy of cost *allocations*, part of the configuration layer. Spend is measured separately in `07`. (`10`) |
| **Stock budget** | A node's cumulative cost allowance over the goal's life. (`10`) |
| **Rate budget** | A node's flow allowance (cost per unit time), enforced as a token bucket. (`10`) |
| **Shutdown reserve** | Cost carved under a node's cap to fund a clean stop (notify + drain + checkpoint) before the hard cap. (`10`) |
| **Deterministic budget notifier** | An off-budget, non-LLM reflex that emits a typed mailbox alert on stock depletion — self-funding, un-forgeable. (`10`, `06`) |
| **`CostUnit`** | The normalized accounting currency (RD-4: tokens×price + wallclock×rate), the denomination of all budgets. (`10`, `04`, `07`) |
```

- [ ] **Step 3: Add `10` to the spec-relationship diagram in `00` §9.** In the ASCII tree (lines 344-368), add under the `01` subtree (budgets live in the config layer) a line:

```
   │       ├── 10-budgets ......... budget tree in config layer; enforcement, notifier
```
Place it after the `06-interaction` line within the `01` branch so the indentation matches its siblings.

- [ ] **Step 4: Verify the edits landed and types are self-consistent.**

Run: `grep -nE "BudgetNode|StockBudget|RateBudget|BudgetScope|CostUnit|Budget tree|Deterministic budget notifier|10-budgets" specs/00-overview.md`
Expected: hits in the §7 code block (all struct/type names), the §8 glossary (all 6 rows), and the §9 diagram (`10-budgets`). Confirm `shutdown_reserve`, `burst_cap`, `floor`, `sustained`, `burst_depth` all appear exactly once in the struct defs.

- [ ] **Step 5: Commit.**

```bash
git add specs/00-overview.md
git commit -m "specs/00: add canonical budget types, glossary, and 10-budgets to diagram"
```

---

### Task 2: Author `specs/10-budgets.md`

**Files:**
- Create: `specs/10-budgets.md`

**Interfaces:**
- Consumes (from Task 1): all `00` §7 budget types.
- Produces (referenced by Tasks 3-9): the enforcement protocol table, the notifier contract, and the ledger/enforcement pseudotypes owned by this spec (`BudgetLedger`, `NodeSpend`, `BudgetBreach`, `BudgetNotice`). Later tasks cite this spec by number; they do not need its internal type names except where noted.

Author the file with the standard seven-section structure. Each step writes one section; expand prose from the cited design-doc section, keeping every normative decision verbatim from design doc §9.

- [ ] **Step 1: Title + status banner + Purpose (§1).** Header `# Metatron — Budgets (cost governance)`, a status banner matching `04`'s format (`> **Status:** …`), then §1 Purpose from design doc §1. Must state: hierarchy global→class→agent; two orthogonal quantities (stock, rate); the gap it fills vs. today's single soft `cost` signal (`03`) and best-effort per-task `Budget` (`04`).

- [ ] **Step 2: Concepts (§2).** From design doc §2–§3. Subsections: **2.1 Two quantities** (stock vs rate); **2.2 The two homes** (allocation = governed config `01`; spend = runtime ledger `07`); **2.3 Reserved floor + shared burst** (the allocation invariant Σ child floors ≤ parent; kernel-stays-funded rationale; degenerate settings `burst_cap=floor` → hard partition, `floor=0` → pure pool); **2.4 Token bucket for rate** (sustained=refill, burst_depth=depth; class bucket = admission control).

- [ ] **Step 3: Detailed design (§3).** From design doc §3–§7. Subsections: **3.1 Allocation semantics**; **3.2 Governance — tiered writes** (global-ceiling/kernel-floor = ¾ constitutional per `02` §9.2; in-pool top-ups = single-Guardian + audit per `02` §9.4); **3.3 Enforcement** — reproduce the enforcement matrix table verbatim:

```markdown
| Breach | Signal | Action | Recovery |
|---|---|---|---|
| **Stock** soft threshold (`cap − shutdown_reserve`) | ledger roll-up crosses threshold | deterministic **notify** → cooperative **drain to atomic boundary** → **checkpoint** if harness supports it (`04`), else **freeze** → **hard-cancel backstop** (RD-4) after bounded grace | user top-up / reallocation; resume from snapshot or re-plan from committed state |
| **Rate** cap | token bucket empty | **throttle** (delay dispatch / shed concurrency); *no* notify | automatic as the bucket refills |
| **Sustained rate** | `03` persistently-stuck counter trips | escalate to user | user raises cap / retires agent |
```
Include the four rationale bullets from design doc §5 (soft-threshold + shutdown_reserve; drain-to-atomic-boundary protects `mcp-auth-proxy` calls `09`; freeze-and-replan safe because progress is in committed state `01`; hard-cancel is the mandatory backstop). **3.4 The deterministic notifier** (design doc §6: off-budget, typed template computed from the `07` ledger, advisory⇒no-consensus, debounced via `03` deadband/hysteresis, two-tier, determinism-as-security). **3.5 Steering-loop relationship** (design doc §7: soft `cost` above hard caps; rate caps = enforcement complement to the deferred D-term; `burn_rate` dimension deferred).

- [ ] **Step 4: Interfaces & schemas (§4).** Reference `00` §7 for the allocation types (do not redefine). Define the types this spec *owns* (runtime, not in `00`):

````rust
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
````

- [ ] **Step 5: Resolved decisions (§5).** Reproduce design doc §9 (six resolved decisions with their rejected alternatives). Keep the rejected-alternative parentheticals — they carry the rationale.

- [ ] **Step 6: Open questions & ambiguities (§6).** Reproduce design doc §10 (burst-pool fairness; cross-user scoping — cross-ref `06`'s open cross-user arbitration; shutdown-reserve/soft-threshold sizing; `burn_rate` as a formal dimension — cross-ref OE-01).

- [ ] **Step 7: Relationships to other specs (§7).** From design doc §11: depends on `00`, `01`, `02`, `04`, `07`; feeds `03`, `06`; cross-refs `08`, `09`.

- [ ] **Step 8: Verify structure, conventions, and no dangling references.**

Run: `grep -nE "^#{1,2} " specs/10-budgets.md`
Expected: the seven top-level sections in order (Purpose, Concepts, Detailed design, Interfaces & schemas, Resolved decisions, Open questions, Relationships).

Run: `grep -oE "CostUnit|BudgetNode|StockBudget|RateBudget|BudgetScope|BudgetTree" specs/10-budgets.md | sort -u`
Expected: every referenced `00` type name appears — and confirm by eye that none are *redefined* (only `BudgetLedger`, `NodeSpend`, `BudgetBreach`, `BudgetNotice`, `BudgetRemedy` are defined here).

Run: `grep -nE "raw token|tokens/min budget|token budget of [0-9]" specs/10-budgets.md`
Expected: no hits denominating budgets in raw tokens (must use `CostUnit`).

- [ ] **Step 9: Commit.**

```bash
git add specs/10-budgets.md
git commit -m "specs/10: add budgets subsystem spec (hierarchical stock+rate, enforcement, notifier)"
```

---

### Task 3: Thread `01` — budget tree in the configuration layer

**Files:**
- Modify: `specs/01-state-model.md` — §3.2 "The configuration layer in detail" (lines 197-236).

**Interfaces:**
- Consumes: `BudgetTree` (`00` §7).

- [ ] **Step 1: Append the budget-allocation note to §3.2.** Add this paragraph at the end of §3.2:

```markdown
**Budget allocations (`10`).** The `BudgetTree` — the governed global→class→agent
cost-allocation hierarchy — is part of the configuration layer: allocations are
ordinary typed diffs, versioned and governed like any other config change. Their
*spend* counterpart is deliberately **not** here — measured consumption lives in the
runtime accounting ledger (`07`) and is never written to the Merkle log. This keeps
the desired(allocation)/actual(spend) split aligned with the rest of the model, so
metering never touches the write path.
```

- [ ] **Step 2: Verify.**

Run: `grep -n "BudgetTree\|Budget allocations" specs/01-state-model.md`
Expected: one hit in §3.2.

- [ ] **Step 3: Commit.**

```bash
git add specs/01-state-model.md
git commit -m "specs/01: place the budget tree in the configuration layer (allocation vs spend split)"
```

---

### Task 4: Thread `02` — budget reallocation as a tiered typed write

**Files:**
- Modify: `specs/02-consensus.md` — §9.4 "Routine / reversible writes — single-Guardian fast path" (starts line 641).

**Interfaces:**
- Consumes: `BudgetNode` (`00`); the ¾ constitutional threshold (`02` §9.2); the single-Guardian fast path (`02` §9.4).

- [ ] **Step 1: Append the reallocation-tiering note to §9.4.** Add this paragraph at the end of §9.4:

```markdown
**Budget reallocation (`10`).** Changing a `BudgetNode` is a typed diff tiered by
blast radius like any other write. **Routine per-agent / per-class top-ups within the
existing global pool** take this single-Guardian + post-hoc-audit fast path —
reversible, low blast radius. **Raising the global ceiling or changing kernel
(Guardian/Genesis) floors** is constitutional-adjacent: it takes the
reputation-weighted ¾ threshold (§9.2), because it enlarges the system's total
spending authority or touches the funding that keeps governance itself alive.
```

- [ ] **Step 2: Verify.**

Run: `grep -n "Budget reallocation" specs/02-consensus.md`
Expected: one hit in §9.4.

- [ ] **Step 3: Commit.**

```bash
git add specs/02-consensus.md
git commit -m "specs/02: tier budget reallocation (in-pool top-up fast path; ceiling/floor changes constitutional)"
```

---

### Task 5: Thread `03` — cost/rate relationship & sustained-throttle escalation

**Files:**
- Modify: `specs/03-control-loop.md` — §3.2 estimators (the `cost` estimator, ~line 133); §3.10 "Deferred until a measured oscillation demands them" (starts line 280); §5.3 or §2.1 persistently-stuck counter (counter defined ~line 74).

**Interfaces:**
- Consumes: the `cost` dimension (`03` §3.1/§3.2); the persistently-stuck counter (`03` §2.1); the deferred-terms section (`03` §3.10).

- [ ] **Step 1: Add the hard-cap relationship note after the `cost` estimator (§3.2).** Immediately after the `y_cost` estimator definition, add:

```markdown
**Relationship to hard budgets (`10`).** This `cost` dimension is the *soft*,
proportional signal layered **above** the hard stock caps of `10`. The caps are the
safety floor the controller aims never to reach; `cost` does the smooth day-to-day
steering (retire workers, prefer cheaper JIT tiers, narrow council). Hard-cap
**enforcement** — pausing a depleted agent or throttling a rate breach — is owned by
`10`, not by this controller.
```

- [ ] **Step 2: Add the deferred `burn_rate` dimension note to §3.10.** Append:

```markdown
**A `burn_rate` `ErrorVector` dimension (deferred).** `10` enforces per-node **rate**
caps via token buckets — the enforcement complement to the burn-rate spikes this loop
already reasons about (the motivation for the deferred derivative term). Promoting
aggregate burn-rate to a first-class controlled dimension is deferred alongside the
integral/derivative terms (OE-01), and adopted only if a measured need appears.
```

- [ ] **Step 3: Add the sustained-throttle escalation note where the persistently-stuck counter is described (§2.1, after the counter paragraph ~line 74).** Add:

```markdown
A **sustained** `10` rate breach is exactly this kind of persistent error: a transient
rate breach self-heals as the token bucket refills and does **not** escalate, but if
throttling persists the counter trips and surfaces an `EscalateToUser` — the signal
that a rate cap is mis-set or a runaway is sustained rather than spiky.
```

- [ ] **Step 4: Verify.**

Run: `grep -n "hard budgets\|burn_rate\|sustained\`\?.*rate breach\|Relationship to hard budgets" specs/03-control-loop.md`
Expected: three inserted notes (hard-budgets relationship, burn_rate deferral, sustained rate breach).

- [ ] **Step 5: Commit.**

```bash
git add specs/03-control-loop.md
git commit -m "specs/03: relate soft cost dim to hard budget caps; defer burn_rate dim; sustained-throttle escalation"
```

---

### Task 6: Thread `04` — enforcement mechanics & RD-4 extension

**Files:**
- Modify: `specs/04-runtime-and-harness.md` — §3.2 `TaskSpec` (the `budget` field, ~line 146); §4.3 "Agent lifecycle & supervision" (lines 330-364); §9 RD-4 "Cost & quota accounting" (~line 586).

**Interfaces:**
- Consumes: `BudgetNode` (`00`); the checkpoint/preempt optional capability (`04` §3.3); RD-4 hard-cancel path (`04` §9).

- [ ] **Step 1: Annotate `TaskSpec.budget` (§3.2).** Update the `budget` field comment so it binds to the tree. Change the line:

`    budget: Budget,             // wall-clock, token, and cost ceilings (best-effort enforced)`

to:

`    budget: Budget,             // binds to the agent's BudgetNode in the 10 tree; enforcement per 10`

- [ ] **Step 2: Add the depletion-enforcement paragraph to §4.3.** Append:

```markdown
**Budget depletion enforcement (`10`).** When an agent's `BudgetNode` crosses its
**stock** soft threshold (`cap − shutdown_reserve`), the execution plane runs the
layered stop of `10`: the agent drains to an atomic boundary (finishing an in-flight
tool call — never hard-cancelled mid-`mcp-auth-proxy` call), **checkpoints** if the
harness exposes the checkpoint/preempt capability (§3.3) or else **freezes** (safe:
committed progress lives in `01`, so it re-plans on resume like any restarted agent),
with the RD-4 **hard-cancel** as the bounded-grace backstop for non-cooperative or
runaway harnesses. A **rate** breach is instead **throttled** (dispatch delayed /
concurrency shed) and self-heals; only *sustained* throttling escalates (`03`).
```

- [ ] **Step 3: Extend RD-4 (§9).** Append to the RD-4 paragraph:

```markdown
Budgets are **hierarchical** (global→class→agent) and carry both a **stock** and a
**rate** allowance (`10`). Stock enforcement is no longer a bare hard-cancel: it is
soft-threshold → cooperative-drain → checkpoint-or-freeze → hard-cancel backstop.
Rate enforcement is **throttle**, falling back to hard-cancel only when a
non-cooperative harness sustains the breach.
```

- [ ] **Step 4: Verify.**

Run: `grep -n "BudgetNode\|Budget depletion enforcement\|hierarchical.*global→class→agent\|checkpoint-or-freeze" specs/04-runtime-and-harness.md`
Expected: the `TaskSpec` comment change, the §4.3 paragraph, and the RD-4 extension.

- [ ] **Step 5: Commit.**

```bash
git add specs/04-runtime-and-harness.md
git commit -m "specs/04: bind TaskSpec.budget to the tree; add depletion-enforcement mechanics; extend RD-4"
```

---

### Task 7: Thread `06` — user budget-setting, notifier, resume flow

**Files:**
- Modify: `specs/06-interaction-and-mailbox.md` — §2.5 "Escalations as a Mailbox boundary" (lines 136-146); §4.4 "External API surface" (starts line 435).

**Interfaces:**
- Consumes: `BudgetNotice` (`10` §4); the setpoint-override path (`03` §7.1); the mailbox/escalation model (`06` §2.5).

- [ ] **Step 1: Add the deterministic-notifier note to §2.5.** Append:

```markdown
**The deterministic budget notifier (`10`).** Budget-exhaustion escalations are
special: they are raised by an **off-budget, non-LLM reflex** that emits a
schema-validated `BudgetNotice` (a typed Mailbox item) computed entirely from the
`07` ledger. It is self-funding (draws from no budget node) and un-forgeable (a
drifting or compromised LLM cannot corrupt the message a funding decision rests on),
debounced by the same deadband/hysteresis the steering loop uses. If reserved-floor
budget remains, the Guardian LLM *additionally* enriches it — a guaranteed baseline
plus best-effort context. The blocked work waits under the usual bounded
escalation-timeout and then degrades safely; on top-up or reallocation it resumes.
```

- [ ] **Step 2: Add the budget-setting note to §4.4.** Append a paragraph documenting that users set/override budgets through the Interaction plane:

```markdown
**Setting budgets (`10`).** Through this surface a user sets or overrides the **stock**
and **rate** budgets of any node they are authorized for — the global ceiling and,
optionally, per-class / per-agent allocations. Budget setpoints follow the same
strict-priority resolution as other setpoints (`03` §7.1): explicit user override →
guardrailed learned refinement → safe default. Changes are enacted as tiered typed
proposals (`02` §9.4).
```

- [ ] **Step 3: Verify.**

Run: `grep -n "deterministic budget notifier\|BudgetNotice\|Setting budgets" specs/06-interaction-and-mailbox.md`
Expected: the §2.5 notifier note and the §4.4 budget-setting note.

- [ ] **Step 4: Commit.**

```bash
git add specs/06-interaction-and-mailbox.md
git commit -m "specs/06: add deterministic budget notifier + user budget-setting surface"
```

---

### Task 8: Thread `07` — accounting substrate & roll-up

**Files:**
- Modify: `specs/07-observability.md` — §3.2 "What every plane emits" (the Execution-plane metrics bullet, ~line 192); §3.4 "Data path to the steering-loop estimators" (lines 225-244); §4.6 "Consumer contracts" (starts line 459).

**Interfaces:**
- Consumes: existing `exec.tokens_total` / `exec.cost_units_total` metrics (`07` §3.2); the `BudgetLedger` (`10` §4).

- [ ] **Step 1: Add budget metrics to §3.2.** After the existing `exec.cost_units_total` metric, add:

```markdown
- **Budget metrics:** `budget.spend_units_total{scope}` (cumulative stock, rolled up
  agent→class→global — the **stock-enforcement** and **notifier** input);
  `budget.burn_rate{scope}` (gauge — the **rate-enforcement** input);
  `budget.utilization_ratio{node}` (spend ÷ cap — the deterministic `BudgetNotice`
  and the soft `cost` dimension both read this).
```

- [ ] **Step 2: Add the accounting-ledger note to §3.4.** Append:

```markdown
**The accounting ledger (`10`).** Observability owns the runtime `BudgetLedger`: it
debits each agent's measured spend and **rolls it up** to the agent's class node and
the global root, deterministically. This ledger is the substrate both the `10`
enforcement path and the off-budget deterministic notifier read. It is **runtime
state, not committed** to the Merkle log (mirroring the allocation/spend split of
`01`).
```

- [ ] **Step 3: Add the budget consumers to §4.6.** Add a consumer-contract entry noting the `10` enforcement path and notifier as named consumers of `budget.*` metrics and the ledger roll-up.

- [ ] **Step 4: Verify.**

Run: `grep -n "budget.spend_units_total\|budget.burn_rate\|accounting ledger\|BudgetLedger" specs/07-observability.md`
Expected: the metrics in §3.2, the ledger note in §3.4, the consumer entry in §4.6.

- [ ] **Step 5: Commit.**

```bash
git add specs/07-observability.md
git commit -m "specs/07: add budget accounting ledger, roll-up, and budget.* metrics"
```

---

### Task 9: Thread `08` — reallocation authority & notifier-determinism-as-trust

**Files:**
- Modify: `specs/08-trust-and-security.md` — §3.4 "Kernel protection" (lines 282-322); §4.1 "Threat model" (starts line 623).

**Interfaces:**
- Consumes: kernel-protection model (`08` §3.4); the ¾ constitutional threshold (`02` §9.2); `BudgetNotice` determinism (`10` §3.4).

- [ ] **Step 1: Add the budget-authority note to §3.4.** Append:

```markdown
**Budget authority (`10`).** Enlarging total spending authority (raising the global
ceiling) or changing kernel funding (Guardian/Genesis budget floors) is a protected,
constitutional-threshold change (`02` §9.2) — the funding that keeps governance itself
alive cannot be moved on a single Guardian's fast path.
```

- [ ] **Step 2: Add the notifier-determinism threat-model note to §4.1.** Append:

```markdown
**Un-forgeable budget notices (`10`).** The budget-exhaustion notice a user relies on
to make a funding/operational decision is emitted by a deterministic, off-budget
reflex from a schema-validated template computed from the `07` ledger — so a drifting
or compromised LLM cannot fabricate, suppress (it is self-funding), or corrupt it.
Determinism here is a trust property, not just an efficiency one.
```

- [ ] **Step 3: Verify.**

Run: `grep -n "Budget authority\|Un-forgeable budget notices" specs/08-trust-and-security.md`
Expected: the §3.4 authority note and the §4.1 threat-model note.

- [ ] **Step 4: Commit.**

```bash
git add specs/08-trust-and-security.md
git commit -m "specs/08: protect budget authority; record notifier determinism as a trust property"
```

---

### Task 10: `README` reading order, key decisions, and repo-wide consistency pass

**Files:**
- Modify: `specs/README.md` — reading-order table (lines 55-67); "Key design decisions" (lines 88-100); "The system at a glance" ASCII (lines 15-28, optional).

**Interfaces:**
- Consumes: everything from Tasks 1-9.

- [ ] **Step 1: Add the `10` row to the reading-order table (README).** After the `09` row:

```markdown
| **10** | [budgets](./10-budgets.md) | User-defined hierarchical (global→class→agent) stock + rate budgets; reserved-floor+shared-burst allocation; layered depletion enforcement; off-budget deterministic notifier | How the user bounds and scopes spend, and how agents pause/throttle when depleted |
```

- [ ] **Step 2: Add a budgets bullet to "Key design decisions" (README).** Append:

```markdown
- **Budgets** — user-defined budgets are **hierarchical** (global→class→agent) and carry both a **stock** (cumulative) and a **rate** (token-bucket) allowance, denominated in the normalized `CostUnit`. Allocation is **reserved-floor + shared-burst** so kernel governance stays funded under pressure while ephemeral workers run on shared burst; reallocation is a **tiered typed write** (in-pool top-ups fast-path, ceiling/floor changes constitutional). Depletion runs a **layered stop** (soft-threshold → cooperative drain → checkpoint/freeze → hard-cancel backstop; throttle for rate), announced by an **off-budget deterministic notifier** so telling the user "out of budget" never itself needs budget (`10`).
```

- [ ] **Step 3: Repo-wide cross-reference consistency pass.** Confirm every reference resolves and vocabulary is consistent.

Run: `grep -rn "\`10\`\|10-budgets" specs/*.md | wc -l`
Expected: ≥ 9 (each threaded spec + README + `00` diagram reference `10`).

Run: `for t in CostUnit BudgetNode StockBudget RateBudget shutdown_reserve burst_cap; do echo -n "$t: "; grep -rl "$t" specs/*.md | tr '\n' ' '; echo; done`
Expected: each type appears in `00` (definition) and at least `10` (usage); no spec redefines a `00` type (only `10` adds its own `BudgetLedger`/`NodeSpend`/`BudgetBreach`/`BudgetNotice`/`BudgetRemedy`).

Run: `grep -rniE "raw token budget|token budget of [0-9]|tokens-per-minute budget" specs/*.md`
Expected: no hits (budgets denominated in `CostUnit`, not raw tokens, in normative text).

Run: `grep -c "shutdown_reserve" specs/10-budgets.md specs/00-overview.md`
Expected: ≥1 in each (spelling consistent between definition and usage).

Fix any inconsistency found before committing (e.g., a type named `burst_cap` in `00` but `burstCap` in `10`).

- [ ] **Step 4: Commit.**

```bash
git add specs/README.md
git commit -m "specs/README: add 10-budgets to reading order and key design decisions"
```

---

## Self-Review

**1. Spec coverage** — every design-doc section maps to a task:
- §1 Purpose → Task 2.1. §2 Data model → Task 1 (canonical types) + Task 2.2/2.4. §3 Allocation → Task 2.2/2.3 + `01` config-layer placement Task 3. §4 Governance → Task 2.3 + `02` Task 4. §5 Enforcement → Task 2.3 + `04` Task 6. §6 Notifier → Task 2.3 + `06` Task 7 + `08` Task 9. §7 Steering relationship → Task 2.3 + `03` Task 5. §8 Threaded edits → Tasks 3-10 (one per spec). §9 Resolved decisions → Task 2.5. §10 Open questions → Task 2.6. §11 Relationships → Task 2.7. Accounting substrate → `07` Task 8. README/index → Task 10. **No gaps.**

**2. Placeholder scan** — no "TBD/TODO/implement later"; every insertion gives verbatim text; every code step shows the exact block; verification steps give exact commands + expected output. The one indirection (10-budgets.md prose "expand from design-doc §N") points at a committed external artifact that *is* the content source, not an unwritten task.

**3. Type consistency** — `00` defines `CostUnit`, `CostRate`, `BudgetTree`, `BudgetNodeId`, `BudgetNode`, `BudgetScope`, `StockBudget{floor,burst_cap,shutdown_reserve}`, `RateBudget{sustained,burst_depth}`. `10` defines only the runtime types (`BudgetLedger`, `NodeSpend`, `BudgetBreach`, `BudgetNotice`, `BudgetRemedy`) and reuses the `00` names verbatim. Task 10 Step 3 mechanically checks no consumer redefines or misspells a `00` type. Field names used in threaded edits (`shutdown_reserve`, `burst_cap`) match the `00` definitions. **Consistent.**
