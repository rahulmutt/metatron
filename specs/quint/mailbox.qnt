// # VERIFY: corrInjective, answerClearsOwnNode, gatingConsistent, bindingIs1to1, precedenceNoDeadlock
// # VERIFY-MAX-STEPS: 6
module mailbox {
  import base.* from "./base"

  type QState = Draft | Open | Answered | Closed
  type Question = { id: int, gatesNode: int, recipient: UserId, blastHigh: bool, qstate: QState }

  // Channel taxonomy (06 §2.6/§4.5): the pluggable external boundary. Each channel is an
  // adapter that authenticates a channel-native sender and resolves it to an ExternalUserId
  // via the 08-owned binding table (06 §3.9).
  type ChannelKind = Api | Slack | Telegram | Sms

  var questions: int -> Question
  var openIndex: Set[(UserId, int)]     // (user, qid) blocking set
  var corr: int -> int                  // CorrelationToken -> QuestionId (injective)
  var nodeBlocked: int -> bool
  var mayAnswer: (UserId, int) -> bool  // authz: may this user answer this question
  var nextTok: int
  // (channel, native_id) -> ExternalUserId. Binding table owned by 08 (§3.9), resolved by
  // each Channel Adapter. Task 8: 1:1 identity binding + cross-user precedence.
  var bindingTable: (ChannelKind, int) -> UserId
  var rank: UserId -> int               // authorization rank; total-ordered precedence (§3.7)

  action init = all {
    questions' = Map(), openIndex' = Set(), corr' = Map(), nodeBlocked' = Map(),
    mayAnswer' = Map(), nextTok' = 1,
    // Fixture enriched for non-vacuous bindIs1to1 (see invariant note below):
    //  - (Api,1)->1 and (Api,2)->3: two DISTINCT native ids in the SAME channel Api mapping
    //    to distinct principals -> makes per-channel injectivity a COMPARABLE, exercised pair
    //    (the channel-match conjunct fires; a wrong (Api,2)->1 binding would FALSIFY it).
    //  - (Api,1)->1 and (Telegram,1)->1: the SAME principal (user 1) legitimately bound on
    //    TWO DIFFERENT channels -> this is exactly the cross-channel case the design permits
    //    (06 §3.9 / decision 3: linking several channel identities onto one principal), which
    //    GLOBAL injectivity would wrongly reject. Confirms per-channel (not global) is correct.
    bindingTable' = Map((Api, 1) -> 1, (Api, 2) -> 3, (Slack, 1) -> 2, (Telegram, 1) -> 1),
    // rank enriched with user 3 at the SAME rank (2) as user 1 so precedenceNoDeadlock
    // genuinely exercises the EQUAL-RANK tie-break branch over two DISTINCT users (1,3) —
    // otherwise (with all-distinct ranks) the tie-break is only reachable at u1==u2 and an
    // asymmetric tie-break would go undetected. Mutating `else if (u1<u2) u1 else u2` to a
    // first-arg-wins rule now falsifies precedenceNoDeadlock (verified by mutation).
    rank' = Map(1 -> 2, 2 -> 1, 3 -> 2),
  }

  // Quint 0.24.0's stdlib has no `getOrElse`/`mapGetDefault` (see builtin.qnt: only
  // `get`/`set`/`keys`/`setBy` exist for maps) — default-lookup helpers below use an
  // explicit `.keys().in()` guard instead.
  def mayAnswerGet(u: UserId, q: int): bool =
    if ((u, q).in(mayAnswer.keys())) mayAnswer.get((u, q)) else false
  def nodeBlockedGet(n: int): bool =
    if (n.in(nodeBlocked.keys())) nodeBlocked.get(n) else false

  // Is some OTHER (id != selfQ) question still ACTIVELY gating `node` — Open (awaiting an
  // answer) OR Closed (a high-stakes safe-hold from timeoutHighStakes, which retains the
  // block by design, §3.7 line 132) — evaluated against the PRE-image `questions` map (i.e.
  // before the current transition's questions' update lands)? Needed by deliverAnswer below:
  // excluding selfQ matters because at guard-eval time selfQ's own qstate in `questions` is
  // still Open (its Answered update is only visible in questions').
  //
  // Generalized from Open-only to Open-or-Closed (Task 8 fix, see gatingConsistent below):
  // Closed arises ONLY from timeoutHighStakes' safe-hold, so it is model-wide a second,
  // legitimate block-retaining reason alongside Open. This is a conservative extension: when
  // no Closed question is present (Task 7's entire reachable space), the predicate reduces
  // exactly to its prior Open-only form.
  def anotherActiveGate(node: int, selfQ: int): bool =
    questions.keys().exists(q2 => q2 != selfQ and questions.get(q2).gatesNode == node
      and (questions.get(q2).qstate == Open or questions.get(q2).qstate == Closed))

