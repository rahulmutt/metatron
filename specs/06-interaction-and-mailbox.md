# Metatron — Interaction Plane & Mailbox

> **Status:** Research architecture specification (v0.1)
> **Plane:** Interaction (top of the stack in `00-overview.md` §2).
> **Owning role:** **Guardian** agents (the user's advocate; *propose* power, never *vote*).
> **Depends on:** `00-overview.md` (canonical vocabulary & types — when this spec disagrees with it, the overview wins). References `01-state-model.md` (progress layer, open questions), `02-consensus.md` (typed `Proposal`, consensus escalation), `03-control-loop.md` (`ErrorVector`, setpoint, control-loop escalation), `08-trust-and-security.md` (external identity vs `AgentId`).

---

## 1. Purpose

The **Interaction plane** is the boundary between Metatron and the external world. Everything the user knows about the system, and everything the system knows about the user's intent, flows through this one plane. It exists so that the rest of Metatron — the deliberative, control-theoretic core — can treat *user intent* as a clean, typed, versioned input rather than a stream of free text.

Concretely, the Interaction plane is responsible for five things, all owned by **Guardian** agents:

1. **Accept user INSTRUCTIONS.** Take in raw, possibly under-specified natural-language directives from the external user.
2. **NORMALIZE an instruction into a GOAL.** Turn an instruction into a typed, schema-validated `Goal` artifact — the canonical statement of what the user wants.
3. **Define the SETPOINT / TARGET STATE.** The normalized goal *is* the reference signal the PID controller (`03`) steers toward. Goal → setpoint is the contract between the Interaction plane and the Governance plane.
4. **Detect AMBIGUITY** in an instruction or in any downstream work derived from it, and resolve it under a strict two-step gate (auto-resolve from existing context, else escalate to the user).
5. **Author typed PROPOSALS** (`Proposal`, defined in `00` §7, elaborated in `02`). Guardians are the *only* role with propose power; every user-originated change to the world-model enters governance as a Guardian-authored proposal.

The plane also owns **the Mailbox**: the single bidirectional channel between the system and the user. Outbound it carries **questions** and **notifications**; inbound it carries **answers** and **new instructions**. The Mailbox is also the boundary at which *internal escalations surface to the human*: consensus escalations from `02` and control-loop escalations from `03` both reach the user as mailbox items.

**Design tenet (from `00` §6).** The user is an external, unreliable, high-latency oracle. We treat their attention as the scarcest resource in the system. The plane is engineered to *minimize* the number of questions that reach them — first by normalizing aggressively, then by resolving ambiguity from existing context before ever interrupting them — and to make every question that does reach them load-bearing: some specific unit of work is *blocked* on it.

**Non-goals.** The Interaction plane does not decide anything: Guardians propose, the Genesis council disposes (`02`). It does not execute work (`04`). It does not measure (`07`). It does not store the canonical history — it *writes into* the progress layer (`01`) via proposals, but the Merkle DAG is the State plane's concern.

---

## 2. Concepts

### 2.1 The intent pipeline

The plane transforms raw intent into governance inputs through a fixed pipeline. Each stage produces a typed artifact; nothing crosses a stage boundary as free text.

```
Instruction ──normalize──▶ Goal ──derive──▶ Setpoint ──┐
 (raw NL)                  (typed)          (target     │
     │                        │              state)     ▼
     │                        │                     PID loop (03)
     │                        ▼
     └────detect─────▶ Ambiguity ──gate──▶ {auto-resolved | Question}
                                                              │
                                                       Mailbox (out)
                                                              │
                                                            user
                                                              │
                                                       Mailbox (in)
                                                              ▼
                                                          Answer ──▶ unblock
```

| Concept | Meaning |
|---------|---------|
| **Instruction** | A raw natural-language directive from the external user. The only free-text input the system accepts. Immutable once received; assigned an `InstructionId`. |
| **Goal** | The typed, schema-validated normalization of an instruction: *what the user wants*, expressed as a target over the progress layer. The canonical statement of intent. |
| **Setpoint / Target state** | The goal projected into the controlled-variable space of the PID controller (`03`). The reference signal the closed loop steers toward. One goal yields one setpoint contribution. |
| **Ambiguity** | A point in an instruction, goal, or derived unit of work where more than one materially-different interpretation is admissible, *and* the choice affects the outcome. Detected by any agent; adjudicated by Guardians. |
| **Question** | A typed request for user input that has survived the two-step resolution gate. Surfaced via the Mailbox. Linked to the progress-layer node it gates. |
| **Answer** | The user's typed response to a Question. Unblocks the gated work and is recorded as a new user input. |
| **Notification** | An outbound, *non-blocking* message from the system to the user (status, escalation summary, completion). The user is not required to respond. |
| **Mailbox** | The bidirectional channel carrying Questions/Notifications out and Answers/Instructions in. The external API surface (§4). |

### 2.2 Guardian responsibilities recap

Guardians sit at the top of the checks-and-balances cycle (`00` §3): **Guardians propose → Genesis disposes**. Within the Interaction plane a Guardian is a state machine that owns one user's intent thread (multi-user is parked, §5). It:

- ingests Instructions and normalizes them to Goals;
- maintains the mapping `Goal → Setpoint` consumed by `03`;
- receives ambiguity reports from *any* agent in the system (a Worker hitting an unclear requirement, a Genesis member unsure how to vote, the PID controller unable to interpret an error) and runs the resolution gate (§2.3);
- owns the Mailbox: emits Questions/Notifications, ingests Answers/Instructions;
- authors `Proposal`s — to seed the progress layer from a new Goal, to record an Answer's resolution, to relay an escalation as a concrete decision for the user.

Critically, **Guardians do not vote and do not execute.** Their advocacy is expressed entirely as *proposals* and *questions*. This preserves the `00` §3 separation of powers: the user's advocate cannot also be the body that disposes of the user's request.

### 2.3 The ambiguity resolution gate (two-step)

This is the heart of the plane and is honored precisely from the bootstrap. When *any* agent encounters ambiguity it **must not proceed** on the ambiguous unit of work. But it also must not reflexively interrupt the user. Instead, ambiguity passes through a two-step gate:

```
            ┌───────────────────────────────────────────────┐
 ambiguity  │  STEP 1 — AUTO-RESOLVE FROM EXISTING CONTEXT   │
 detected   │  Consult the council/Guardians: do the user's  │
 ──────────▶│  EXISTING inputs already resolve this?         │
   (work     │   (prior instructions, answered questions,     │
   pauses)   │    the active Goal, accepted commits)          │
            └───────────────┬───────────────────────────────┘
                            │
                ┌───────────┴───────────┐
            resolved?                 not resolved?
                │                         │
                ▼                         ▼
       record Resolution         ┌─────────────────────────────┐
       (proposal),               │ STEP 2 — ESCALATE TO USER   │
       UNBLOCK work,             │ Author a Question, link it  │
       no user interrupt         │ to the gated progress node, │
                                 │ emit to Mailbox.            │
                                 │ Work BLOCKS until answered. │
                                 └─────────────────────────────┘
```

- **Step 1 — auto-resolve from existing context.** Before any question reaches the human, the system consults the **council / Guardians** to check whether the user's *existing inputs* already determine the answer. "Existing inputs" means: prior instructions, previously answered questions, the active Goal and its setpoint, and accepted commits in the progress layer. This is a deliberative read-only query — it produces a *candidate resolution* with a confidence — and it is itself decorrelation-friendly (multiple Guardians/Genesis members can be consulted; see `02`). If the existing context resolves the ambiguity above a confidence threshold, the resolution is recorded (as a Guardian proposal so it enters the immutable history) and the blocked work is **unblocked without ever interrupting the user**.
- **Step 2 — escalate to the user.** Only if Step 1 fails does a `Question` reach the human. The Guardian authors a typed Question, **links it to the specific progress-layer node it gates**, and emits it on the Mailbox. The gated work — and only the gated work — **blocks until answered** (§2.4). Unrelated work continues.

The gate is what makes user attention scarce-by-construction: the human is interrupted only for ambiguities that their own prior inputs genuinely cannot settle.

### 2.4 Blocking-until-answered

Blocking is **scoped, not global**. A Question gates a *specific* unit of work, represented as an edge from the Question to the progress-layer node it depends on. While the Question is open:

- the gated node (and its transitive dependents in the task graph) is in a `Blocked` state and does not advance;
- every other node in the progress layer continues normally;
- the PID controller (`03`) sees the blocked node as *stalled-by-design*, not as divergence or failure — a blocked node contributes to a distinct `blocked` accounting, not to the `progress` error term as drift (see §6 and `03`).

When the Answer arrives, the Guardian records it (as a proposal that writes the resolution into the progress layer), the gating edge is removed, the node transitions `Blocked → Ready`, and execution resumes. The Answer is also retained as a new "existing input," so future Step-1 auto-resolutions can draw on it — answering a question once should prevent the system from ever asking an equivalent question again.

### 2.5 Escalations as a Mailbox boundary

The Mailbox is the *single* place internal escalations become human-visible:

- **Consensus escalations (`02`).** When the council cannot reach the acceptance threshold, or dispersion is high enough that deliberation does not converge, the decision escalates. A Guardian renders the deadlock as a user-facing item: a Question if a human choice can break it, or a Notification if it is merely informational.
- **Control-loop escalations (`03`).** When the PID controller detects an error it cannot drive down with available control actions (e.g. the goal is infeasible under the cost budget, or progress has flatlined), it escalates. A Guardian renders this as a Question ("relax the deadline or cut scope?") or Notification.

In both cases the Interaction plane is doing its job: translating an internal condition into the typed, scarce, blocking-or-not vocabulary the user understands.

---

## 3. Detailed design

### 3.1 The Guardian intake state machine

Each Instruction is processed by a Guardian as follows:

```
RECEIVED ──normalize──▶ NORMALIZED ──ambiguity?──▶ GATED ──┬─[Step1 resolves]─▶ PROPOSED
   │                        │                              │
   │                        └──[no ambiguity]──────────────┘
   │                                                       └─[Step2]─▶ AWAITING_USER ──answer──▶ PROPOSED
   ▼
 (InstructionId assigned, persisted, ack'd on the Mailbox)
```

1. **RECEIVED.** The Instruction is assigned an `InstructionId`, time-stamped with `LogicalTime` (`01`), and acknowledged. It is immutable.
2. **NORMALIZED.** The Guardian produces a candidate `Goal`. Normalization is an LLM-backed step but its *output is typed* (per `00` §6.1, constrain the output space): the Guardian must emit a schema-valid `Goal`, not prose. The instruction text is preserved on the Goal as provenance.
3. **Ambiguity check.** The Guardian scans the Goal for ambiguity (and downstream agents may later raise ambiguity against work derived from it). Each ambiguity enters the two-step gate (§2.3).
4. **GATED → resolution.** Step 1 may auto-resolve. Otherwise Step 2 surfaces a Question and the Guardian parks the affected work in `AWAITING_USER`.
5. **PROPOSED.** Once the Goal is unambiguous (or its ambiguities are resolved/parked such that *some* work can proceed), the Guardian authors `Proposal`s that seed the progress layer with the goal's task structure and register the setpoint. From here the Governance plane takes over (`02`).

Note normalization and ambiguity resolution are *interleaved*, not strictly sequential: a Goal may be partially proposed (the unambiguous part proceeds) while one sub-aspect blocks on a Question.

### 3.2 Goal → Setpoint derivation

The Goal is the user-facing statement; the **Setpoint** is its projection into the PID controller's controlled-variable space (`03`). The Guardian computes and maintains this projection:

- **Progress target.** The goal's completion criteria define the `progress` reference: `progress_error = 0` exactly when the goal's acceptance predicate holds over the progress layer.
- **Constraints become bounds.** Budget/deadline/quality constraints on the Goal map onto the `cost` and `latency` reference bands of the `ErrorVector` (`00` §7).
- **Stability.** The setpoint is *versioned*: a new Instruction that revises intent produces a new Goal version and a new setpoint, applied at a `LogicalTime` boundary so the controller sees a clean reference step rather than a mid-flight mutation.

The mapping is owned by the Guardian but *consumed* by `03`; the schema of the setpoint contribution lives here (§4.4) and is referenced by `03`.

### 3.3 Mailbox internals

The Mailbox is modeled as two append-only, content-addressed logs plus a derived index:

- **Outbound log** — Questions and Notifications, in emission order.
- **Inbound log** — Answers and Instructions, in arrival order.
- **Open-question index** — the derived set of Questions with no matching Answer, each carrying its gating edge into the progress layer.

```
        SYSTEM                         MAILBOX                        USER
          │                              │                             │
          │  emit(Question q)            │                             │
          ├─────────────────────────────▶ append outbound, index open │
          │                              │   notify (poll/subscribe) ──▶│
          │                              │                             │ (thinks)
   work gated on q: BLOCKED              │                             │
   other work: continues                │   answer(q, ...) ◀───────────┤
          │                              ◀─────────────────────────────┤
          │  deliver(Answer a)           │ append inbound, close q     │
          ◀─────────────────────────────┤                             │
   record resolution (Proposal)         │                             │
   unblock gated node                   │                             │
          │                              │                             │
```

Because the logs are append-only and content-addressed, the entire interaction history is replayable and auditable, consistent with `00` §6.6 (record everything immutably). Answers and resolutions also land in the progress layer via proposals, so the *decisions* live in the Merkle DAG while the *conversation* lives in the Mailbox logs; the two are cross-linked by `InstructionId` / `QuestionId` / progress-node `Hash`.

### 3.4 Question lifecycle & the gating edge

```
        ┌────────┐   surfaced    ┌────────┐   answered   ┌──────────┐
        │ DRAFT  │──────────────▶│  OPEN  │─────────────▶│ ANSWERED │
        └────────┘  (Step 2)     └────────┘              └──────────┘
                                     │  superseded /          ▲
                                     │  auto-resolved-late     │ retained as
                                     ▼                         │ "existing input"
                                 ┌──────────┐                  │
                                 │  CLOSED  │──────────────────┘
                                 └──────────┘
```

A Question carries a **gating edge**: `gates: Hash` pointing at the progress-layer node it blocks (the canonical "open question" object lives in the progress layer per `01`; the Mailbox `Question` is its user-facing projection). The two are kept in correspondence:

- creating a Question marks its target progress node `Blocked`;
- answering or closing a Question clears the block;
- a Question may be **superseded** if a later auto-resolution (Step 1, drawing on a newer input) settles it before the user answers — in which case it is `CLOSED` with reason `auto_resolved_late` and a Notification is sent so the user is not left answering a stale question.

### 3.5 Worked sequence — ambiguity from a Worker

```
Worker        Guardian                Council/Guardians       Mailbox        User
  │  "spec says 'fast' — fast=latency or throughput?"          │             │
  ├──ambiguity report──▶│                                      │             │
  │   (work pauses)     │                                      │             │
  │                     ├──Step1: consult──▶│                  │             │
  │                     │   "existing inputs?"                 │             │
  │                     │◀──no prior signal──┤                 │             │
  │                     │   (below threshold)                  │             │
  │                     ├──Step2: author Question──────────────▶ emit out    │
  │                     │   gates = task-node#  │              ├──notify─────▶│
  │   node BLOCKED      │                       │              │             │ answers
  │                     │                       │              │◀──answer────┤  "latency"
  │                     │◀──deliver Answer──────────────────────┤            │
  │                     ├──Proposal: record resolution ──▶ (governance)      │
  │◀──UNBLOCK, resume───┤   node Blocked→Ready                  │            │
  │  continues          │                                       │            │
```

Contrast: had a prior instruction said "optimize p99 response time," Step 1 would have auto-resolved `fast = latency`, recorded the resolution, and unblocked the Worker **without** the Mailbox/User columns ever activating.

---

## 4. Interfaces & schemas

Rust-flavored pseudotypes. Names and shapes reuse `00` §7 verbatim where applicable (`AgentId`, `Hash`, `LogicalTime`, `Proposal`, `ErrorVector`).

### 4.1 Core artifacts

```rust
type InstructionId = Hash;   // content address of the raw instruction
type GoalId        = Hash;
type QuestionId    = Hash;

/// Raw, immutable user directive — the only free text the system accepts.
struct Instruction {
    id: InstructionId,
    body: Text,                  // raw natural language
    submitter: ExternalUserId,   // external identity; mapped to no AgentId — see 08
    received_at: LogicalTime,
    in_reply_to: Option<QuestionId>, // set if this instruction is actually an Answer payload
}

/// Typed normalization of an instruction: the canonical statement of intent.
struct Goal {
    id: GoalId,
    derived_from: InstructionId,
    version: u32,                // bumped when intent is revised
    intent: TypedIntent,         // structured goal (target over progress layer)
    acceptance: AcceptancePredicate, // holds <=> goal complete (progress_error == 0)
    constraints: Constraints,    // budget / deadline / quality -> setpoint bands
    provenance: Text,            // original instruction text, retained
}

/// The goal's projection into the PID controlled-variable space (consumed by 03).
struct Setpoint {
    goal: GoalId,
    progress_target: ProgressRef,   // acceptance predicate handle
    cost_band: Band,                // budget reference for ErrorVector.cost
    latency_band: Band,             // deadline reference for ErrorVector.latency
    applied_at: LogicalTime,        // clean reference-step boundary
}
```

### 4.2 Ambiguity, questions, answers

```rust
/// Raised by ANY agent that hits ambiguity. The work it concerns pauses on raise.
struct AmbiguityReport {
    raised_by: AgentId,
    concerns: Hash,              // the progress-layer node / proposal under question
    description: Text,
    alternatives: Vec<Text>,     // the materially-different interpretations
    blocking: bool,              // true => raiser must not proceed (the default)
}

/// Step-1 candidate resolution from existing context (no user interrupt).
struct ContextResolution {
    ambiguity: Hash,
    chosen: Text,                // which alternative
    confidence: f32,             // in [0,1]; compared to auto_resolve_threshold
    evidence: Vec<Hash>,         // prior instructions / answers / commits relied on
    consulted: Vec<AgentId>,     // Guardians/Genesis polled (decorrelation)
}

/// Step-2 user-facing question (only if Step 1 fails). Blocks its gated node.
struct Question {
    id: QuestionId,
    author: AgentId,             // the Guardian
    gates: Hash,                 // progress-layer node this Question blocks (01)
    prompt: Text,
    options: Option<Vec<Text>>,  // closed-form if known; else free-form answer
    origin: QuestionOrigin,      // Ambiguity | ConsensusEscalation | ControlEscalation
    raised_at: LogicalTime,
    state: QuestionState,        // Draft | Open | Answered | Closed
}

enum QuestionOrigin { Ambiguity, ConsensusEscalation, ControlEscalation }
enum QuestionState  { Draft, Open, Answered, Closed(CloseReason) }
enum CloseReason    { Answered, AutoResolvedLate, Superseded, Withdrawn }

/// The user's reply. Unblocks the gated node and becomes a new "existing input."
struct Answer {
    question: QuestionId,
    body: Text,                  // selected option or free text
    answered_at: LogicalTime,
    answered_by: ExternalUserId,
}

/// Outbound, non-blocking message. User need not respond.
struct Notification {
    subject: Text,
    body: Text,
    severity: Severity,          // Info | Warning | ActionSuggested
    relates_to: Option<Hash>,    // goal / node / decision this concerns
    emitted_at: LogicalTime,
}
```

### 4.3 The Guardian trait

```rust
/// The Interaction-plane contract. Implemented by Guardian agents.
trait GuardianInteraction {
    /// Intake: accept and persist a raw instruction.
    fn submit_instruction(&self, body: Text, submitter: ExternalUserId) -> InstructionId;

    /// Normalize an instruction into a typed Goal (output is schema-validated).
    fn normalize(&self, instr: InstructionId) -> Goal;

    /// Derive/maintain the PID setpoint from a goal (consumed by 03).
    fn setpoint(&self, goal: GoalId) -> Setpoint;

    /// STEP 1 of the gate: can existing user inputs resolve this ambiguity?
    /// Consults the council/Guardians; returns Some(resolution) iff confident.
    fn try_auto_resolve(&self, a: &AmbiguityReport) -> Option<ContextResolution>;

    /// STEP 2 of the gate: surface a Question and block the gated node.
    fn escalate_to_user(&self, a: &AmbiguityReport) -> QuestionId;

    /// Deliver a user Answer: unblock the gated node, record the resolution
    /// (as a Proposal so it enters the immutable history), retain as input.
    fn deliver_answer(&self, ans: Answer);

    /// Author a typed proposal (00 §7) into governance (02). Propose, not vote.
    fn author_proposal(&self, p: Proposal) -> Hash;
}
```

### 4.4 External API surface

The Interaction plane is also the **external boundary**. These are the operations available to a user-facing client (CLI, web, agent). Authentication and external-identity binding are deferred to `08` (§5); shapes are illustrative (REST-flavored, but transport-agnostic).

**(a) Submit an instruction.**

```
POST /v1/instructions
  req:  { "body": "<natural language>", "in_reply_to": <QuestionId?> }
  resp: { "instruction_id": <Hash>, "received_at": <LogicalTime>,
          "ack": "received" }
```
A `body` with `in_reply_to` set is routed as an `Answer` to that Question (one channel, two semantics). A bare instruction enters the intake state machine (§3.1).

**(b) Poll or subscribe to notifications.**

```
GET  /v1/notifications?since=<LogicalTime>          # poll
  resp: { "items": [ <Notification | Question> ... ], "cursor": <LogicalTime> }

GET  /v1/notifications/stream                        # subscribe (SSE/websocket)
  -> server-pushed stream of <Notification | Question> as they are emitted
```
Both Questions and Notifications appear here; a Question is distinguished by carrying a `question_id` and being answerable. This is the channel on which **consensus escalations (`02`)** and **control-loop escalations (`03`)** reach the user.

**(c) List open questions.**

```
GET  /v1/questions?state=open
  resp: { "items": [ {
            "question_id": <Hash>, "prompt": <Text>,
            "options": [<Text>...] | null,
            "gates": <Hash>,              # the blocked progress node (01)
            "origin": "Ambiguity" | "ConsensusEscalation" | "ControlEscalation",
            "raised_at": <LogicalTime>
          } ... ] }
```
Each item exposes its `gates` edge so a client can show *what is blocked* on each question.

**(d) Answer a question.**

```
POST /v1/questions/{question_id}/answer
  req:  { "body": "<selected option or free text>" }
  resp: { "status": "accepted",
          "unblocked": [ <Hash> ... ],   # progress nodes transitioned Blocked->Ready
          "resolution_proposal": <Hash> } # the Proposal recording the answer
```
Answering is idempotent per `question_id`: a second answer to an already-`Answered`/`Closed` question returns the prior outcome rather than re-applying.

**Surface summary.**

| Direction | Operation | Carries |
|-----------|-----------|---------|
| Inbound | `submit_instruction` | new Instructions; Answers (via `in_reply_to`) |
| Outbound | `poll` / `subscribe` notifications | Notifications, Questions, escalations from `02`/`03` |
| Read | `list open questions` | the blocking work surface (with `gates` edges) |
| Inbound | `answer_question` | Answers that unblock gated nodes |

---

## 5. Open questions & ambiguities

Per `00` §9, surfaced ambiguities are parked here, not silently decided.

1. **One user or many?** This spec assumes a *single* external user with a single intent thread per Guardian. Multiple concurrent users — shared goals, conflicting instructions, per-user mailboxes, authorization to answer another user's question — are unresolved. If multi-user, the Guardian state machine (§3.1) and the open-question index (§3.3) need a tenancy dimension, and "existing inputs" in the Step-1 gate must be scoped to whose inputs count.
2. **External identity vs internal `AgentId`.** `ExternalUserId` is intentionally *not* an `AgentId` (`00` §7: `AgentId` is a public-key-derived identity for internal agents). How external users authenticate, how their identity binds to a session, and whether an external user can be granted any internal trust are all **deferred to `08-trust-and-security.md`**. This spec only assumes a stable `ExternalUserId` exists and that the submitter of an Answer can be checked.
3. **Timeouts on unanswered questions.** A `Question` can stay `Open` indefinitely, blocking its node forever. Should there be a timeout? If so, may the system **proceed with a default**? Candidates: (a) never proceed (current default — honors "do not proceed until answered" literally); (b) proceed with the Step-1 best candidate (its `confidence` was just below threshold) after a deadline, emitting a Notification; (c) escalate severity and keep blocking. The safest reading of the bootstrap is (a), but (b) may be necessary for liveness. Parked.
4. **Deduplicating near-identical questions.** Multiple agents may independently raise the *same* ambiguity (e.g. several Workers all confused by "fast"). Surfacing N near-identical Questions would burn user attention. We need a dedup/coalescing policy: cluster `AmbiguityReport`s by semantic similarity, raise *one* Question, and fan its single Answer back out to every gated node. The clustering is itself LLM-backed and therefore nondeterministic — does coalescing run through the council (decorrelated), and what is the false-merge risk (two genuinely different ambiguities merged, so one is answered wrong)? Parked.
5. **Auto-resolve confidence threshold.** Step 1 turns on a confidence threshold separating "auto-resolve silently" from "ask the user." Where is it set, is it per-goal tunable, and does it interact with the PID controller (e.g. tighten the threshold when divergence is already high)? Calibrating this trades user-interruption rate against silent-misinterpretation rate. Parked; relates to reputation/calibration in `08`.
6. **Late supersession UX.** §3.4 allows a still-`Open` Question to be auto-resolved late by a newer input and `CLOSED(AutoResolvedLate)`. Racing the user (they may be mid-answer) needs a tie-break: does a user Answer always win over a late auto-resolution? Current lean: yes, the human is authoritative. Parked for confirmation.
7. **Instruction that contradicts an accepted commit.** A new Instruction may conflict with already-committed progress (`01`). Is that an ambiguity (gate it), a new Goal version (setpoint step, §3.2), or a proposal to *revert*? Likely all three depending on magnitude; the routing rule is unspecified. Parked.

---

## 6. Relationships to other specs

| Spec | Relationship |
|------|--------------|
| **`00-overview.md`** | Canonical anchor. Guardian role (§3), Mailbox glossary entry, plane table (§2), the closed-loop diagram (§5: "Guardians surface a question … the affected work blocks until answered"), and the canonical types (`Proposal`, `AgentId`, `Hash`, `LogicalTime`, `ErrorVector`) all originate there and are reused verbatim. |
| **`01-state-model.md`** | The Interaction plane *writes into the progress layer* via proposals. The canonical "open question" object is a **progress-layer node** (`01` lists "open questions" as progress-layer content); the Mailbox `Question` is its user-facing projection, linked by the `gates: Hash` edge. Blocking/unblocking flips that node's `Blocked ↔ Ready` state. `LogicalTime` ordering comes from here. |
| **`02-consensus.md`** | Guardians *author* the typed `Proposal`s that this plane produces (goal seeding, answer resolutions, escalation relays); the Genesis council disposes. **Consensus escalations** (deadlock, high dispersion) surface to the user through this plane's Mailbox as Questions/Notifications. The Step-1 auto-resolve "consult the council" query is a decorrelated read using `02` machinery. |
| **`03-control-loop.md`** | The **Goal defines the setpoint/target state** the PID controller steers toward (§3.2). The Setpoint schema (§4.1) is produced here and consumed there. **Control-loop escalations** (infeasible goal, flatlined progress) surface through the Mailbox. Blocked nodes are reported to `03` as *stalled-by-design*, kept distinct from the `divergence`/`progress` error terms so blocking does not look like failure. |
| **`04-runtime-and-harness.md`** | Workers (running under harnesses) are the most frequent *raisers* of `AmbiguityReport`s (§3.5). A raised ambiguity pauses that Worker's unit of work; the Answer/resolution resumes it. |
| **`07-observability.md`** | The Mailbox logs (§3.3) and question lifecycle (§3.4) are a telemetry source: interruption rate, auto-resolve hit-rate, mean time-to-answer, and blocked-node counts are observability signals. Sentinels may watch for Guardians over-interrupting the user (a drift signal). |
| **`08-trust-and-security.md`** | Owns the unresolved external-identity questions (§5.2): how `ExternalUserId` authenticates, how answer-authorization is checked, and the external-vs-internal trust boundary. The Mailbox is the system's outermost trust boundary. |
