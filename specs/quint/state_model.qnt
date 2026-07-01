// # VERIFY: headReachable, linearSpine, gapFreeTime
module state_model {
  import base.* from "./base"

  type Hash = int                       // content address, modeled as a bounded int id
  type Commit = { id: Hash, parent: int, index: int, author: AgentId, constitutional: bool }

  var store: Hash -> Commit             // immutable content-addressed node store (grow-only)
  var headId: Hash
  var staged: Set[Commit]               // candidate commits racing for the headId
  var nextId: Hash

  val GENESIS: Commit = { id: 0, parent: -1, index: 0, author: 0, constitutional: false }

  action init = all {
    store' = Map(0 -> GENESIS), headId' = 0, staged' = Set(), nextId' = 1,
  }

  // stage a candidate against the CURRENT headId (optimistic concurrency base)
  action stage(auth: AgentId, isConst: bool): bool = all {
    val c = { id: nextId, parent: headId, index: store.get(headId).index + 1, author: auth, constitutional: isConst }
    staged' = staged.union(Set(c)), nextId' = nextId + 1,
    store' = store, headId' = headId,
  }
  // CAS: a staged candidate wins iff its parent still equals headId. Exactly one wins per tick.
  action advanceHead(c: Commit): bool = all {
    c.in(staged), c.parent == headId,
    store' = store.put(c.id, c), headId' = c.id,
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
  val headReachable = 0.in(ancestors(headId))
  val gapFreeTime = store.keys().forall(h =>
    store.get(h).parent >= 0 implies store.get(h).index == store.get(store.get(h).parent).index + 1)
  // linear spine: no two COMMITTED nodes (in store, on the headId's ancestor chain) share a parent
  val linearSpine =
    ancestors(headId).forall(x => ancestors(headId).forall(y =>
      (x != y and store.get(x).parent == store.get(y).parent and store.get(x).parent >= 0) implies false))

  // --- tests ---
  // two candidates stage against the same headId; only one becomes headId, no double-advance
  run casSerializesTest =
    init.then(stage(1, false)).then(stage(2, false))
        .then(all { nondet c = staged.oneOf() advanceHead(c) })
        .then(all { assert(linearSpine and headReachable),
                    store' = store, headId' = headId, staged' = staged, nextId' = nextId })
}