  // NB: a `val` inside `all{}` only scopes over the SINGLE next comma item, not the whole
  // rest of the chain (confirmed empirically against Quint 0.24.0 — the brief's flat
  // `val tok = nextTok  questions' = ...,  corr' = corr.set(tok, q), ...` form fails
  // typecheck with "Name 'tok' not found" on every item after the first). Fix: wrap
  // every statement that needs the bound name in one nested `all{}` right after the `val`.
  //
  // NB2: `Map.set(k, v)` requires `k` to already be a key of the map (0.24.0 stdlib doc:
  // "with the key k mapped to v if k.in(keys(m))") — using it on a genuinely NEW key is a
  // runtime QNT507 ("Called 'set' with a non-existing key"), caught by `quint test`. Every
  // assignment below targets a fresh key (q, tok, and node/user-pair on first mention), so
  // this action uses `.put()` (upsert) throughout instead of `.set()`.
  action askQuestion(q: int, node: int, user: UserId, high: bool): bool = all {
    not(q.in(questions.keys())),
    val tok = nextTok
    all {
      questions' = questions.put(q, { id: q, gatesNode: node, recipient: user, blastHigh: high, qstate: Open }),
      openIndex' = openIndex.union(Set((user, q))),
      corr' = corr.put(tok, q), nextTok' = nextTok + 1,
      nodeBlocked' = nodeBlocked.put(node, true),
      mayAnswer' = mayAnswer.put((user, q), true),   // owner may answer; others default false
      bindingTable' = bindingTable, rank' = rank,
    }
  }
  // deliver via a correlation token; authz on the RESOLVED user, not the token alone
  //
  // FINDING (recorded for Task 11): the brief's original body unconditionally set
  // `nodeBlocked' = nodeBlocked.set(gatesNode, false)`. `quint verify` found a genuine
  // counterexample against `gatingConsistent`: with two Open questions gating the SAME
  // node, answering one blindly cleared nodeBlocked for that node even though the other
  // question was still Open and still gating it. Fixed below to only clear the block when
  // no other ACTIVE (Open or safe-held Closed) question still gates the node
  // (anotherActiveGate), matching what answerClearsOwnNode already assumes of the design.
  action deliverAnswer(tok: int, user: UserId): bool = all {
    tok.in(corr.keys()),
    val q = corr.get(tok)
    all {
      questions.get(q).qstate == Open,
      mayAnswerGet(user, q),                         // token match alone never authorizes
      questions' = questions.set(q, { ...questions.get(q), qstate: Answered }),
      openIndex' = openIndex.exclude(Set((questions.get(q).recipient, q))),
      nodeBlocked' = nodeBlocked.set(questions.get(q).gatesNode, anotherActiveGate(questions.get(q).gatesNode, q)),
      corr' = corr, nextTok' = nextTok, mayAnswer' = mayAnswer,
      bindingTable' = bindingTable, rank' = rank,
    }
  }
  // Always-enabled no-op so `step` never deadlocks once the bounded {1,2} question-id pool
  // is exhausted (both asked and answered) — Apalache's `quint verify` treats a stuck `step`
  // relation as a reportable deadlock, which is a model-completeness artifact of the small
  // fixed id pool, not a safety violation. `idle` keeps every state reachable for exploration
  // without ever weakening corrInjective/answerClearsOwnNode/gatingConsistent.
  action idle: bool = all {
    questions' = questions, openIndex' = openIndex, corr' = corr, nodeBlocked' = nodeBlocked,
    mayAnswer' = mayAnswer, nextTok' = nextTok,
    bindingTable' = bindingTable, rank' = rank,
  }

