// # VERIFY: stockNeverExceedsCap, childFloorsFitParent, kernelFloorAvailable, bucketWithinCapacity
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
  action step = nondet k = tree.keys().oneOf(); any {
    nondet a = Set(1,2,3,4,5).oneOf() { chargeStock(k, a) },
    refillBucket(k),
  }

  // adversarial: worker (node 2) charges hard; kernel-class (1) floor stays available
  run runawayWorkerRespectsKernelFloorTest =
    init.then(chargeStock(2, 5)).then(chargeStock(2, 5)).then(chargeStock(2, 5))
        .then(all { assert(kernelFloorAvailable), tree' = tree, ledger' = ledger, status' = status, notices' = notices })
}
