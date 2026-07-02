// # VERIFY: weightBounded
module sentinel {
  import base.* from "./base"

  // reputation weight IS voting weight (08 §3.3, OE-05); integer proxy in [0..CAP]
  // (00 uses f32; ints keep MC decidable, per base.qnt's CostUnit convention).
  var weight: AgentId -> int
  // aggregation membership: a Quarantined voter is dropped from aggregation (08 §3.6).
  type Status = Active | Quarantined
  var status: AgentId -> Status
  // the live corroboration window: (sentinelId, targetId) findings not yet consumed.
  var findings: Set[(AgentId, AgentId)]
  // manufactured trap telemetry against the standing proposal (the G1 laundering path).
  var deoptStorm: int
  // ghosts: record the gate arithmetic at fire time so well-formedness is an invariant.
  var lastSlashCorroborators: int
  var lastQuarantinePassedQuorum: bool

  pure val CAP         = 6   // max reputation/voting weight
  pure val START       = 4   // initial weight for every council member
  pure val SLASH       = 3   // weight removed by a corroborated slash
  pure val K           = 2   // k-of-n corroboration threshold (07 §5.9 / 08 §3.6)
  pure val STORM_LIMIT = 2   // deopt count past which G1 retro-scoring bites jurors
  pure val G1_PENALTY  = 2   // weight an approving juror loses to G1 retro-scoring

  pure def maxInt(a: int, b: int): int = if (a > b) a else b

  // council fixture: compromised faction {1,2} (sub-2/3 at init by construction)
  // vs. honest {3,4,5}. Sentinel ids offset 10x so the two id spaces never alias.
  pure val faction = Set(1, 2)
  pure val honest  = Set(3, 4, 5)
  pure val council = Set(1, 2, 3, 4, 5)
  pure val sBloc   = Set(101, 102)   // correlated Sentinels (share a base model)
  pure val sHonest = Set(103)        // one independent Sentinel
  pure val guilty  = Set()           // ground truth: NO council member is actually guilty

  action init = all {
    weight'                    = council.mapBy(_ => START),
    status'                    = council.mapBy(_ => Active),
    findings'                  = Set(),
    deoptStorm'                = 0,
    lastSlashCorroborators'    = 0,
    lastQuarantinePassedQuorum' = false,
  }

  // weight summed over Active voters only (Quarantined are out of aggregation).
  def activeTotalWeight =
    council.filter(a => status.get(a) == Active).fold(0, (s, a) => s + weight.get(a))
  // approve weight the compromised faction can muster from its Active members.
  def factionApproveWeight =
    faction.filter(a => status.get(a) == Active).fold(0, (s, a) => s + weight.get(a))

  // --- invariants ---
  val weightBounded =
    weight.keys().forall(a => 0 <= weight.get(a) and weight.get(a) <= CAP)

  // ROB-06's literal guarantee: a lone finding moves no weight and evicts no voter.
  run singleFindingInertTest =
    init.then(raiseFinding(101, 3))
        .then(all {
          assert(weight.get(3) == START and status.get(3) == Active
                 and findings == Set((101, 3))),
          weight' = weight, status' = status, findings' = findings,
          deoptStorm' = deoptStorm, lastSlashCorroborators' = lastSlashCorroborators,
          lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
        })

  // A bloc Sentinel may target ANY council member; an honest Sentinel only the guilty
  // (i.e. never, in this fixture — guilty = {}). Findings accumulate; no weight moves.
  action raiseFinding(s: AgentId, a: AgentId): bool = all {
    a.in(council),
    or {
      s.in(sBloc),
      s.in(sHonest) and a.in(guilty),
    },
    findings' = findings.union(Set((s, a))),
    weight' = weight, status' = status, deoptStorm' = deoptStorm,
    lastSlashCorroborators' = lastSlashCorroborators,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }

  // temporary stutter so the module typechecks/tests before step is built (Task 6).
  action idle = all {
    weight' = weight, status' = status, findings' = findings, deoptStorm' = deoptStorm,
    lastSlashCorroborators' = lastSlashCorroborators,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }
  action step = idle
}
