// # VERIFY: proposerNotDisposer, verifyBeforeVote, refutedNeverCommits, quorumAndThreshold, noAutonomousLowCoverageHighBlast, mechanicalTiering, breakGlassOnlyOnDeadlock
// # VERIFY-MAX-STEPS: 10
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
  var familyOf: AgentId -> int          // model_family, for correlation/diversity checks (Task 10)
  // --- Task 10 state: verification-coverage / blast-radius / burn-in / deadlock signals ---
  var coverageHigh: bool                // verification-coverage signal (07); high => machine-checkable
  var blastHigh: bool                   // proposal has high blast radius (consequential change)
  var burnIn: bool                      // true at genesis / after recomposition (weights uncalibrated)
  var deadlockDetected: bool            // a full round mechanically failed to reach commit

  action init = all {
    author' = 100,                                 // author is a Guardian, id 100 (not in council)
    council' = Set(1, 2, 3, 4, 5),
    tier' = Ordinary, verification' = NotRun, votes' = Map(),
    weight' = Map(1->2, 2->2, 3->2, 4->2, 5->2),
    familyOf' = Map(1->0, 2->0, 3->1, 4->1, 5->2),
    outcome' = Pending,
    coverageHigh' = true, blastHigh' = false, burnIn' = false, deadlockDetected' = false,
  }

  action verify(r: VReport): bool = all {
    verification == NotRun, r != NotRun,
    verification' = r,
    outcome' = if (r == Refuted) Rejected else Pending,
    author' = author, council' = council, tier' = tier, votes' = votes,
    weight' = weight, familyOf' = familyOf,
    coverageHigh' = coverageHigh, blastHigh' = blastHigh, burnIn' = burnIn,
    deadlockDetected' = deadlockDetected,
  }
  // a vote may be cast only after verification produced Residual (or Certified constitutional carve-out)
  action castVote(a: AgentId, v: Verdict): bool = all {
    a.in(council), not(a.in(votes.keys())),
    a != author,                                   // propose != dispose
    verification == Residual or (verification == Certified and tier == Constitutional),
    // Quint 0.24.0's `Map.set` requires the key to already exist (see mailbox.qnt NB2);
    // every vote targets a fresh AgentId key, so this uses `.put()` (upsert) instead.
    votes' = votes.put(a, v),
    author' = author, council' = council, tier' = tier, verification' = verification,
    weight' = weight, familyOf' = familyOf, outcome' = outcome,
    coverageHigh' = coverageHigh, blastHigh' = blastHigh, burnIn' = burnIn,
    deadlockDetected' = deadlockDetected,
  }
  def approveWeight = votes.keys().filter(a => votes.get(a) == Approve).fold(0, (s,a) => s + weight.get(a))
  def totalWeight   = votes.keys().fold(0, (s,a) => s + weight.get(a))
  def quorumMet     = votes.keys().size() * 2 > council.size()   // >half participate
  // model-family diversity: count distinct families among the agents that have actually voted.
  // >= 2 distinct families guards against a correlated (single-family) council auto-committing.
  def distinctFamilies = council.filter(a => a.in(votes.keys())).map(a => familyOf.get(a)).size()
  def diversityFloorMet = distinctFamilies >= 2
  // NB: a `val` inside `all{}` scopes only over the single next comma item (confirmed in
  // Tasks 3/7/8) — `pass`/`autonomyOk` are needed by BOTH `outcome'` and would otherwise leak
  // into the trailing pass-through items, so every statement depending on them is wrapped in a
  // nested `all{}` right after the chained `val`s.
  action decide: bool = all {
    outcome == Pending, verification != NotRun, verification != Refuted,
    votes.keys().size() == council.size(),         // all cast (blind round complete)
    val pass = quorumMet and (if (tier == Constitutional) passesConstitutional(approveWeight, totalWeight)
                              else passesOrdinary(approveWeight, totalWeight))
    // ROB-01/02/03: an autonomous commit is only permitted with high coverage, model-family
    // diversity, and past burn-in. Otherwise a passing high-blast proposal must ESCALATE.
    val autonomyOk = coverageHigh and diversityFloorMet and not(burnIn)
    all {
      outcome' = if (pass and (not(blastHigh) or autonomyOk)) Committed
                 else if (pass and blastHigh) Escalated
                 else Rejected,
      author' = author, council' = council, tier' = tier, verification' = verification,
      votes' = votes, weight' = weight, familyOf' = familyOf,
      coverageHigh' = coverageHigh, blastHigh' = blastHigh, burnIn' = burnIn,
      deadlockDetected' = deadlockDetected,
    }
  }
  // tier is assigned MECHANICALLY from (touchesKernel, reversible, blastHigh); a Guardian
  // cannot hand-wave a consequential change into Routine. Enabled pre-verification only.
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
  // A deadlock monitor: a full council round that failed to commit (outcome not Committed)
  // may be mechanically flagged as deadlocked. Kept simple/monotonic (never un-set) — its
  // only purpose is to ENABLE break-glass, so the recovery path is reachable in MC.
  action detectDeadlock: bool = all {
    not(deadlockDetected), outcome != Committed,
    deadlockDetected' = true,
    author' = author, council' = council, tier' = tier, verification' = verification,
    votes' = votes, weight' = weight, familyOf' = familyOf, outcome' = outcome,
    coverageHigh' = coverageHigh, blastHigh' = blastHigh, burnIn' = burnIn,
  }
  // break-glass (ROB-04): deadlock recovery does NOT route through the broken quorum; only
  // enabled once deadlock is mechanically detected; scope-limited to recomposition (WidenCouncil).
  action breakGlass: bool = all {
    deadlockDetected,
    council' = council.union(Set(6, 7)),   // widen; recomposition re-enters burn-in
    burnIn' = true, outcome' = Escalated, votes' = Map(),
    author' = author, tier' = tier, verification' = verification, weight' = weight.put(6,2).put(7,2),
    familyOf' = familyOf.put(6,3).put(7,4), coverageHigh' = coverageHigh, blastHigh' = blastHigh,
    deadlockDetected' = deadlockDetected,
  }
  // Always-enabled no-op so `step` never deadlocks once the proposal has reached a terminal
  // outcome (Committed/Rejected/Escalated) — every other action's guard is then disabled.
  // Apalache's `quint verify` treats a stuck `step` relation as a reportable deadlock, which
  // is a model-completeness artifact of the bounded funnel reaching its terminal state, not a
  // safety violation. `idle` keeps every state reachable for exploration without ever weakening
  // any invariant.
  action idle: bool = all {
    author' = author, council' = council, tier' = tier, verification' = verification,
    votes' = votes, weight' = weight, familyOf' = familyOf, outcome' = outcome,
    coverageHigh' = coverageHigh, blastHigh' = blastHigh, burnIn' = burnIn,
    deadlockDetected' = deadlockDetected,
  }
  action step = any {
    nondet tk = Set(false, true).oneOf() (nondet rev = Set(false, true).oneOf()
      (nondet hi = Set(false, true).oneOf() classify(tk, rev, hi))),
    nondet r = Set(Refuted, Certified, Residual).oneOf() verify(r),
    nondet a = council.oneOf() (nondet v = Set(Approve, Reject, Abstain).oneOf() castVote(a, v)),
    decide,
    detectDeadlock,
    breakGlass,
    idle,
  }

  // --- invariants ---
  val proposerNotDisposer = not(author.in(votes.keys()))
  val verifyBeforeVote = (votes.keys().size() > 0) implies
    (verification == Residual or (verification == Certified and tier == Constitutional))
  val refutedNeverCommits = (verification == Refuted) implies (outcome != Committed)
  val quorumAndThreshold = (outcome == Committed) implies
    (quorumMet and (if (tier == Constitutional) passesConstitutional(approveWeight, totalWeight)
                    else passesOrdinary(approveWeight, totalWeight)))
  // ROB-01/02/03: a high-blast-radius proposal may not autonomously commit when coverage is
  // low OR diversity floor unmet OR still in burn-in — it must escalate.
  val noAutonomousLowCoverageHighBlast =
    (outcome == Committed and blastHigh) implies (coverageHigh and diversityFloorMet and not(burnIn))
  // Routine tier is mechanically never high-blast (classify pins them together).
  val mechanicalTiering = (tier == Routine) implies (not(blastHigh))
  // The council is only ever widened (break-glass) once a deadlock was mechanically detected.
  // `breakGlass` is the ONLY action that adds {6,7} to `council`, and it is guarded by
  // `deadlockDetected` (which is monotonic), so a widened council implies deadlock was detected.
  val breakGlassOnlyOnDeadlock = (6.in(council) or 7.in(council)) implies deadlockDetected

  // --- scenarios ---
  // A Refuted verification report immediately rejects the proposal and permanently disables
  // voting — verify-before-vote holds even in the "never got to vote" branch.
  run refutedRejectsNoVoteTest =
    init.then(verify(Refuted))
        .then(all {
          assert(outcome == Rejected),
          author' = author, council' = council, tier' = tier, verification' = verification,
          votes' = votes, weight' = weight, familyOf' = familyOf, outcome' = outcome,
          coverageHigh' = coverageHigh, blastHigh' = blastHigh, burnIn' = burnIn,
          deadlockDetected' = deadlockDetected,
        })
        .then(castVote(1, Approve).fail())   // no vote after Refuted

  // propose != dispose: the author (id 100, not in council anyway) can never cast a vote.
  run authorCannotVoteTest =
    init.then(verify(Residual)).then(castVote(100, Approve).fail())

  // Full Approve-majority round genuinely reaches Committed (non-vacuity for
  // refutedNeverCommits / quorumAndThreshold, which are otherwise vacuous over Committed).
  run ordinaryPassPathTest =
    init.then(verify(Residual))
        .then(castVote(1,Approve)).then(castVote(2,Approve)).then(castVote(3,Approve))
        .then(castVote(4,Approve)).then(castVote(5,Reject)).then(decide)
        .then(all {
          assert(outcome == Committed),
          author' = author, council' = council, tier' = tier, verification' = verification,
          votes' = votes, weight' = weight, familyOf' = familyOf, outcome' = outcome,
          coverageHigh' = coverageHigh, blastHigh' = blastHigh, burnIn' = burnIn,
          deadlockDetected' = deadlockDetected,
        })

  // ROB headline: a correlated confident-wrong council — all one model family, all Approve a
  // high-blast, low-coverage residue — must NOT auto-commit; it must Escalate.
  run correlatedCouncilCannotAutoCommitTest =
    init.then(all { familyOf' = Map(1->0,2->0,3->0,4->0,5->0), coverageHigh' = false, blastHigh' = true,
                    author'=author, council'=council, tier'=tier, verification'=verification, votes'=votes,
                    weight'=weight, outcome'=outcome, burnIn'=burnIn, deadlockDetected'=deadlockDetected })
        .then(verify(Residual))
        .then(castVote(1,Approve)).then(castVote(2,Approve)).then(castVote(3,Approve))
        .then(castVote(4,Approve)).then(castVote(5,Approve)).then(decide)
        .then(all {
          assert(outcome == Escalated),          // headline residual risk is caught, not committed
          author' = author, council' = council, tier' = tier, verification' = verification,
          votes' = votes, weight' = weight, familyOf' = familyOf, outcome' = outcome,
          coverageHigh' = coverageHigh, blastHigh' = blastHigh, burnIn' = burnIn,
          deadlockDetected' = deadlockDetected,
        })

  // break-glass is disabled until a deadlock is detected (deadlockDetected is false at genesis).
  run breakGlassGatedTest = init.then(breakGlass.fail())
}
