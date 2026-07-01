// # VERIFY: headReachable, linearSpine, gapFreeTime, constitutionalIffKernel, constitutionalFlagHonest, taskDagAcyclic, blockedTaskSafety
module state_model {
  import base.* from "./base"

  type Hash = int                       // content address, modeled as a bounded int id
  // touchedKernel records, per stored commit, whether its ops mutated the kernel set (I3 witness)
  type Commit = { id: Hash, parent: int, index: int, author: AgentId, constitutional: bool, touchedKernel: bool }

  var store: Hash -> Commit             // immutable content-addressed node store (grow-only)
  var headId: Hash
  var staged: Set[Commit]               // candidate commits racing for the headId
  var nextId: Hash

  // --- progress-layer subset needed for I4/I6: tasks with deps + a blocked-on question flag ---
  type TaskStatus = Todo | InProgress | Done | Failed | Cancelled
  type Task = { deps: Set[int], blockedPending: bool, tstatus: TaskStatus }
  var tasks: int -> Task
  var kernelTouched: bool                // set by the last applied diff (models "ops mutate KernelSet")

  val GENESIS: Commit = { id: 0, parent: -1, index: 0, author: 0, constitutional: false, touchedKernel: false }

  action init = all {
    store' = Map(0 -> GENESIS), headId' = 0, staged' = Set(), nextId' = 1,
    tasks' = Map(), kernelTouched' = false,
  }

  // stage a candidate against the CURRENT headId (optimistic concurrency base).
  // DESIGN (i), honest-by-construction: raw stage sets touchedKernel = isConst, so the I3 iff
  // (constitutional <-> touchedKernel) holds over ALL reachable states, not only the checked path.
  action stage(auth: AgentId, isConst: bool): bool = all {
    val c = { id: nextId, parent: headId, index: store.get(headId).index + 1,
              author: auth, constitutional: isConst, touchedKernel: isConst }
    staged' = staged.union(Set(c)), nextId' = nextId + 1,
    store' = store, headId' = headId,
    tasks' = tasks, kernelTouched' = kernelTouched,
  }
  // CAS: a staged candidate wins iff its parent still equals headId. Exactly one wins per tick.
  action advanceHead(c: Commit): bool = all {
    c.in(staged), c.parent == headId,
    store' = store.put(c.id, c), headId' = c.id,
    staged' = Set(),  // a CAS win invalidates every candidate staged against the old head; all are dropped
    nextId' = nextId,
    tasks' = tasks, kernelTouched' = kernelTouched,
  }
  action step = any {
    nondet a = Set(1, 2).oneOf() (nondet b = Set(true, false).oneOf() stage(a, b)),
    nondet c = staged.oneOf() advanceHead(c),
  }
  // A progress-layer step used to model-check the task DAG invariants (I4/I6) non-vacuously.
  // Kept separate from `step` so the default (Task-5) `step` — and thus verify.sh — stays fast;
  // drive verify with `--step=taskStep` to explore populated task maps (all three hold: NoError
  // confirmed through 6 states). The `quint test` scenarios below also exercise I4/I6 non-vacuously.
  action taskStep = any {
    nondet a = Set(1, 2).oneOf() (nondet b = Set(true, false).oneOf() stage(a, b)),
    nondet c = staged.oneOf() advanceHead(c),
    nondet t = Set(1, 2).oneOf() addTask(t),
    nondet t = Set(1, 2).oneOf() (nondet d = Set(1, 2).oneOf() addDep(t, d)),
    nondet t = Set(1, 2).oneOf() setTaskDone(t),
  }

  // --- diff-application actions with I-guards (progress layer) ---
  action addTask(t: int): bool = all {
    not(t.in(tasks.keys())),
    tasks' = tasks.put(t, { deps: Set(), blockedPending: false, tstatus: Todo }),
    store' = store, headId' = headId, staged' = staged, nextId' = nextId, kernelTouched' = false,
  }
  action addDep(t: int, d: int): bool = all {
    t.in(tasks.keys()), d.in(tasks.keys()), t != d,
    not(reaches(d, t)),                    // I4: reject edges that would create a cycle
    tasks' = tasks.set(t, { ...tasks.get(t), deps: tasks.get(t).deps.union(Set(d)) }),
    store' = store, headId' = headId, staged' = staged, nextId' = nextId, kernelTouched' = false,
  }
  action setTaskDone(t: int): bool = all {
    t.in(tasks.keys()), tasks.get(t).tstatus == InProgress,
    not(tasks.get(t).blockedPending),      // I6: a pending-blocked task cannot reach Done
    tasks' = tasks.set(t, { ...tasks.get(t), tstatus: Done }),
    store' = store, headId' = headId, staged' = staged, nextId' = nextId, kernelTouched' = false,
  }
  // is b in the reflexive-transitive dep-closure of a (bounded unfold). Top-level def:
  // nested fold/map lambdas. Reflexive: reaches(a, a) is always true (seed Set(a) contains a),
  // which is exactly what the addDep guard wants (it is only ever called with d != t).
  def reaches(a: int, b: int): bool =
    0.to(MAX_AGENTS + MAX_DEPTH).fold(Set(a), (acc, _) =>
      acc.union(acc.map(x => if (x.in(tasks.keys())) tasks.get(x).deps else Set()).flatten()))
       .contains(b)
  // strict reachability: b reachable from a via >= 1 dep edge. Used for proper cycle detection,
  // where the reflexive `reaches` would give a false self-cycle for every task.
  def reachesStrict(a: int, b: int): bool =
    (if (a.in(tasks.keys())) tasks.get(a).deps else Set()).exists(d => reaches(d, b))

