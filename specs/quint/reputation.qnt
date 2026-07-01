// # VERIFY: weightBounded
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

  // --- invariants ---
  val weightBounded =
    weight.keys().forall(a => 0 <= weight.get(a) and weight.get(a) <= CAP)
}
