// # VERIFY: corrInjective, answerClearsOwnNode, gatingConsistent
// # VERIFY-MAX-STEPS: 6
module mailbox {
  import base.* from "./base"

  type QState = Draft | Open | Answered | Closed
  type Question = { id: int, gatesNode: int, recipient: UserId, blastHigh: bool, qstate: QState }

  var questions: int -> Question
  var openIndex: Set[(UserId, int)]     // (user, qid) blocking set
  var corr: int -> int                  // CorrelationToken -> QuestionId (injective)
  var nodeBlocked: int -> bool
  var mayAnswer: (UserId, int) -> bool  // authz: may this user answer this question
  var nextTok: int

  action init = all {
    questions' = Map(), openIndex' = Set(), corr' = Map(), nodeBlocked' = Map(),
    mayAnswer' = Map(), nextTok' = 1,
  }

  // Quint 0.24.0's stdlib has no `getOrElse`/`mapGetDefault` (see builtin.qnt: only
  // `get`/`set`/`keys`/`setBy` exist for maps) — default-lookup helpers below use an
  // explicit `.keys().in()` guard instead.
  def mayAnswerGet(u: UserId, q: int): bool =
    if ((u, q).in(mayAnswer.keys())) mayAnswer.get((u, q)) else false
  def nodeBlockedGet(n: int): bool =
    if (n.in(nodeBlocked.keys())) nodeBlocked.get(n) else false

  // Is some OTHER (id != selfQ) question still Open and gating `node`, evaluated against the
  // PRE-image `questions` map (i.e. before the current transition's questions' update lands)?
  // Needed by deliverAnswer below: excluding selfQ matters because at guard-eval time selfQ's
  // own qstate in `questions` is still Open (its Answered update is only visible in questions').
  def anotherOpenGate(node: int, selfQ: int): bool =
    questions.keys().exists(q2 => q2 != selfQ and questions.get(q2).gatesNode == node and questions.get(q2).qstate == Open)

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
    }
  }
  // deliver via a correlation token; authz on the RESOLVED user, not the token alone
  //
  // FINDING (recorded for Task 11): the brief's original body unconditionally set
  // `nodeBlocked' = nodeBlocked.set(gatesNode, false)`. `quint verify` found a genuine
  // counterexample against `gatingConsistent`: with two Open questions gating the SAME
  // node, answering one blindly cleared nodeBlocked for that node even though the other
  // question was still Open and still gating it. Fixed below to only clear the block when
  // no other Open question still gates the node (anotherOpenGate), matching what
  // answerClearsOwnNode already assumed of the design.
  action deliverAnswer(tok: int, user: UserId): bool = all {
    tok.in(corr.keys()),
    val q = corr.get(tok)
    all {
      questions.get(q).qstate == Open,
      mayAnswerGet(user, q),                         // token match alone never authorizes
      questions' = questions.set(q, { ...questions.get(q), qstate: Answered }),
      openIndex' = openIndex.exclude(Set((questions.get(q).recipient, q))),
      nodeBlocked' = nodeBlocked.set(questions.get(q).gatesNode, anotherOpenGate(questions.get(q).gatesNode, q)),
      corr' = corr, nextTok' = nextTok, mayAnswer' = mayAnswer,
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
  }
  action step = any {
    nondet q = Set(1,2).oneOf() (nondet n = Set(10,20).oneOf()
      (nondet u = Set(1,2).oneOf() (nondet h = Set(true,false).oneOf() askQuestion(q, n, u, h)))),
    all {
      corr.keys().size() > 0,
      nondet t = corr.keys().oneOf() (nondet u = Set(1,2).oneOf() deliverAnswer(t, u)),
    },
    idle,
  }

  // --- invariants ---
  val corrInjective = corr.keys().forall(a => corr.keys().forall(b =>
    (corr.get(a) == corr.get(b)) implies (a == b)))
  def otherOpenGates(node: int): bool =
    questions.keys().exists(q2 => questions.get(q2).gatesNode == node and questions.get(q2).qstate == Open)
  val answerClearsOwnNode = questions.keys().forall(q =>
    questions.get(q).qstate == Answered implies (not(nodeBlockedGet(questions.get(q).gatesNode))
      or otherOpenGates(questions.get(q).gatesNode)))
  val gatingConsistent = nodeBlocked.keys().forall(n =>
    nodeBlocked.get(n) == questions.keys().exists(q => questions.get(q).gatesNode == n and questions.get(q).qstate == Open))

  // --- scenarios ---
  run answerRoutesToOwnQuestionTest =
    init.then(askQuestion(1, 10, 1, false)).then(deliverAnswer(1, 1))
        .then(all {
          assert(questions.get(1).qstate == Answered and not(nodeBlocked.get(10))),
          questions' = questions, openIndex' = openIndex, corr' = corr, nodeBlocked' = nodeBlocked,
          mayAnswer' = mayAnswer, nextTok' = nextTok,
        })
  // leaked correlation token used by an UNauthorized user is rejected
  run leakedTokenRejectedTest =
    init.then(askQuestion(1, 10, 1, true))
        .then(deliverAnswer(1, 2).fail())   // user 2 lacks may_answer on q1
}
