// # VERIFY: proposerNotDisposer, verifyBeforeVote, refutedNeverCommits, quorumAndThreshold
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
    // Quint 0.24.0's `Map.set` requires the key to already exist (see mailbox.qnt NB2);
    // every vote targets a fresh AgentId key, so this uses `.put()` (upsert) instead.
    votes' = votes.put(a, v),
    author' = author, council' = council, tier' = tier, verification' = verification,
    weight' = weight, familyOf' = familyOf, outcome' = outcome,
  }
  def approveWeight = votes.keys().filter(a => votes.get(a) == Approve).fold(0, (s,a) => s + weight.get(a))
  def totalWeight   = votes.keys().fold(0, (s,a) => s + weight.get(a))
  def quorumMet     = votes.keys().size() * 2 > council.size()   // >half participate
  // NB: a `val` inside `all{}` scopes only over the single next comma item (confirmed in
  // Tasks 3/7/8) — `pass` is needed by BOTH `outcome'` and would otherwise leak into the
  // trailing pass-through items, so every statement depending on it is wrapped in a nested
  // `all{}` right after the `val`.
  action decide: bool = all {
    outcome == Pending, verification != NotRun, verification != Refuted,
    votes.keys().size() == council.size(),         // all cast (blind round complete)
    val pass = quorumMet and (if (tier == Constitutional) passesConstitutional(approveWeight, totalWeight)
                              else passesOrdinary(approveWeight, totalWeight))
    all {
      outcome' = if (pass) Committed else Rejected,
      author' = author, council' = council, tier' = tier, verification' = verification,
      votes' = votes, weight' = weight, familyOf' = familyOf,
    }
  }
  // Always-enabled no-op so `step` never deadlocks once the proposal has reached a terminal
  // outcome (Committed/Rejected) — every other action's guard is then disabled (verify
  // requires NotRun, castVote requires an unfilled council seat, decide requires Pending).
  // Apalache's `quint verify` treats a stuck `step` relation as a reportable deadlock, which
  // is a model-completeness artifact of the bounded funnel reaching its terminal state, not a
  // safety violation. `idle` keeps every state reachable for exploration without ever
  // weakening proposerNotDisposer/verifyBeforeVote/refutedNeverCommits/quorumAndThreshold.
  action idle: bool = all {
    author' = author, council' = council, tier' = tier, verification' = verification,
    votes' = votes, weight' = weight, familyOf' = familyOf, outcome' = outcome,
  }
  action step = any {
    nondet r = Set(Refuted, Certified, Residual).oneOf() verify(r),
    nondet a = council.oneOf() (nondet v = Set(Approve, Reject, Abstain).oneOf() castVote(a, v)),
    decide,
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

  // --- scenarios ---
  // A Refuted verification report immediately rejects the proposal and permanently disables
  // voting — verify-before-vote holds even in the "never got to vote" branch.
  run refutedRejectsNoVoteTest =
    init.then(verify(Refuted))
        .then(all {
          assert(outcome == Rejected),
          author' = author, council' = council, tier' = tier, verification' = verification,
          votes' = votes, weight' = weight, familyOf' = familyOf, outcome' = outcome,
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
        })
}
