// # VERIFY: weightBounded, slashRequiresCorroboration, quarantineRequiresQuorum
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
  // distinct sentinels with a live finding on a.
  def corroboratorsOf(a: AgentId): Set[AgentId] =
    findings.filter(f => f._2 == a).map(f => f._1)

  // --- invariants ---
  val weightBounded =
    weight.keys().forall(a => 0 <= weight.get(a) and weight.get(a) <= CAP)

  // ROB-06 acceptance box #1, in invariant form: every slash that has occurred was
  // backed by >= K DISTINCT sentinels. Catches guard bugs (slash on one finding, an
  // off-by-one corroboration count). Expected to HOLD — the prose fix is literally correct.
  val slashRequiresCorroboration =
    lastSlashCorroborators == 0 or lastSlashCorroborators >= K

  // ROB-06 acceptance box #2's sibling on the EVICTION path: a quarantine fires only when
  // the faction can carry an ordinary (2/3) TypedDiff. Expected to HOLD — the finding
  // (ROB-12) is that the quorum itself is manufacturable, not that this guard is buggy.
  val quarantineRequiresQuorum =
    lastQuarantinePassedQuorum or council.forall(a => status.get(a) == Active)

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

  // Non-vacuity witness: two DISTINCT sentinels corroborate, slash fires, invariant holds
  // over a non-empty slash. weight 4 -> max(0, 4-3) = 1.
  run soundSlashReachableTest =
    init.then(raiseFinding(101, 3)).then(raiseFinding(102, 3)).then(corroboratedSlash(3))
        .then(all {
          assert(weight.get(3) == 1 and lastSlashCorroborators >= K
                 and slashRequiresCorroboration),
          weight' = weight, status' = status, findings' = findings,
          deoptStorm' = deoptStorm, lastSlashCorroborators' = lastSlashCorroborators,
          lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
        })

  // The corroborated path: enabled only when >= K DISTINCT sentinels have live findings
  // on a. Applies SLASH, consumes a's findings, records the corroboration count (ghost).
  action corroboratedSlash(a: AgentId): bool = all {
    corroboratorsOf(a).size() >= K,
    weight' = weight.set(a, maxInt(0, weight.get(a) - SLASH)),
    findings' = findings.filter(f => f._2 != a),
    lastSlashCorroborators' = corroboratorsOf(a).size(),
    status' = status, deoptStorm' = deoptStorm,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }

  // The OR-branch oracle (07 §5.9): adjudication through the deterministic G0 gate.
  // Enabled only for the GUILTY (never, in this fixture). The SOUND path — present so the
  // model records that a legitimate single-source slash exists, gated on soundness not count.
  action g0Slash(a: AgentId): bool = all {
    a.in(guilty),
    weight' = weight.set(a, maxInt(0, weight.get(a) - SLASH)),
    findings' = findings.filter(f => f._2 != a),
    lastSlashCorroborators' = K,   // G0 adjudication is treated as fully-authorized
    status' = status, deoptStorm' = deoptStorm,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }

  // Ordinary (2/3) quarantine of a Worker-grade voter (08 §3.6): enabled iff the faction's
  // Active approve weight passes passesOrdinary over the Active total. Drops a from
  // aggregation. Checked against base.passesOrdinary — the SAME predicate decide uses.
  action quarantine(a: AgentId): bool = all {
    a.in(council),
    status.get(a) == Active,
    passesOrdinary(factionApproveWeight, activeTotalWeight),
    status' = status.set(a, Quarantined),
    lastQuarantinePassedQuorum' = true,
    weight' = weight, findings' = findings, deoptStorm' = deoptStorm,
    lastSlashCorroborators' = lastSlashCorroborators,
  }

  // temporary stutter so the module typechecks/tests before step is built (Task 6).
  action idle = all {
    weight' = weight, status' = status, findings' = findings, deoptStorm' = deoptStorm,
    lastSlashCorroborators' = lastSlashCorroborators,
    lastQuarantinePassedQuorum' = lastQuarantinePassedQuorum,
  }
  action step = idle
}