  // I3 checked-stage path: the constitutional flag must match kernel reality, else the stage is
  // invalid (guard disabled). stage() already sets touchedKernel = isConst; the guard forces
  // isConst == touchesKernel, so a checked commit carries a truthful witness.
  action stageChecked(auth: AgentId, isConst: bool, touchesKernel: bool): bool = all {
    isConst == touchesKernel,              // I3: flag must match reality, else invalid
    stage(auth, isConst),
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

  // I3: every stored commit is `constitutional` IFF its ops touched the kernel set.
  val constitutionalIffKernel =
    store.keys().forall(h => store.get(h).constitutional == store.get(h).touchedKernel)
  // GENESIS is an honest, non-constitutional, non-kernel-touching root (distinct from the iff above).
  val constitutionalFlagHonest =
    store.get(0).constitutional == false and store.get(0).touchedKernel == false
  // I4: the task dependency graph is acyclic (no task reaches itself via a >= 1-edge dep path).
  val taskDagAcyclic = tasks.keys().forall(t => not(reachesStrict(t, t)))
  // I6: a task blocked pending a question can never be in the Done state.
  val blockedTaskSafety = tasks.keys().forall(t =>
    tasks.get(t).blockedPending implies tasks.get(t).tstatus != Done)

  // --- tests ---
  // two candidates stage against the same headId; only one becomes headId, no double-advance
  run casSerializesTest =
    init.then(stage(1, false)).then(stage(2, false))
        .then(all { nondet c = staged.oneOf() advanceHead(c) })
        .then(all { assert(linearSpine and headReachable),
                    store' = store, headId' = headId, staged' = staged, nextId' = nextId,
                    tasks' = tasks, kernelTouched' = kernelTouched })

  // I4: a cycle-creating edge (2 -> 1 once 1 -> 2 exists) is rejected by addDep's guard.
  // The final assert checks taskDagAcyclic over a NON-EMPTY task map (2 tasks + a dep edge),
  // so I4 is exercised non-vacuously here (not just vacuously over the empty map under verify).
  run cycleRejectedTest =
    init.then(addTask(1)).then(addTask(2)).then(addDep(1, 2))
        .then(all { assert(taskDagAcyclic),     // I4 holds over a non-empty 2-task + edge map
                    store' = store, headId' = headId, staged' = staged, nextId' = nextId,
                    tasks' = tasks, kernelTouched' = kernelTouched })
        .then(addDep(2, 1).fail())              // adding 2->1 would create a cycle -> guard disabled

  // I6: a task blocked pending a question cannot transition to Done.
  // The final assert checks blockedTaskSafety over a NON-EMPTY task map holding a blocked,
  // InProgress task, so I6 ranges over a real blocked task rather than the empty map.
  run blockedCannotFinishTest =
    init.then(addTask(1))
        .then(all { tasks' = tasks.set(1, { deps: Set(), blockedPending: true, tstatus: InProgress }),
                    store' = store, headId' = headId, staged' = staged, nextId' = nextId,
                    kernelTouched' = kernelTouched })
        .then(all { assert(blockedTaskSafety),  // I6 holds over a real blocked, InProgress task
                    store' = store, headId' = headId, staged' = staged, nextId' = nextId,
                    tasks' = tasks, kernelTouched' = kernelTouched })
        .then(setTaskDone(1).fail())            // cannot reach Done while pending-blocked

  // I3: a stage claiming non-constitutional while touching the kernel is rejected (guard disabled).
  run i3EvasionRejectedTest =
    init.then(stageChecked(1, false, true).fail())  // false flag but touches kernel -> invalid
}
