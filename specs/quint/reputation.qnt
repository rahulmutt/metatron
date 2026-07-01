// # VERIFY: weightBounded, driftDecaysWeight, swingResistance
module reputation {
  import base.* from "./base"

  // reputation weight, integer proxy in [0..CAP] (00 uses f32 in [0,1]; ints keep MC
  // decidable, mirroring base.qnt's CostUnit convention). driftCount = consecutive
  // rounds voting against ground truth; resets to 0 on any correct vote.
  var weight: AgentId -> int
  var driftCount: AgentId -> int

  pure val CAP         = 6
  pure val DECAY       = 2
  pure val DRIFT_LIMIT = 3
  pure val START       = 4
  // derived: provable weight ceiling for a tainted agent (= 0 at these params)
  pure val DRIFT_WEIGHT_CAP = maxInt(0, CAP - DRIFT_LIMIT * DECAY)

  pure def maxInt(a: int, b: int): int = if (a > b) a else b
  pure def minInt(a: int, b: int): int = if (a < b) a else b

  // council: correlatable bloc {1,2,3,4} + honest anchor {5}
  pure val bloc    = Set(1, 2, 3, 4)
  pure val council = Set(1, 2, 3, 4, 5)

  action init = all {
    weight'     = council.mapBy(_ => START),
    driftCount' = council.mapBy(_ => 0),
  }

  // one scoring round for agent a whose vote went AGAINST ground truth
  action observeWrong(a: AgentId): bool = all {
    a.in(weight.keys()),
    weight'     = weight.set(a, maxInt(0, weight.get(a) - DECAY)),
    driftCount' = driftCount.set(a, driftCount.get(a) + 1),
  }
  // one scoring round for agent a whose vote MATCHED ground truth
  action observeRight(a: AgentId): bool = all {
    a.in(weight.keys()),
    weight'     = weight.set(a, minInt(CAP, weight.get(a) + 1)),
    driftCount' = driftCount.set(a, 0),
  }
  // no-op stutter so `step` never deadlocks for Apalache once activity stops — a
  // model-completeness artifact of the bounded fixture, not a weakening of any
  // invariant (every invariant is still checked at every state, idle ones included).
  // Same rationale as consensus.qnt / mailbox.qnt idle actions.
  action idle: bool = all { weight' = weight, driftCount' = driftCount }

  // only the bloc {1,2,3,4} may be driven wrong; the honest anchor {5} is only ever
  // observed right, keeping total council weight positive so swingResistance stays a
  // non-degenerate check of the decay dynamics (design §Fixture rationale).
  action step = any {
    nondet a = bloc.oneOf() observeWrong(a),
    nondet a = council.oneOf() observeRight(a),
    idle,
  }

  // --- invariants ---
  val weightBounded =
    weight.keys().forall(a => 0 <= weight.get(a) and weight.get(a) <= CAP)

  // A persistent drifter's weight is provably bounded by the derived ceiling. Because
  // DRIFT_WEIGHT_CAP is DEFINED as max(0, CAP - DRIFT_LIMIT*DECAY), this holds by
  // construction for any DECAY — it is a WELL-FORMEDNESS check (catches update-rule
  // bugs: decaying the wrong agent, an off-by-one streak counter, a broken driftCount
  // reset — a missing floor is weightBounded's job, not this one's). It
  // does NOT by itself catch a mis-tuned decay RATE — that is swingResistance's job
  // (Task 5). Deliberate division of labor (design §Invariants).
  val driftDecaysWeight =
    weight.keys().forall(a =>
      driftCount.get(a) >= DRIFT_LIMIT implies weight.get(a) <= DRIFT_WEIGHT_CAP)

  // summed weight of drift-flagged agents (tainted = a persistent drifter)
  def taintedWeight =
    council.filter(a => driftCount.get(a) >= DRIFT_LIMIT)
           .fold(0, (s, a) => s + weight.get(a))
  def totalWeight = council.fold(0, (s, a) => s + weight.get(a))

  // HEADLINE: even if the ENTIRE drift-flagged bloc votes Approve, its combined weight
  // cannot meet the 2/3 ordinary threshold — a correlated, persistently-wrong bloc
  // cannot unilaterally carry a proposal (the ROB-02 "correlated bloc loses its teeth"
  // claim). Checked against base.passesOrdinary — the SAME predicate consensus.qnt's
  // `decide` uses — so the swing test and the live threshold cannot silently diverge.
  // Reasons in ABSOLUTE threshold terms, so a too-slow DECAY (which merely raises the
  // derived DRIFT_WEIGHT_CAP) is caught here as a reachable counterexample (Task 6).
  val swingResistance = not(passesOrdinary(taintedWeight, totalWeight))

  // --- scenarios ---
  // Decay-to-floor is REACHED, not just bounded: agent 1, observed wrong DRIFT_LIMIT
  // times from START=4 (4 -> 2 -> 0 -> 0), lands at weight 0 with driftCount 3.
  run chronicDriftReachesFloorTest =
    init.then(observeWrong(1)).then(observeWrong(1)).then(observeWrong(1))
        .then(all {
          assert(weight.get(1) == 0 and driftCount.get(1) == DRIFT_LIMIT),
          weight' = weight, driftCount' = driftCount,
        })

  // Non-vacuity witness for swingResistance: drive the WHOLE bloc {1,2,3,4} past
  // DRIFT_LIMIT so the tainted set is non-empty, then assert the invariant holds over a
  // real tainted council (each bloc agent at weight 0; anchor 5 still at START).
  run blocDefangedTest =
    init.then(observeWrong(1)).then(observeWrong(2)).then(observeWrong(3)).then(observeWrong(4))
        .then(observeWrong(1)).then(observeWrong(2)).then(observeWrong(3)).then(observeWrong(4))
        .then(observeWrong(1)).then(observeWrong(2)).then(observeWrong(3)).then(observeWrong(4))
        .then(all {
          assert(council.filter(a => driftCount.get(a) >= DRIFT_LIMIT) == bloc
                 and swingResistance),
          weight' = weight, driftCount' = driftCount,
        })
}