  // High-stakes bounded-timeout fallback (06 §3.7 / line 132): a high-stakes Question is
  // NEVER silently auto-defaulted. On escalation-window expiry the gated node "holds and
  // degrades safely" — it STAYS Blocked (never proceeds on the irreversible action) while
  // the Question resolves to a defined bounded fallback (Closed) rather than staying Open
  // forever. This is the liveness floor: no high-stakes path blocks indefinitely.
  //
  // FINDING (resolved, see task-8-report.md "Fix: complete gatingConsistent..."): keeping the
  // node blocked while the Question leaves Open is INTENTIONAL per the design, and Closed is a
  // SECOND, legitimate block-retaining reason alongside Open. Task 7's `gatingConsistent`
  // biconditional (nodeBlocked[n] <=> some Open question gates n) was INCOMPLETE, not this
  // action's fault — excluding the action from `step` would hide a genuine reachable bug
  // (a safe-held Closed question's block being wrongly cleared by an unrelated deliverAnswer
  // on a sibling Open question). Fix: generalize gatingConsistent, anotherActiveGate (used by
  // deliverAnswer), and otherOpenGates (used by answerClearsOwnNode) to count Open OR Closed
  // gating questions — a conservative extension of Task 7's Open-only invariants. This action
  // is now part of the verified `step` any{} below.
  action timeoutHighStakes(q: int): bool = all {
    q.in(questions.keys()), questions.get(q).qstate == Open, questions.get(q).blastHigh,
    questions' = questions.set(q, { ...questions.get(q), qstate: Closed }),
    openIndex' = openIndex.exclude(Set((questions.get(q).recipient, q))),
    nodeBlocked' = nodeBlocked, corr' = corr, nextTok' = nextTok, mayAnswer' = mayAnswer,
    bindingTable' = bindingTable, rank' = rank,
  }

  // Cross-user arbitration (06 §3.7): when two authorized principals contend, a deterministic
  // precedence order (precedenceWinner) always yields a single winner, so arbitration
  // terminates rather than deadlocking. In this bounded safety model arbitration is a
  // deterministic query over `rank`; its surfacing of the loser as a Notification and its
  // re-entry as a fresh instruction are out of scope, so the transition is a guarded stutter.
  action arbitrate(u1: UserId, u2: UserId): bool = all {
    u1.in(rank.keys()), u2.in(rank.keys()),
    questions' = questions, openIndex' = openIndex, corr' = corr, nodeBlocked' = nodeBlocked,
    mayAnswer' = mayAnswer, nextTok' = nextTok, bindingTable' = bindingTable, rank' = rank,
  }

  action step = any {
    nondet q = Set(1,2).oneOf() (nondet n = Set(10,20).oneOf()
      (nondet u = Set(1,2).oneOf() (nondet h = Set(true,false).oneOf() askQuestion(q, n, u, h)))),
    all {
      corr.keys().size() > 0,
      nondet t = corr.keys().oneOf() (nondet u = Set(1,2).oneOf() deliverAnswer(t, u)),
    },
    all {
      questions.keys().size() > 0,
      nondet q = questions.keys().oneOf() timeoutHighStakes(q),
    },
    idle,
  }

  // --- invariants ---
  val corrInjective = corr.keys().forall(a => corr.keys().forall(b =>
    (corr.get(a) == corr.get(b)) implies (a == b)))
  // Generalized (Task 8 fix) from Open-only to Open-or-Closed: a safe-held Closed
  // high-stakes question (timeoutHighStakes) is a second legitimate block-retaining gate,
  // just like an Open one. Conservative extension of Task 7's form — when no Closed question
  // is present this reduces exactly to the prior `qstate == Open` predicate.
  def otherOpenGates(node: int): bool =
    questions.keys().exists(q2 => questions.get(q2).gatesNode == node
      and (questions.get(q2).qstate == Open or questions.get(q2).qstate == Closed))
  val answerClearsOwnNode = questions.keys().forall(q =>
    questions.get(q).qstate == Answered implies (not(nodeBlockedGet(questions.get(q).gatesNode))
      or otherOpenGates(questions.get(q).gatesNode)))
  // Generalized (Task 8 fix): nodeBlocked[n] <=> some question gating n is Open OR Closed
  // (safe-held). Closed arises ONLY from timeoutHighStakes' high-stakes safe-hold, so
  // "Closed => safe-held" holds model-wide, making Closed a sound second block-reason
  // alongside Open. Conservative extension: reduces to Task 7's Open-only biconditional
  // whenever no Closed question exists.
  val gatingConsistent = nodeBlocked.keys().forall(n =>
    nodeBlocked.get(n) == questions.keys().exists(q => questions.get(q).gatesNode == n
      and (questions.get(q).qstate == Open or questions.get(q).qstate == Closed)))

  // --- Task 8: 1:1 binding + cross-user precedence ---

