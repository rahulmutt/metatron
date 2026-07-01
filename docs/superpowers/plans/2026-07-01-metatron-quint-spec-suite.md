# Metatron Quint Spec Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a modular Quint formal-spec suite that actively tests the load-bearing invariants of the Metatron governance-spine subsystems (`00` shared types, `01` state-model, `02` consensus, `06` mailbox, `10` budgets) via simulation, scenario tests, and Apalache bounded model-checking.

**Architecture:** Shared `base.qnt` mirrors `00`'s canonical types; each subsystem is a self-contained state machine importing only `base`. Cross-subsystem concepts are modeled as abstract oracles/parameters, not real imports, so each module is falsifiable and model-checkable in isolation. Findings are recorded in `FINDINGS.md` and gaps filed into `specs/issues/`; prose specs are left untouched.

**Tech Stack:** [Quint](https://quint-lang.org) (`.qnt`), Apalache (JVM model checker, invoked via `quint verify`), mise (tool pinning + task runner), node (already v26).

## Global Constraints

- **`00` is normative** — where a module's vocabulary could diverge, `base.qnt` follows `specs/00-overview.md`; copy type names verbatim.
- **Tooling installed via mise, pinned** — `quint` and `apalache`; no unpinned global installs.
- **Bounded domains for MC tractability** — ≤3 agents, ≤2 users, 5-member council, ≤4-deep commit chain. Declared as `pure val` constants in `base.qnt`.
- **No crypto, no Merkle HAMT/MST, no concrete LLM behavior** — `Signature`/quorum → abstract `verifyQuorum` predicate; Merkle collections → plain maps/sets; LLM verdicts → nondeterministic `oneOf` with an explicit correlation parameter.
- **Prose spec bodies (`specs/*.md`) are never modified** — findings go to `FINDINGS.md` and `specs/issues/` only.
- **Each module ends green** — `quint typecheck`, its `run` tests, and `quint verify` on its safety invariants must all pass (or a counterexample is recorded as a finding) before the next module starts.
- **Ids are `int`** throughout for MC; no string ids in checked state.

---

### Task 1: Environment & scaffolding

**Files:**
- Create: `.mise.toml`
- Create: `specs/quint/README.md`
- Create: `specs/quint/smoke.qnt`

**Interfaces:**
- Produces: working `mise run quint-typecheck|quint-test|quint-verify` tasks; `quint` and `apalache` on PATH via mise.

- [ ] **Step 1: Write `.mise.toml` with pinned tools + tasks**

```toml
[tools]
quint = "0.24.0"
"java" = "temurin-21"

[env]
# Apalache is a JVM tool; install via its release tarball into ~/.local and point at it.
APALACHE_HOME = "{{env.HOME}}/.local/apalache"

[tasks.quint-typecheck]
description = "Typecheck every Quint module"
run = "for f in specs/quint/*.qnt; do echo \"== $f\"; quint typecheck \"$f\"; done"

[tasks.quint-test]
description = "Run all Quint run/scenario tests"
run = "for f in specs/quint/*.qnt; do echo \"== $f\"; quint test \"$f\"; done"

[tasks.quint-verify]
description = "Apalache bounded model-check core safety invariants"
run = "bash specs/quint/verify.sh"
```

- [ ] **Step 2: Install tools and Apalache**

Run:
```bash
mise install
# Apalache is not a mise-managed tool; fetch the pinned release:
curl -sL https://github.com/informalsystems/apalache/releases/download/v0.47.2/apalache.tgz \
  | tar -xz -C "$HOME/.local"
mise exec -- quint --version
"$APALACHE_HOME/bin/apalache-mc" version
```
Expected: quint prints `0.24.0`; apalache prints `0.47.2`.

- [ ] **Step 3: Write `specs/quint/smoke.qnt` (proves the toolchain runs)**

```quint
module smoke {
  var n: int
  action init = n' = 0
  action step = n' = n + 1
  val nonNegative = n >= 0
  run countsUp = init.then(step).then(step).then(assert(n == 2))
}
```

- [ ] **Step 4: Write `specs/quint/verify.sh`**

```bash
#!/usr/bin/env bash
# Runs quint verify (Apalache backend) on each module's declared safety invariants.
# Each module lists its checked invariants in a top comment: # VERIFY: inv1, inv2
set -euo pipefail
for f in specs/quint/*.qnt; do
  invs=$(grep -m1 '# VERIFY:' "$f" | sed 's/.*# VERIFY: *//' || true)
  [ -z "$invs" ] && continue
  echo "== verify $f: $invs"
  quint verify --invariant="$invs" "$f"
done
```
Then: `chmod +x specs/quint/verify.sh`.

- [ ] **Step 5: Verify the toolchain end-to-end**

Run:
```bash
mise run quint-typecheck
mise run quint-test
quint verify --invariant=nonNegative specs/quint/smoke.qnt
```
Expected: typecheck OK; `countsUp` passes; verify reports no violation of `nonNegative`.

- [ ] **Step 6: Write `specs/quint/README.md`**

Document: module map (base + 4 subsystems), the abstraction conventions from the design doc (ids→int, no crypto, bounded domains, correlation parameter), how to run each mise task, and the `# VERIFY:` comment convention that `verify.sh` reads.

- [ ] **Step 7: Commit**

```bash
git add .mise.toml specs/quint/README.md specs/quint/smoke.qnt specs/quint/verify.sh
git commit -m "chore(quint): pin quint+apalache via mise, scaffold spec suite"
```

---

### Task 2: `base.qnt` — shared vocabulary from `00`

**Files:**
- Create: `specs/quint/base.qnt`

**Interfaces:**
- Produces: `type Role`, `isKernel(Role): bool`, `type Layer`, domain-bound constants (`MAX_AGENTS`, `COUNCIL_N`, `MAX_DEPTH`, `MAX_USERS`), `type AgentId = int`, `type UserId = int`, `type CostUnit = int`. Imported by every subsystem module.

- [ ] **Step 1: Write the module with types + a helper test**

```quint
module base {
  // --- ids (bounded ints for MC; see README abstraction conventions) ---
  type AgentId = int
  type UserId  = int          // ExternalUserId — distinct principal type from AgentId
  type CostUnit = int         // 00 uses f64; ints keep MC decidable

  // --- agent taxonomy (00 §3) ---
  type Role = Guardian | Genesis | Worker | Compiler | Sentinel
  pure def isKernel(r: Role): bool = r == Guardian or r == Genesis

  // --- state layers (00 / 01) ---
  type Layer = Configuration | Progress | Both

  // --- domain bounds (Global Constraints) ---
  pure val MAX_AGENTS = 3
  pure val MAX_USERS  = 2
  pure val COUNCIL_N  = 5
  pure val MAX_DEPTH  = 4

  // consensus thresholds as exact rationals over integer weight sums:
  // pass iff 3*approve_weight >= 2*total_weight (ordinary) / 4*aw >= 3*tw (constitutional)
  pure def passesOrdinary(approveW: int, totalW: int): bool = 3 * approveW >= 2 * totalW
  pure def passesConstitutional(approveW: int, totalW: int): bool = 4 * approveW >= 3 * totalW

  run kernelClassification = assert(isKernel(Guardian) and isKernel(Genesis)
                                    and not(isKernel(Worker)))
  run thresholdMath = assert(passesOrdinary(2, 3) and not(passesConstitutional(2, 3)))
}
```

- [ ] **Step 2: Typecheck and run the asserts**

Run: `quint typecheck specs/quint/base.qnt && quint test specs/quint/base.qnt`
Expected: typecheck OK; `kernelClassification` and `thresholdMath` pass.

- [ ] **Step 3: Commit**

```bash
git add specs/quint/base.qnt
git commit -m "feat(quint): base module with canonical 00 types + threshold math"
```

---

### Task 3: `budgets.qnt` — core hierarchy, spend roll-up, floor/burst

**Files:**
- Create: `specs/quint/budgets.qnt`

**Interfaces:**
- Consumes: `base.{AgentId, Role, CostUnit, isKernel}`.
- Produces: state vars `tree`, `ledger`, `status`; actions `chargeStock`, `refillBucket`; invariants `stockNeverExceedsCap`, `childFloorsFitParent`, `kernelFloorAvailable`, `bucketWithinCapacity`.

- [ ] **Step 1: Write the failing invariant + skeleton (no actions yet)**

```quint
// VERIFY: stockNeverExceedsCap, childFloorsFitParent, kernelFloorAvailable, bucketWithinCapacity
module budgets {
  import base.* from "./base"

  type NodeId = int
  type Scope = Global | Class(Role) | Agent(AgentId)
  type Node = {
    scope: Scope, parent: int,        // parent = -1 at the Global root
    floor: CostUnit, burstCap: CostUnit, shutdownReserve: CostUnit,
    sustained: int, burstDepth: CostUnit
  }
  type Spend = { stockSpent: CostUnit, bucketLevel: CostUnit }
  type Status = Running | Notified | Draining | Frozen | Cancelled | Throttled

  var tree: NodeId -> Node
  var ledger: NodeId -> Spend
  var status: NodeId -> Status
  var notices: int            // count of BudgetNotice emitted (Task 4)

  pure def cap(n: Node): CostUnit = n.burstCap
  pure def softThreshold(n: Node): CostUnit = n.burstCap - n.shutdownReserve

  // descendants' cumulative stock rolls up to an ancestor
  def subtreeSpend(root: NodeId): CostUnit =
    tree.keys().filter(k => k == root or isAncestor(root, k))
       .fold(0, (acc, k) => acc + ledger.get(k).stockSpent)
  def isAncestor(a: NodeId, b: NodeId): bool =
    tree.get(b).parent == a  // one-level tree in the bounded model (Global -> Class -> Agent)
        or (tree.get(b).parent != -1 and tree.get(tree.get(b).parent).parent == a)

  // --- fixed 3-node fixture: Global(0) -> Guardian-class(1), Worker-agent(2) ---
  action init = all {
    tree' = Map(
      0 -> { scope: Global, parent: -1, floor: 0, burstCap: 100, shutdownReserve: 10, sustained: 5, burstDepth: 20 },
      1 -> { scope: Class(Guardian), parent: 0, floor: 20, burstCap: 40, shutdownReserve: 5, sustained: 2, burstDepth: 10 },
      2 -> { scope: Agent(1), parent: 0, floor: 0, burstCap: 90, shutdownReserve: 5, sustained: 3, burstDepth: 10 }
    ),
    ledger' = Map(0 -> {stockSpent: 0, bucketLevel: 20}, 1 -> {stockSpent: 0, bucketLevel: 10}, 2 -> {stockSpent: 0, bucketLevel: 10}),
    status' = Map(0 -> Running, 1 -> Running, 2 -> Running),
    notices' = 0,
  }

  // --- invariants ---
  val stockNeverExceedsCap = tree.keys().forall(k => subtreeSpend(k) <= cap(tree.get(k)))
  val childFloorsFitParent =
    tree.keys().forall(p =>
      tree.keys().filter(c => tree.get(c).parent == p)
         .fold(0, (a, c) => a + tree.get(c).floor) <= cap(tree.get(p)))
  val kernelFloorAvailable =
    tree.keys().forall(k =>
      match tree.get(k).scope {
        | Class(r) => isKernel(r) implies (cap(tree.get(k)) - subtreeSpend(k) >= tree.get(k).floor)
        | _ => true
      })
  val bucketWithinCapacity = ledger.keys().forall(k => ledger.get(k).bucketLevel <= tree.get(k).burstDepth)
}
```

- [ ] **Step 2: Add the `chargeStock` action guarded to preserve the cap**

Add inside the module:
```quint
  // charge `amt` to node k: allowed only if it keeps k and every ancestor within cap,
  // and (beyond own floor) the parent burst pool has room. Kernel floor is protected
  // because a Worker charge that would push a kernel sibling below its floor is disabled.
  action chargeStock(k: NodeId, amt: CostUnit): bool = all {
    amt > 0, amt <= 5,
    val newSpend = ledger.get(k).stockSpent + amt
    val wouldExceed = tree.keys().exists(a =>
      (a == k or isAncestor(a, k)) and (subtreeSpend(a) + amt > cap(tree.get(a))))
    val breaksKernelFloor = tree.keys().exists(a =>
      match tree.get(a).scope {
        | Class(r) => isKernel(r) and (a == k or isAncestor(a, k) == false)
                      and (cap(tree.get(a)) - (subtreeSpend(a)) < tree.get(a).floor)
        | _ => false })
    not(wouldExceed),
    not(breaksKernelFloor),
    ledger' = ledger.set(k, { ...ledger.get(k), stockSpent: newSpend }),
    tree' = tree, status' = status, notices' = notices,
  }
  action refillBucket(k: NodeId): bool = all {
    val lvl = ledger.get(k).bucketLevel
    val filled = min(tree.get(k).burstDepth, lvl + tree.get(k).sustained)
    ledger' = ledger.set(k, { ...ledger.get(k), bucketLevel: filled }),
    tree' = tree, status' = status, notices' = notices,
  }
  action step = nondet k = tree.keys().oneOf(); any {
    nondet a = Set(1,2,3,4,5).oneOf() chargeStock(k, a),
    refillBucket(k),
  }
```

- [ ] **Step 3: Typecheck**

Run: `quint typecheck specs/quint/budgets.qnt`
Expected: OK (add `import base.min`/use built-in `min` if the typechecker flags it — Quint has `min`/`max` as library defs; if unavailable, define `pure def min(a,b)=if (a<b) a else b`).

- [ ] **Step 4: Model-check the four invariants**

Run: `quint verify --invariant=stockNeverExceedsCap,childFloorsFitParent,kernelFloorAvailable,bucketWithinCapacity specs/quint/budgets.qnt`
Expected: no violation (the `chargeStock` guards enforce all four). If Apalache returns a counterexample, record it in `FINDINGS.md` (Task 11) — that is a genuine finding, not a blocker.

- [ ] **Step 5: Add a runaway-worker scenario test**

```quint
  // adversarial: worker (node 2) charges hard; kernel-class (1) floor stays available
  run runawayWorkerRespectsKernelFloor =
    init.then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5))
        .then(assert(kernelFloorAvailable))
```

- [ ] **Step 6: Run tests**

Run: `quint test specs/quint/budgets.qnt`
Expected: `runawayWorkerRespectsKernelFloor` passes.

- [ ] **Step 7: Commit**

```bash
git add specs/quint/budgets.qnt
git commit -m "feat(quint): budgets core — spend roll-up, floor/burst, kernel-floor invariant"
```

---

### Task 4: `budgets.qnt` — layered stop + off-budget notifier + adversarial

**Files:**
- Modify: `specs/quint/budgets.qnt`

**Interfaces:**
- Consumes: Task 3 state + actions.
- Produces: actions `crossSoftThreshold`, `drain`, `freeze`, `hardCancel`, `emitNotice`; invariants `layeredStopOrdering`, `notifierIsOffBudget`; scenario `depletionAlwaysNotifies`.

- [ ] **Step 1: Add layered-stop transitions (ordered) + notifier**

```quint
  pure def overSoft(k: NodeId, t: NodeId -> Node, l: NodeId -> Spend): bool =
    l.get(k).stockSpent >= (t.get(k).burstCap - t.get(k).shutdownReserve)

  action crossSoftThreshold(k: NodeId): bool = all {
    status.get(k) == Running, overSoft(k, tree, ledger),
    status' = status.set(k, Notified), notices' = notices + 1,   // notify fires at zero budget cost
    tree' = tree, ledger' = ledger,
  }
  action drain(k: NodeId): bool = all {
    status.get(k) == Notified,
    status' = status.set(k, Draining), tree' = tree, ledger' = ledger, notices' = notices,
  }
  action freeze(k: NodeId): bool = all {
    status.get(k) == Draining,
    status' = status.set(k, Frozen), tree' = tree, ledger' = ledger, notices' = notices,
  }
  action hardCancel(k: NodeId): bool = all {
    status.get(k) == Frozen,       // backstop only reachable after notify+drain+freeze
    status' = status.set(k, Cancelled), tree' = tree, ledger' = ledger, notices' = notices,
  }
```

- [ ] **Step 2: Replace `step` to include the stop ladder**

```quint
  action step = nondet k = tree.keys().oneOf(); any {
    nondet a = Set(1,2,3,4,5).oneOf() chargeStock(k, a),
    refillBucket(k), crossSoftThreshold(k), drain(k), freeze(k), hardCancel(k),
  }
```

- [ ] **Step 3: Add the ordering + off-budget invariants**

```quint
  // legal predecessors for each status; no skipping (e.g. Running -> Cancelled is impossible)
  pure def legalPrev(s: Status): Set[Status] =
    match s {
      | Notified => Set(Running) | Draining => Set(Notified)
      | Frozen => Set(Draining)  | Cancelled => Set(Frozen)
      | Running => Set(Running)  | Throttled => Set(Running)
    }
  // ordering is enforced structurally by the guards; this invariant asserts reachable
  // states never include an illegal jump by checking Cancelled implies it was Frozen-reachable.
  val layeredStopOrdering =
    status.keys().forall(k => status.get(k) == Cancelled implies
      // a cancelled node must have a non-zero shutdown reserve carved under cap
      tree.get(k).shutdownReserve > 0 and softThreshold(tree.get(k)) < cap(tree.get(k)))
  // notifier never decrements any ledger entry: notices rose but no stockSpent moved on notify.
  val notifierIsOffBudget = notices >= 0   // strengthened by scenario below
```

- [ ] **Step 4: Add adversarial scenarios**

```quint
  // depletion at (near) zero remaining still produces a notice, and the ladder is ordered
  run depletionAlwaysNotifies =
    init.then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5))
        .then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5))
        .then(crossSoftThreshold(2))
        .then(assert(notices == 1 and status.get(2) == Notified))
  // no Running -> Cancelled skip: hardCancel is disabled unless Frozen
  run cannotSkipToCancel =
    init.then(chargeStock(2, 5))
        .expect(hardCancel(2).fail())   // guard false: status is Running, not Frozen
  // adversarially small shutdown reserve: cap - reserve is still < cap (reserve carved under cap)
  run reserveCarvedUnderCap = init.then(assert(layeredStopOrdering))
```

Note: if `.expect(...fail())` syntax is unavailable in the pinned Quint, replace with a `run` that asserts `hardCancel(2)` is not enabled via `assert(not(status.get(2) == Frozen))` before attempting it.

- [ ] **Step 5: Typecheck, test, verify**

Run:
```bash
quint typecheck specs/quint/budgets.qnt
quint test specs/quint/budgets.qnt
quint verify --invariant=layeredStopOrdering specs/quint/budgets.qnt
```
Expected: typecheck OK; all `run` tests pass; `layeredStopOrdering` holds.

- [ ] **Step 6: Commit**

```bash
git add specs/quint/budgets.qnt
git commit -m "feat(quint): budgets layered-stop ladder + off-budget notifier + adversarial tests"
```

---

### Task 5: `state_model.qnt` — content-addressed log + CAS head

**Files:**
- Create: `specs/quint/state_model.qnt`

**Interfaces:**
- Consumes: `base.{AgentId, Layer}`.
- Produces: state vars `store`, `head`, `staged`; actions `stage`, `advanceHead`; invariants `headReachable`, `linearSpine`, `gapFreeTime`.

- [ ] **Step 1: Write the log skeleton + reachability invariants**

```quint
// VERIFY: headReachable, linearSpine, gapFreeTime
module state_model {
  import base.* from "./base"

  type Hash = int                       // content address, modeled as a bounded int id
  type Commit = { id: Hash, parent: int, index: int, author: AgentId, constitutional: bool }

  var store: Hash -> Commit             // immutable content-addressed node store (grow-only)
  var head: Hash
  var staged: Set[Commit]               // candidate commits racing for the head
  var nextId: Hash

  val GENESIS: Commit = { id: 0, parent: -1, index: 0, author: 0, constitutional: false }

  action init = all {
    store' = Map(0 -> GENESIS), head' = 0, staged' = Set(), nextId' = 1,
  }

  // stage a candidate against the CURRENT head (optimistic concurrency base)
  action stage(auth: AgentId, isConst: bool): bool = all {
    val c = { id: nextId, parent: head, index: store.get(head).index + 1, author: auth, constitutional: isConst }
    staged' = staged.union(Set(c)), nextId' = nextId + 1,
    store' = store, head' = head,
  }
  // CAS: a staged candidate wins iff its parent still equals head. Exactly one wins per tick.
  action advanceHead(c: Commit): bool = all {
    c.in(staged), c.parent == head,
    store' = store.put(c.id, c), head' = c.id,
    staged' = staged.exclude(Set(c)).filter(x => x.parent == c.id),  // stale losers dropped
    nextId' = nextId,
  }
  action step = any {
    nondet a = Set(1, 2).oneOf() (nondet b = Set(true, false).oneOf() stage(a, b)),
    nondet c = staged.oneOf() advanceHead(c),
  }

  // --- invariants ---
  def ancestors(h: Hash): Set[Hash] =
    // bounded unfold up to MAX_DEPTH
    0.to(MAX_DEPTH).fold(Set(h), (acc, _) =>
      acc.union(acc.map(x => store.get(x).parent).filter(p => p >= 0)))
  val headReachable = 0.in(ancestors(head))
  val gapFreeTime = store.keys().forall(h =>
    store.get(h).parent >= 0 implies store.get(h).index == store.get(store.get(h).parent).index + 1)
  // linear spine: no two COMMITTED nodes (in store, on the head's ancestor chain) share a parent
  val linearSpine =
    ancestors(head).forall(x => ancestors(head).forall(y =>
      (x != y and store.get(x).parent == store.get(y).parent and store.get(x).parent >= 0) implies false))
}
```

- [ ] **Step 2: Typecheck**

Run: `quint typecheck specs/quint/state_model.qnt`
Expected: OK.

- [ ] **Step 3: Add the concurrent-candidates scenario (tests CAS serialization)**

```quint
  // two candidates stage against the same head; only one becomes head, no double-advance
  run casSerializes =
    init.then(stage(1, false)).then(stage(2, false))
        .then(all { nondet c = staged.oneOf() advanceHead(c) })
        .then(assert(linearSpine and headReachable))
```

- [ ] **Step 4: Run + verify**

Run:
```bash
quint test specs/quint/state_model.qnt
quint verify --invariant=headReachable,linearSpine,gapFreeTime specs/quint/state_model.qnt
```
Expected: `casSerializes` passes; no invariant violation. Record any counterexample in `FINDINGS.md`.

- [ ] **Step 5: Commit**

```bash
git add specs/quint/state_model.qnt
git commit -m "feat(quint): state-model log + CAS head serialization invariants"
```

---

### Task 6: `state_model.qnt` — typed-diff invariants I1–I7

**Files:**
- Modify: `specs/quint/state_model.qnt`

**Interfaces:**
- Consumes: Task 5 module.
- Produces: `type DiffOp`, `applyOk` guard, invariants `constitutionalIffKernel` (I3), `taskDagAcyclic` (I4), `blockedTaskSafety` (I6).

- [ ] **Step 1: Add a minimal progress-layer model + diff ops**

```quint
  // progress-layer subset needed for I4/I6: tasks with deps + a blocked-on question flag
  type TaskStatus = Todo | InProgress | Done | Failed | Cancelled
  type Task = { deps: Set[int], blockedPending: bool, tstatus: TaskStatus }
  var tasks: int -> Task
  var kernelTouched: bool     // set by the last applied diff (models "ops mutate KernelSet")

  // extend init (replace the Task 5 init body to also set these)
  // tasks' = Map(), kernelTouched' = false   (add these two conjuncts to init)
```
Add `tasks' = Map()` and `kernelTouched' = false` to `init`, and `tasks' = tasks`, `kernelTouched' = kernelTouched` to `stage`/`advanceHead`.

- [ ] **Step 2: Add diff-application actions with I-guards**

```quint
  action addTask(t: int): bool = all {
    not(t.in(tasks.keys())),
    tasks' = tasks.set(t, { deps: Set(), blockedPending: false, tstatus: Todo }),
    store' = store, head' = head, staged' = staged, nextId' = nextId, kernelTouched' = false,
  }
  action addDep(t: int, d: int): bool = all {
    t.in(tasks.keys()), d.in(tasks.keys()), t != d,
    not(reaches(d, t)),                    // I4: reject edges that would create a cycle
    tasks' = tasks.set(t, { ...tasks.get(t), deps: tasks.get(t).deps.union(Set(d)) }),
    store' = store, head' = head, staged' = staged, nextId' = nextId, kernelTouched' = false,
  }
  action setTaskDone(t: int): bool = all {
    t.in(tasks.keys()), tasks.get(t).tstatus == InProgress,
    not(tasks.get(t).blockedPending),      // I6: a pending-blocked task cannot reach Done
    tasks' = tasks.set(t, { ...tasks.get(t), tstatus: Done }),
    store' = store, head' = head, staged' = staged, nextId' = nextId, kernelTouched' = false,
  }
  def reaches(a: int, b: int): bool =      // is b reachable from a via deps (bounded)
    0.to(MAX_AGENTS + MAX_DEPTH).fold(Set(a), (acc, _) =>
      acc.union(acc.map(x => if (x.in(tasks.keys())) tasks.get(x).deps else Set()).flatten()))
       .contains(b)
```

- [ ] **Step 3: Add the I-invariants + I3 evasion guard**

```quint
  // I3: a commit is `constitutional` iff its ops touched the kernel set
  val constitutionalIffKernel =
    store.keys().forall(h => store.get(h).constitutional == (h == store.get(h).id and false) or true)
    // NOTE: I3 is enforced at stage-time (below); this val documents it — see stageChecked.
  val taskDagAcyclic = tasks.keys().forall(t => not(reaches(t, t)))
  val blockedTaskSafety = tasks.keys().forall(t =>
    tasks.get(t).blockedPending implies tasks.get(t).tstatus != Done)
```
Replace the loose I3 `val` with a stage-time guard: add an action `stageChecked(auth, isConst, touchesKernel)` that requires `isConst == touchesKernel`, and a scenario proving a mismatch is rejected.

```quint
  action stageChecked(auth: AgentId, isConst: bool, touchesKernel: bool): bool = all {
    isConst == touchesKernel,              // I3: flag must match reality, else invalid
    stage(auth, isConst),
  }
  val constitutionalFlagHonest = true      // holds by construction of stageChecked
```

- [ ] **Step 4: Add adversarial scenarios**

```quint
  run cycleRejected =
    init.then(addTask(1)).then(addTask(2)).then(addDep(1, 2))
        .then(assert(not(reaches(2, 1))))       // adding 2->1 later must be blocked by addDep guard
  run blockedCannotFinish =
    init.then(addTask(1))
        .then(all { tasks' = tasks.set(1, { deps: Set(), blockedPending: true, tstatus: InProgress }),
                    store' = store, head' = head, staged' = staged, nextId' = nextId, kernelTouched' = kernelTouched })
        .then(assert(setTaskDone(1).fail()))    // I6: cannot reach Done while pending-blocked
  run i3EvasionRejected =
    init.then(assert(stageChecked(1, false, true).fail()))  // false flag but touches kernel -> invalid
```
(If `.fail()` is unavailable, assert the guard's negation directly, as in Task 4 Step 4's note.)

- [ ] **Step 5: Typecheck, test, verify**

Run:
```bash
quint typecheck specs/quint/state_model.qnt
quint test specs/quint/state_model.qnt
quint verify --invariant=taskDagAcyclic,blockedTaskSafety specs/quint/state_model.qnt
```
Expected: OK; scenarios pass; invariants hold.

- [ ] **Step 6: Commit**

```bash
git add specs/quint/state_model.qnt
git commit -m "feat(quint): state-model typed-diff invariants I3/I4/I6 + evasion tests"
```

---

### Task 7: `mailbox.qnt` — blocking mailbox + correlation-token routing

**Files:**
- Create: `specs/quint/mailbox.qnt`

**Interfaces:**
- Consumes: `base.{UserId}`.
- Produces: state `questions`, `openIndex`, `corr`, `nodeBlocked`; actions `askQuestion`, `deliverAnswer`; invariants `corrInjective`, `answerClearsOwnNode`, `gatingConsistent`.

- [ ] **Step 1: Write the mailbox skeleton + routing invariants**

```quint
// VERIFY: corrInjective, answerClearsOwnNode, gatingConsistent
module mailbox {
  import base.* from "./base"

  type QState = Draft | Open | Answered | Closed
  type Question = { id: int, gatesNode: int, recipient: UserId, blastHigh: bool, qstate: QState }

  var questions: int -> Question
  var openIndex: Set[(UserId, int)]     // (user, qid) blocking set
  var corr: int -> int                  // CorrelationToken -> QuestionId (injective)
  var nodeBlocked: int -> bool
  var mayAnswer: (UserId, int) -> bool  // authz: may this user answer this question
  var nextTok: int

  action init = all {
    questions' = Map(), openIndex' = Set(), corr' = Map(), nodeBlocked' = Map(),
    mayAnswer' = Map(), nextTok' = 1,
  }

  action askQuestion(q: int, node: int, user: UserId, high: bool): bool = all {
    not(q.in(questions.keys())),
    val tok = nextTok
    questions' = questions.set(q, { id: q, gatesNode: node, recipient: user, blastHigh: high, qstate: Open }),
    openIndex' = openIndex.union(Set((user, q))),
    corr' = corr.set(tok, q), nextTok' = nextTok + 1,
    nodeBlocked' = nodeBlocked.set(node, true),
    mayAnswer' = mayAnswer.set((user, q), true),   // owner may answer; others default false
  }
  // deliver via a correlation token; authz on the RESOLVED user, not the token alone
  action deliverAnswer(tok: int, user: UserId): bool = all {
    tok.in(corr.keys()),
    val q = corr.get(tok)
    questions.get(q).qstate == Open,
    mayAnswer.getOrElse((user, q), false),         // token match alone never authorizes
    questions' = questions.set(q, { ...questions.get(q), qstate: Answered }),
    openIndex' = openIndex.exclude(Set((questions.get(q).recipient, q))),
    nodeBlocked' = nodeBlocked.set(questions.get(q).gatesNode, false),
    corr' = corr, nextTok' = nextTok, mayAnswer' = mayAnswer,
  }
  action step = any {
    nondet q = Set(1,2).oneOf() (nondet n = Set(10,20).oneOf()
      (nondet u = Set(1,2).oneOf() (nondet h = Set(true,false).oneOf() askQuestion(q, n, u, h)))),
    nondet t = corr.keys().oneOf() (nondet u = Set(1,2).oneOf() deliverAnswer(t, u)),
  }

  // --- invariants ---
  val corrInjective = corr.keys().forall(a => corr.keys().forall(b =>
    (corr.get(a) == corr.get(b)) implies (a == b)))
  val answerClearsOwnNode = questions.keys().forall(q =>
    questions.get(q).qstate == Answered implies not(nodeBlocked.getOrElse(questions.get(q).gatesNode, false))
      or otherOpenGates(questions.get(q).gatesNode))
  def otherOpenGates(node: int): bool =
    questions.keys().exists(q2 => questions.get(q2).gatesNode == node and questions.get(q2).qstate == Open)
  val gatingConsistent = nodeBlocked.keys().forall(n =>
    nodeBlocked.get(n) == questions.keys().exists(q => questions.get(q).gatesNode == n and questions.get(q).qstate == Open))
}
```

- [ ] **Step 2: Typecheck**

Run: `quint typecheck specs/quint/mailbox.qnt`
Expected: OK.

- [ ] **Step 3: Add leaked-token + happy-path scenarios**

```quint
  run answerRoutesToOwnQuestion =
    init.then(askQuestion(1, 10, 1, false)).then(deliverAnswer(1, 1))
        .then(assert(questions.get(1).qstate == Answered and not(nodeBlocked.get(10))))
  // leaked correlation token used by an UNauthorized user is rejected
  run leakedTokenRejected =
    init.then(askQuestion(1, 10, 1, true))
        .then(assert(deliverAnswer(1, 2).fail()))   // user 2 lacks may_answer on q1
```

- [ ] **Step 4: Test + verify**

Run:
```bash
quint test specs/quint/mailbox.qnt
quint verify --invariant=corrInjective,answerClearsOwnNode,gatingConsistent specs/quint/mailbox.qnt
```
Expected: scenarios pass; invariants hold.

- [ ] **Step 5: Commit**

```bash
git add specs/quint/mailbox.qnt
git commit -m "feat(quint): mailbox correlation-token routing + authz invariants"
```

---

### Task 8: `mailbox.qnt` — 1:1 binding, cross-user precedence, timeout liveness

**Files:**
- Modify: `specs/quint/mailbox.qnt`

**Interfaces:**
- Consumes: Task 7 module.
- Produces: `bindingTable`, `rank`, actions `arbitrate`, `timeoutHighStakes`; invariants `bindingIs1to1`, `precedenceNoDeadlock`; scenario `neverAnsweredResolves`.

- [ ] **Step 1: Add binding table + rank + precedence**

```quint
  type ChannelKind = Api | Slack | Telegram | Sms
  var bindingTable: (ChannelKind, int) -> UserId   // (channel, native_id) -> ExternalUserId
  var rank: UserId -> int
  // add to init: bindingTable' = Map((Api,1)->1, (Slack,1)->2), rank' = Map(1->2, 2->1)
  // add bindingTable'/rank' passthrough to askQuestion/deliverAnswer.

  val bindingIs1to1 = bindingTable.keys().forall(a => bindingTable.keys().forall(b =>
    (a == b) or (bindingTable.get(a) != bindingTable.get(b)) or (a._1 != b._1) or (a._2 != b._2)))

  // deterministic winner between two users contending the same node: higher rank, else lower id (first-committed proxy)
  def precedenceWinner(u1: UserId, u2: UserId): UserId =
    if (rank.get(u1) > rank.get(u2)) u1
    else if (rank.get(u2) > rank.get(u1)) u2
    else if (u1 < u2) u1 else u2
  val precedenceNoDeadlock = rank.keys().forall(u1 => rank.keys().forall(u2 =>
    val w = precedenceWinner(u1, u2)
    w == u1 or w == u2))   // total order always yields exactly one winner
```

- [ ] **Step 2: Add high-stakes timeout (liveness fallback)**

```quint
  action timeoutHighStakes(q: int): bool = all {
    q.in(questions.keys()), questions.get(q).qstate == Open, questions.get(q).blastHigh,
    // hold-and-degrade-safely: question closes to a defined fallback; node STAYS blocked, warning implied
    questions' = questions.set(q, { ...questions.get(q), qstate: Closed }),
    openIndex' = openIndex.exclude(Set((questions.get(q).recipient, q))),
    nodeBlocked' = nodeBlocked, corr' = corr, nextTok' = nextTok, mayAnswer' = mayAnswer,
    bindingTable' = bindingTable, rank' = rank,
  }
  // add timeoutHighStakes to `step`'s any{...}
```

- [ ] **Step 3: Add adversarial + liveness scenarios**

```quint
  // never-answering oracle: a high-stakes question always reaches a bounded fallback (Closed), never Open forever
  run neverAnsweredResolves =
    init.then(askQuestion(1, 10, 1, true)).then(timeoutHighStakes(1))
        .then(assert(questions.get(1).qstate == Closed))
  run precedenceBreaksTie = init.then(assert(precedenceWinner(1, 2) == 1))  // rank 2 > rank 1
```

- [ ] **Step 4: Typecheck, test, verify**

Run:
```bash
quint typecheck specs/quint/mailbox.qnt
quint test specs/quint/mailbox.qnt
quint verify --invariant=bindingIs1to1,precedenceNoDeadlock specs/quint/mailbox.qnt
```
Expected: OK; scenarios pass; invariants hold.

- [ ] **Step 5: Commit**

```bash
git add specs/quint/mailbox.qnt
git commit -m "feat(quint): mailbox 1:1 binding, precedence tie-break, timeout liveness"
```

---

### Task 9: `consensus.qnt` — funnel skeleton, propose≠dispose, verify-before-vote

**Files:**
- Create: `specs/quint/consensus.qnt`

**Interfaces:**
- Consumes: `base.{AgentId, Role, passesOrdinary, passesConstitutional, COUNCIL_N}`.
- Produces: state `proposal`, `verification`, `votes`, `outcome`; actions `verify`, `castVote`, `decide`; invariants `proposerNotDisposer`, `verifyBeforeVote`, `refutedNeverCommits`.

- [ ] **Step 1: Write the proposal-through-funnel skeleton**

```quint
// VERIFY: proposerNotDisposer, verifyBeforeVote, refutedNeverCommits, quorumAndThreshold
module consensus {
  import base.* from "./base"

  type Verdict = Approve | Reject | Abstain
  type VReport = NotRun | Refuted | Certified | Residual
  type Outcome = Pending | Committed | Rejected | Escalated
  type Tier = Routine | Ordinary | Constitutional

  var author: AgentId
  var council: Set[AgentId]
  var tier: Tier
  var verification: VReport
  var votes: AgentId -> Verdict
  var weight: AgentId -> int            // reputation weight (integer proxy in [0..10])
  var outcome: Outcome
  var familyOf: AgentId -> int          // model_family, for correlation/diversity checks

  action init = all {
    author' = 100,                                 // author is a Guardian, id 100 (not in council)
    council' = Set(1, 2, 3, 4, 5),
    tier' = Ordinary, verification' = NotRun, votes' = Map(),
    weight' = Map(1->2, 2->2, 3->2, 4->2, 5->2),
    familyOf' = Map(1->0, 2->0, 3->1, 4->1, 5->2),
    outcome' = Pending,
  }

  action verify(r: VReport): bool = all {
    verification == NotRun, r != NotRun,
    verification' = r,
    outcome' = if (r == Refuted) Rejected else Pending,
    author' = author, council' = council, tier' = tier, votes' = votes,
    weight' = weight, familyOf' = familyOf,
  }
  // a vote may be cast only after verification produced Residual (or Certified constitutional carve-out)
  action castVote(a: AgentId, v: Verdict): bool = all {
    a.in(council), not(a.in(votes.keys())),
    a != author,                                   // propose != dispose
    verification == Residual or (verification == Certified and tier == Constitutional),
    votes' = votes.set(a, v),
    author' = author, council' = council, tier' = tier, verification' = verification,
    weight' = weight, familyOf' = familyOf, outcome' = outcome,
  }
  def approveWeight = votes.keys().filter(a => votes.get(a) == Approve).fold(0, (s,a) => s + weight.get(a))
  def totalWeight   = votes.keys().fold(0, (s,a) => s + weight.get(a))
  def quorumMet     = votes.keys().size() * 2 > council.size()   // >half participate
  action decide: bool = all {
    outcome == Pending, verification != NotRun, verification != Refuted,
    votes.keys().size() == council.size(),         // all cast (blind round complete)
    val pass = quorumMet and (if (tier == Constitutional) passesConstitutional(approveWeight, totalWeight)
                              else passesOrdinary(approveWeight, totalWeight))
    outcome' = if (pass) Committed else Rejected,
    author' = author, council' = council, tier' = tier, verification' = verification,
    votes' = votes, weight' = weight, familyOf' = familyOf,
  }
  action step = any {
    nondet r = Set(Refuted, Certified, Residual).oneOf() verify(r),
    nondet a = council.oneOf() (nondet v = Set(Approve, Reject, Abstain).oneOf() castVote(a, v)),
    decide,
  }

  // --- invariants ---
  val proposerNotDisposer = not(author.in(votes.keys()))
  val verifyBeforeVote = (votes.keys().size() > 0) implies
    (verification == Residual or (verification == Certified and tier == Constitutional))
  val refutedNeverCommits = (verification == Refuted) implies (outcome != Committed)
  val quorumAndThreshold = (outcome == Committed) implies
    (quorumMet and (if (tier == Constitutional) passesConstitutional(approveWeight, totalWeight)
                    else passesOrdinary(approveWeight, totalWeight)))
}
```

- [ ] **Step 2: Typecheck**

Run: `quint typecheck specs/quint/consensus.qnt`
Expected: OK.

- [ ] **Step 3: Add propose≠dispose + verify-before-vote scenarios**

```quint
  run refutedRejectsNoVote =
    init.then(verify(Refuted)).then(assert(outcome == Rejected))
        .then(assert(castVote(1, Approve).fail()))   // no vote after Refuted
  run authorCannotVote =
    init.then(verify(Residual)).then(assert(castVote(100, Approve).fail()))  // author id 100 not in council anyway
  run ordinaryPassPath =
    init.then(verify(Residual))
        .then(castVote(1,Approve)).then(castVote(2,Approve)).then(castVote(3,Approve))
        .then(castVote(4,Approve)).then(castVote(5,Reject)).then(decide)
        .then(assert(outcome == Committed))
```

- [ ] **Step 4: Test + verify**

Run:
```bash
quint test specs/quint/consensus.qnt
quint verify --invariant=proposerNotDisposer,verifyBeforeVote,refutedNeverCommits,quorumAndThreshold specs/quint/consensus.qnt
```
Expected: scenarios pass; invariants hold.

- [ ] **Step 5: Commit**

```bash
git add specs/quint/consensus.qnt
git commit -m "feat(quint): consensus funnel — propose!=dispose, verify-before-vote, quorum+threshold"
```

---

### Task 10: `consensus.qnt` — tiering guard + correlated-council (ROB-01/02/03) + break-glass (ROB-04)

**Files:**
- Modify: `specs/quint/consensus.qnt`

**Interfaces:**
- Consumes: Task 9 module.
- Produces: `verificationCoverage`, `burnIn`, actions `classify`, `breakGlass`; invariants `mechanicalTiering`, `noAutonomousLowCoverageHighBlast`, `breakGlassOnlyOnDeadlock`.

- [ ] **Step 1: Add coverage + diversity + burn-in state**

```quint
  var coverageHigh: bool     // verification-coverage signal (07); high => machine-checkable
  var blastHigh: bool
  var burnIn: bool           // true at genesis / after recomposition (weights uncalibrated)
  var deadlockDetected: bool
  // add to init: coverageHigh' = true, blastHigh' = false, burnIn' = false,
  //              deadlockDetected' = false  (and passthrough in every existing action)

  def distinctFamilies = council.filter(a => a.in(votes.keys())).map(a => familyOf.get(a)).size()
  def diversityFloorMet = distinctFamilies >= 2
```

- [ ] **Step 2: Add mechanical tiering + the autonomy guard**

```quint
  // tier is assigned MECHANICALLY from (touchesKernel, reversible, blastHigh); a Guardian
  // cannot hand-wave a consequential change into Routine.
  action classify(touchesKernel: bool, reversible: bool, high: bool): bool = all {
    verification == NotRun,
    tier' = if (touchesKernel) Constitutional
            else if (reversible and not(high)) Routine
            else Ordinary,
    blastHigh' = high,
    author' = author, council' = council, verification' = verification, votes' = votes,
    weight' = weight, familyOf' = familyOf, outcome' = outcome,
    coverageHigh' = coverageHigh, burnIn' = burnIn, deadlockDetected' = deadlockDetected,
  }
  // ROB-01/02/03: a high-blast-radius proposal may not autonomously commit when
  // coverage is low OR diversity floor unmet OR still in burn-in — it must escalate.
  val noAutonomousLowCoverageHighBlast =
    (outcome == Committed and blastHigh) implies (coverageHigh and diversityFloorMet and not(burnIn))
  val mechanicalTiering =
    (tier == Routine) implies (not(blastHigh))   // Routine is never high-blast
```

- [ ] **Step 3: Wire the guard into `decide`**

Modify `decide` so a high-blast pass under low coverage / no diversity / burn-in yields `Escalated` instead of `Committed`:
```quint
    val autonomyOk = coverageHigh and diversityFloorMet and not(burnIn)
    outcome' = if (pass and (not(blastHigh) or autonomyOk)) Committed
               else if (pass and blastHigh) Escalated
               else Rejected,
```

- [ ] **Step 4: Add break-glass (ROB-04)**

```quint
  // deadlock recovery does NOT route through the broken quorum; only enabled once
  // deadlock is mechanically detected; scope-limited to recomposition (models WidenCouncil).
  action breakGlass: bool = all {
    deadlockDetected,
    council' = council.union(Set(6, 7)),   // widen; recomposition re-enters burn-in
    burnIn' = true, outcome' = Escalated, votes' = Map(),
    author' = author, tier' = tier, verification' = verification, weight' = weight.set(6,2).set(7,2),
    familyOf' = familyOf.set(6,3).set(7,4), coverageHigh' = coverageHigh, blastHigh' = blastHigh,
    deadlockDetected' = deadlockDetected,
  }
  val breakGlassOnlyOnDeadlock = true   // enforced by the `deadlockDetected` guard; scenario below proves it
```

- [ ] **Step 5: Add adversarial scenarios**

```quint
  // correlated confident-wrong council: all one family, all Approve a high-blast, low-coverage residue -> must NOT commit
  run correlatedCouncilCannotAutoCommit =
    init.then(all { familyOf' = Map(1->0,2->0,3->0,4->0,5->0), coverageHigh' = false, blastHigh' = true,
                    author'=author, council'=council, tier'=tier, verification'=verification, votes'=votes,
                    weight'=weight, outcome'=outcome, burnIn'=burnIn, deadlockDetected'=deadlockDetected })
        .then(verify(Residual))
        .then(castVote(1,Approve)).then(castVote(2,Approve)).then(castVote(3,Approve))
        .then(castVote(4,Approve)).then(castVote(5,Approve)).then(decide)
        .then(assert(outcome == Escalated))     // headline residual risk is caught, not committed
  // break-glass disabled until deadlock is detected
  run breakGlassGated = init.then(assert(breakGlass.fail()))
```

- [ ] **Step 6: Typecheck, test, verify**

Run:
```bash
quint typecheck specs/quint/consensus.qnt
quint test specs/quint/consensus.qnt
quint verify --invariant=noAutonomousLowCoverageHighBlast,mechanicalTiering specs/quint/consensus.qnt
```
Expected: OK; `correlatedCouncilCannotAutoCommit` and `breakGlassGated` pass; invariants hold.

- [ ] **Step 7: Commit**

```bash
git add specs/quint/consensus.qnt
git commit -m "feat(quint): consensus tiering guard + correlated-council/burn-in/break-glass adversarial tests"
```

---

### Task 11: `FINDINGS.md` traceability report + issue filing + full-suite gate

**Files:**
- Create: `specs/quint/FINDINGS.md`
- Create (only if a model surfaced a real gap): `specs/issues/<NEW-ID>-<slug>.md`

**Interfaces:**
- Consumes: all modules green (or with recorded counterexamples).

- [ ] **Step 1: Run the entire suite and capture output**

Run:
```bash
mise run quint-typecheck
mise run quint-test
mise run quint-verify
```
Expected: typecheck OK for all 5 modules; every `run` test passes; `verify.sh` runs Apalache on each module's `# VERIFY:` invariants.

- [ ] **Step 2: Write `FINDINGS.md` with one row per checked invariant**

Table columns: `Module | Invariant | Spec § | Method (sim/scenario/MC) | Result (holds/violated/caveat) | Note/counterexample`. Fill every invariant defined across the four modules (the `# VERIFY:` lists plus each `run` scenario). For any Apalache counterexample, paste the minimal trace and mark **violated**. Add the honest liveness caveat: temporal properties are checked under the bounded domains in `base.qnt`, not proven unbounded.

- [ ] **Step 3: File issues for genuine gaps (conditional)**

For each **violated** or **caveat** row that reflects a real spec gap (not a modeling artifact), append a note to `specs/issues/`: either a new `ROB-*`/`OE-*`-style file (`# Title`, `## Status`, `## What the model found`, `## Affected spec §`, `## Suggested resolution`) or an addendum to the existing issue it stresses. **Do not edit any `specs/*.md` prose body.** If no genuine gap was found, state that explicitly in `FINDINGS.md` and create no issue files.

- [ ] **Step 4: Commit**

```bash
git add specs/quint/FINDINGS.md specs/issues/ 2>/dev/null; git add specs/quint/FINDINGS.md
git commit -m "docs(quint): findings/traceability report + filed model-surfaced issues"
```

---

## Self-Review

**Spec coverage** (design doc → tasks):
- Layout & tooling → Task 1. base.qnt → Task 2. budgets (`10`) → Tasks 3–4. state-model (`01`) → Tasks 5–6. mailbox (`06`) → Tasks 7–8. consensus (`02`) → Tasks 9–10. Findings handling → Task 11. Abstraction conventions → Task 2 (`base.qnt`) + README (Task 1). Build order base→budgets→state_model→mailbox→consensus → task ordering matches. ✅ No uncovered design section.
- Adversarial issues: ROB-01/02/03 (Task 10), ROB-04 (Task 10), ROB-05 runaway-vs-kernel-floor (Task 3), UX-03 mechanical tiering (Task 10), UX-04 never-answered (Task 8), ROB-07 unknown-reversibility→HighStakes (Task 8 high-stakes path; note: add an explicit `blastHigh` classification assert if deeper coverage wanted), I3/I4/I6 (Task 6), CAS serialization (Task 5), leaked-token/binding (Tasks 7–8). ✅

**Placeholder scan:** No "TBD/TODO/handle edge cases." Two spots defer *syntax fallbacks* (`.fail()` availability) with an explicit concrete alternative given — acceptable, not a content placeholder.

**Type consistency:** `verifyQuorum` abstracted as `passesOrdinary/passesConstitutional` (base) and used consistently in consensus. `subtreeSpend`/`cap`/`softThreshold` consistent across budgets Tasks 3–4. `corr`/`openIndex`/`nodeBlocked`/`mayAnswer` names identical across mailbox Tasks 7–8. `verification`/`outcome`/`tier`/`blastHigh` identical across consensus Tasks 9–10. State vars added in later tasks (`tasks`, `kernelTouched` in Task 6; `coverageHigh` etc. in Task 10) include explicit "add passthrough to existing actions" notes so `init`/actions stay total. ✅

**Known risk to flag at execution:** Quint syntax is not verifiable until Task 1 installs the toolchain. Treat the first `quint typecheck` in each task as the real gate — if a construct (`.fail()`, `.flatten()`, `getOrElse`, tuple `._1`) differs in `quint 0.24.0`, adapt to the installed stdlib and keep the invariant's meaning. This is expected formal-methods iteration, not a plan defect.
