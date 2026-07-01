// # VERIFY: stockNeverExceedsCap, childFloorsFitParent, kernelFloorAvailable, bucketWithinCapacity, layeredStopOrdering, notifierIsOffBudget
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

  pure def min(a: int, b: int): int = if (a < b) a else b

  pure def cap(n: Node): CostUnit = n.burstCap
  pure def softThreshold(n: Node): CostUnit = n.burstCap - n.shutdownReserve

  def isAncestor(a: NodeId, b: NodeId): bool =
    tree.get(b).parent == a  // one-level tree in the bounded model (Global -> Class -> Agent)
        or (tree.get(b).parent != -1 and tree.get(tree.get(b).parent).parent == a)

  // descendants' cumulative stock rolls up to an ancestor
  def subtreeSpend(root: NodeId): CostUnit =
    tree.keys().filter(k => k == root or isAncestor(root, k))
       .fold(0, (acc, k) => acc + ledger.get(k).stockSpent)

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

  // --- layered-stop / off-budget invariants (Task 4) ---
  // legal predecessors for each status; the ladder guards enforce this structurally
  // (e.g. Running -> Cancelled is impossible: hardCancel requires Frozen). Documented here;
  // the actual no-skip guarantee is exercised by cannotSkipToCancelTest (disabled-guard check).
  pure def legalPrev(s: Status): Set[Status] =
    match s {
      | Notified => Set(Running) | Draining => Set(Notified)
      | Frozen => Set(Draining)  | Cancelled => Set(Frozen)
      | Running => Set(Running)  | Throttled => Set(Running)
    }
  // Non-vacuous ordering support: any node that has left Running must have had its notice
  // counted (notices >= 1). Since crossSoftThreshold is the sole exit from Running AND the
  // sole notifier, a node cannot advance down the ladder without a real threshold crossing.
  // (The brief's `Cancelled implies reserve>0 and softThreshold<cap` is vacuous under this
  // fixture where every node has reserve>0; this form actually constrains reachable states.)
  val layeredStopOrdering =
    status.keys().forall(k => status.get(k) != Running implies notices >= 1)
  // Off-budget notifier accounting (STRENGTHENED from the brief's `notices >= 0` tautology):
  // the notice count must EXACTLY equal the number of nodes that have entered the stop ladder.
  // Falsifiable — it fails if crossSoftThreshold ever over/under-counts, or if any OTHER action
  // moved a node out of Running without emitting a notice (or emitted a notice without moving one).
  val notifierIsOffBudget =
    notices == status.keys().filter(k => status.get(k) != Running).size()

  // helper predicates for chargeStock's guard, hoisted to top-level defs (rather than
  // chained `val` bindings inside `all{}`) — see report: Quint 0.24.0's parser fails to
  // resolve a `val` binding whose body contains a lambda (`=>`) when it follows another
  // `val` binding in the same comma-less chain ("Name 'x' not found" at typecheck time).
  def wouldExceedCap(k: NodeId, amt: CostUnit): bool =
    tree.keys().exists(a =>
      (a == k or isAncestor(a, k)) and (subtreeSpend(a) + amt > cap(tree.get(a))))
  // NB: must add the pending `amt` to subtreeSpend(a) whenever a is on k's
  // ancestor-or-self path (a == k or isAncestor(a, k)) — the charge to k rolls up
  // into a's spend before this action commits, so the guard has to reason about the
  // POST-charge headroom, not the current one. (See report: the brief's original guard
  // read `cap(a) - subtreeSpend(a) < floor(a)` without the `+ amt` term, so it never
  // caught a direct charge to a kernel node itself pushing that node below its own floor
  // — Apalache found this counterexample against `kernelFloorAvailable`.)
  def breaksKernelFloor(k: NodeId, amt: CostUnit): bool =
    tree.keys().exists(a =>
      match tree.get(a).scope {
        | Class(r) =>
            val onPath = a == k or isAncestor(a, k)
            isKernel(r) and (cap(tree.get(a)) - (subtreeSpend(a) + (if (onPath) amt else 0)) < tree.get(a).floor)
        | _ => false })

  // charge `amt` to node k: allowed only if it keeps k and every ancestor within cap,
  // and (beyond own floor) the parent burst pool has room. Kernel floor is protected
  // because a Worker charge that would push a kernel sibling below its floor is disabled.
  action chargeStock(k: NodeId, amt: CostUnit): bool = all {
    amt > 0, amt <= 5,
    not(wouldExceedCap(k, amt)),
    not(breaksKernelFloor(k, amt)),
    ledger' = ledger.set(k, { ...ledger.get(k), stockSpent: ledger.get(k).stockSpent + amt }),
    tree' = tree, status' = status, notices' = notices,
  }
  action refillBucket(k: NodeId): bool = all {
    val lvl = ledger.get(k).bucketLevel
    val filled = min(tree.get(k).burstDepth, lvl + tree.get(k).sustained)
    ledger' = ledger.set(k, { ...ledger.get(k), bucketLevel: filled }),
    tree' = tree, status' = status, notices' = notices,
  }

  // --- layered-stop ladder (Task 4): crossSoftThreshold -> drain -> freeze -> hardCancel ---
  // A node crosses its soft threshold once its stock reaches burstCap - shutdownReserve.
  // Hoisted to a top-level pure def (per Task 3 convention) so its lambda-free body resolves.
  pure def overSoft(k: NodeId, t: NodeId -> Node, l: NodeId -> Spend): bool =
    l.get(k).stockSpent >= (t.get(k).burstCap - t.get(k).shutdownReserve)

  // The notifier: fires exactly once per node, at zero budget cost (ledger/tree untouched).
  // crossSoftThreshold is the ONLY action that increments `notices` and the ONLY action
  // that moves a node OUT of Running — this is what makes notifierIsOffBudget falsifiable.
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

  action step = nondet k = tree.keys().oneOf(); any {
    nondet a = Set(1,2,3,4,5).oneOf() { chargeStock(k, a) },
    refillBucket(k), crossSoftThreshold(k), drain(k), freeze(k), hardCancel(k),
  }

  // adversarial: worker (node 2) charges hard; kernel-class (1) floor stays available
  run runawayWorkerRespectsKernelFloorTest =
    init.then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5))
        .then(all { assert(kernelFloorAvailable), tree' = tree, ledger' = ledger, status' = status, notices' = notices })

  // --- adversarial layered-stop scenarios (Task 4) ---
  // Depletion to (or above) the soft threshold produces EXACTLY one notice and moves the node
  // to Notified. crossSoftThreshold(2) is only enabled once stockSpent(2) >= softThreshold(2) =
  // burstCap - shutdownReserve = 90 - 5 = 85, so we drive node 2 with 17 charges of 5 (= 85)
  // before the notify step. Global roll-up stays within cap 100 (node 1 = 0). The brief's 6x5=30
  // was below the 85 threshold and would have left crossSoftThreshold(2) DISABLED; the asserted
  // property (notices == 1 and status.get(2) == Notified) is preserved verbatim.
  run depletionAlwaysNotifiesTest =
    init.then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5))
        .then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5))
        .then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5))
        .then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5))
        .then(chargeStock(2, 5))
        .then(crossSoftThreshold(2))
        .then(all { assert(notices == 1 and status.get(2) == Notified),
                    tree' = tree, ledger' = ledger, status' = status, notices' = notices })

  // No Running -> Cancelled skip: hardCancel is disabled unless the node is Frozen.
  // Quint 0.24.0 note: the brief's `.expect(hardCancel(2).fail())` fails the effect checker,
  // but `.then(hardCancel(2).fail())` works and is stronger than the assert-only fallback —
  // it actually ATTEMPTS hardCancel and requires the guard (status == Frozen) to be false.
  run cannotSkipToCancelTest =
    init.then(chargeStock(2, 5))
        .then(hardCancel(2).fail())   // guard false: status is Running, not Frozen

  // Reserve is carved UNDER cap for every node, so the ordering invariant holds at init.
  run reserveCarvedUnderCapTest =
    init.then(all { assert(layeredStopOrdering),
                    tree' = tree, ledger' = ledger, status' = status, notices' = notices })
}