  // Deterministic winner between two principals contending the same node/shared goal (§3.7):
  //  (1) higher authorization rank wins;
  //  (2) on equal rank, lower id wins (a symmetric, computable proxy for first-committed).
  def precedenceWinner(u1: UserId, u2: UserId): UserId =
    if (rank.get(u1) > rank.get(u2)) u1
    else if (rank.get(u2) > rank.get(u1)) u2
    else if (u1 < u2) u1 else u2

  // bindingIs1to1 — PER-CHANNEL injectivity. Intent (06 §3.9, §3.8, decision 3): a
  // channel-native identity resolves UNAMBIGUOUSLY to one ExternalUserId, and within a single
  // channel two distinct native ids must NOT collapse onto the same principal (that would
  // break routing / enable a false-merge). We use PER-channel, not GLOBAL, injectivity because
  // the design explicitly PERMITS the same ExternalUserId to be bound on several DIFFERENT
  // channels (the ChannelIdentity->ExternalUserId indirection exists precisely to later link
  // one human's Slack/Telegram/Api identities onto one principal, §3.9 decision 3); global
  // injectivity would wrongly forbid that legitimate state. (The brief's literal form
  //  `(a==b) or (get(a)!=get(b)) or (a._1!=b._1) or (a._2!=b._2)` is a tautology over distinct
  //  tuple keys — replaced with this genuine, falsifiable injectivity property per directive.)
  val bindingIs1to1 = bindingTable.keys().forall(a => bindingTable.keys().forall(b =>
    (a._1 == b._1 and bindingTable.get(a) == bindingTable.get(b)) implies a == b))

  // precedenceNoDeadlock — the tie-break is a CONSISTENT total order: the winner is
  // independent of argument order, so there is no A-beats-B-beats-A cycle and arbitration
  // always terminates with exactly one winner (§3.7 "deterministic, deadlock-free"). This is
  // genuinely falsifiable (a tie-break that returned the FIRST argument on ties would break
  // order-independence) and non-vacuous over the ranked fixture. (The brief's literal form
  //  `w == u1 or w == u2` is a tautology — precedenceWinner returns u1 or u2 by construction;
  //  replaced with this real no-deadlock property per directive.)
  val precedenceNoDeadlock = rank.keys().forall(u1 => rank.keys().forall(u2 =>
    precedenceWinner(u1, u2) == precedenceWinner(u2, u1)))

  // --- scenarios ---
  run answerRoutesToOwnQuestionTest =
    init.then(askQuestion(1, 10, 1, false)).then(deliverAnswer(1, 1))
        .then(all {
          assert(questions.get(1).qstate == Answered and not(nodeBlocked.get(10))),
          questions' = questions, openIndex' = openIndex, corr' = corr, nodeBlocked' = nodeBlocked,
          mayAnswer' = mayAnswer, nextTok' = nextTok,
          bindingTable' = bindingTable, rank' = rank,
        })
  // leaked correlation token used by an UNauthorized user is rejected
  run leakedTokenRejectedTest =
    init.then(askQuestion(1, 10, 1, true))
        .then(deliverAnswer(1, 2).fail())   // user 2 lacks may_answer on q1

  // Liveness: a never-answering oracle on a high-stakes Question still reaches a bounded
  // fallback (Closed), never Open forever — and the gated node HOLDS (stays blocked =
  // degrade-safely), never proceeding on the irreversible action (§3.7 line 132).
  run neverAnsweredResolvesTest =
    init.then(askQuestion(1, 10, 1, true)).then(timeoutHighStakes(1))
        .then(all {
          assert(questions.get(1).qstate == Closed and nodeBlockedGet(10)),
          questions' = questions, openIndex' = openIndex, corr' = corr, nodeBlocked' = nodeBlocked,
          mayAnswer' = mayAnswer, nextTok' = nextTok,
          bindingTable' = bindingTable, rank' = rank,
        })

  // Cross-user precedence deterministically breaks the tie: user 1 has rank 2 > user 2's
  // rank 1, so user 1 wins. `arbitrate` fires first to exercise the arbitration transition.
  run precedenceBreaksTieTest =
    init.then(arbitrate(1, 2))
        .then(all {
          assert(precedenceWinner(1, 2) == 1),
          questions' = questions, openIndex' = openIndex, corr' = corr, nodeBlocked' = nodeBlocked,
          mayAnswer' = mayAnswer, nextTok' = nextTok,
          bindingTable' = bindingTable, rank' = rank,
        })
}
