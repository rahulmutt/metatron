# Metatron — Interaction Plane & Mailbox

> **Status:** Research architecture specification (v0.1)
> **Plane:** Interaction (top of the stack in `00-overview.md` §2).
> **Owning role:** **Guardian** agents (the user's advocate; *propose* power, never *vote*).
> **Depends on:** `00-overview.md` (canonical vocabulary & types — when this spec disagrees with it, the overview wins). References `01-state-model.md` (progress layer, open questions), `02-consensus.md` (typed `Proposal`, consensus escalation), `03-control-loop.md` (`ErrorVector`, setpoint, control-loop escalation), `08-trust-and-security.md` (external identity, authentication, and per-user authorization scopes — `ExternalUserId` is a separate principal type, **not** an `AgentId`).

---

## 1. Purpose

The **Interaction plane** is the boundary between Metatron and the external world. Everything the user knows about the system, and everything the system knows about the user's intent, flows through this one plane. It exists so that the rest of Metatron — the deliberative, control-theoretic core — can treat *user intent* as a clean, typed, versioned input rather than a stream of free text.

Concretely, the Interaction plane is responsible for five things, all owned by **Guardian** agents:

1. **Accept user INSTRUCTIONS.** Take in raw, possibly under-specified natural-language directives from the external user.
2. **NORMALIZE an instruction into a GOAL.** Turn an instruction into a typed, schema-validated `Goal` artifact — the canonical statement of what the user wants.
3. **Define the SETPOINT / TARGET STATE.** The normalized goal *is* the reference signal the steering loop (`03`) steers toward. Goal → setpoint is the contract between the Interaction plane and the Governance plane.
4. **Detect AMBIGUITY** in an instruction or in any downstream work derived from it, and resolve it under a strict two-step gate (auto-resolve from existing context, else escalate to the user).
5. **Author typed PROPOSALS** (`Proposal`, defined in `00` §7, elaborated in `02`). Guardians are the *only* role with propose power; every user-originated change to the world-model enters governance as a Guardian-authored proposal.

The plane also owns **the Mailbox**: the bidirectional channel between the system and its users. Outbound it carries **questions** and **notifications**; inbound it carries **answers** and **new instructions**. The Mailbox is also the boundary at which *internal escalations surface to the human*: consensus escalations from `02` and control-loop escalations from `03` both reach the user as mailbox items.

**Multi-user from the start.** Metatron is **multi-tenant**: several authenticated external users interact with the same system concurrently, each with their own intent thread, their own **per-user mailbox**, and their own **authorization scopes** over which goals and budgets they may set or answer for. Every artifact in this plane carries a **principal** dimension. The external principal is a *separate principal type* — an authenticated **`ExternalUserId`**, distinct from the internal public-key-derived **`AgentId`** (`00` §7). This spec **assumes** an authenticated `ExternalUserId` and a resolved set of per-user scopes; *how* a user authenticates and how those scopes are issued/checked is owned by `08-trust-and-security.md` and referenced, not redefined, here.

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
     │                        │                     steering loop (03)
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
| **Setpoint / Target state** | The goal projected into the controlled-variable space of the steering loop (`03`). The reference signal the closed loop steers toward. One goal yields one setpoint contribution. |
| **Ambiguity** | A point in an instruction, goal, or derived unit of work where more than one materially-different interpretation is admissible, *and* the choice affects the outcome. Detected by any agent; adjudicated by Guardians. |
| **Question** | A typed request for user input that has survived the two-step resolution gate. Surfaced via the Mailbox. Linked to the progress-layer node it gates. |
| **Answer** | The user's typed response to a Question. Unblocks the gated work and is recorded as a new user input. |
| **Notification** | An outbound, *non-blocking* message from the system to a user (status, escalation summary, completion). The user is not required to respond. |
| **Mailbox** | The **per-user** bidirectional channel carrying Questions/Notifications out and Answers/Instructions in. The external API surface (§4). |
| **Principal / `ExternalUserId`** | The authenticated identity of an external user. A *separate principal type* from `AgentId` (`00` §7); every Instruction/Goal/Question/Answer/Notification is tagged with the principal it belongs to. Authentication owned by `08`. |
| **Authorization scope** | The set of goals, budget ceilings, and questions a given principal is permitted to set, raise, or answer. Issued/checked per `08`; *consumed* here to admit or reject instructions and answers, and to scope Step-1 "existing inputs". |

### 2.2 Guardian responsibilities recap

Guardians sit at the top of the checks-and-balances cycle (`00` §3): **Guardians propose → Genesis disposes**. Within the Interaction plane a Guardian is a state machine **keyed by principal**: it owns one `ExternalUserId`'s intent thread, that user's per-user mailbox, and the enforcement of that user's authorization scopes. Multiple users' threads run concurrently; a Guardian instance is always acting *on behalf of a specific principal* and stamps every artifact it produces with that `ExternalUserId`. It:

- admits an Instruction or Answer only if it falls within the submitting principal's authorization scope (which goals/budgets that user may set or answer for; scopes issued/checked per `08`), rejecting or down-scoping otherwise;
- ingests Instructions and normalizes them to Goals;
- maintains the mapping `Goal → Setpoint` consumed by `03`;
- receives ambiguity reports from *any* agent in the system (a Worker hitting an unclear requirement, a Genesis member unsure how to vote, the steering loop unable to interpret an error) and runs the resolution gate (§2.3);
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

- **Step 1 — auto-resolve from existing context.** Before any question reaches the human, the system consults the **council / Guardians** to check whether the *existing inputs* already determine the answer. **"Existing inputs" is scoped to the relevant user and goal**: it means the prior instructions and previously-answered questions *of the principal(s) authorized over the goal under question*, the active Goal and its setpoint, and accepted commits in that goal's progress sub-graph. One user's private intent thread does not silently resolve another user's ambiguity; only inputs in scope for the gated goal count. This is a deliberative read-only query — it produces a *candidate resolution* with a confidence — and it is itself decorrelation-friendly (multiple Guardians/Genesis members can be consulted; see `02`). If the in-scope context resolves the ambiguity above a confidence threshold, the resolution is recorded (as a Guardian proposal so it enters the immutable history) and the blocked work is **unblocked without ever interrupting the user**.
- **Step 2 — escalate to the user.** Only if Step 1 fails does a `Question` reach the human. The Guardian authors a typed Question, **links it to the specific progress-layer node it gates**, and emits it on the Mailbox. The gated work — and only the gated work — **blocks until answered** (§2.4). Unrelated work continues.

The gate is what makes user attention scarce-by-construction: the human is interrupted only for ambiguities that their own prior inputs genuinely cannot settle.

### 2.4 Blocking-until-answered

Blocking is **scoped, not global**. A Question gates a *specific* unit of work, represented as an edge from the Question to the progress-layer node it depends on. While the Question is open:

- the gated node (and its transitive dependents in the task graph) is in a `Blocked` state and does not advance;
- every other node in the progress layer continues normally;
- the steering loop (`03`) sees the blocked node as *stalled-by-design*, not as divergence or failure — a blocked node contributes to a distinct `blocked` accounting, not to the `progress` error term as drift (see §7 and `03`).

When the Answer arrives, the Guardian records it (as a proposal that writes the resolution into the progress layer), the gating edge is removed, the node transitions `Blocked → Ready`, and execution resumes. The Answer is also retained as a new "existing input," so future Step-1 auto-resolutions can draw on it — answering a question once should prevent the system from ever asking an equivalent question again.

**Defining `reversible` — the predicate the whole gate rests on.** Because whether the system *acts without asking* turns on this one word, it is given an operational definition rather than left to free-form judgment. An action is **`reversible` iff *both* objective conditions hold**:

1. **No external side effect through the `mcp-auth-proxy`.** The gated work issues *no* call that egresses through the `mcp-auth-proxy` (`08`); every effect stays inside Metatron's own state. The proxy is the single external-egress chokepoint, so "does this touch an external system" reduces to a **lookup over the gated node's planned tool-calls**: if any planned call is routed to the proxy, this condition is **false**.
2. **A revertible DAG diff.** The state change the work commits is expressible as a progress-layer / Merkle-DAG diff with a **computable inverse** — a `revert` proposal (`02`, §3.7) that returns the head to its prior content-address. This is decided **structurally from the diff**: an additive or last-writer-wins diff over nodes the work itself authored, with the pre-image retained, is revertible; a diff that destroys prior content without a retained pre-image, or that a later committed node already builds on, is **not**.

**Anything not provably both is irreversible by default.** In particular, **if either input cannot be computed — reversibility is *unknown* — the action is classified irreversible and the gate blocks, escalating to a human.** Unknown is *never* treated as reversible. Both inputs are objective (proxy routing is a lookup over planned calls; diff-revertibility is a structural property of the diff), so the classifier is **not** free-form LLM judgment: an LLM may *propose* a tier, but the predicate above is authoritative and fails safe. The **"a user Answer always wins over a late auto-resolution" revert** (§3.4) rests on this same predicate — an auto-resolution can only have committed in the user's absence if it was `reversible` here, so its revert path is always well-defined.

**Timeouts are tiered by blast radius.** A `Question` must not block its node *forever* when the work is cheap and recoverable, but must *never* be auto-defaulted when the work is dangerous. The deadline behavior is therefore tiered by the blast radius of the gated work:

- **Low-stakes / reversible work** — work that is cheap, `reversible` (by the predicate above), and below a significant-budget threshold **proceeds after a deadline** using the Step-1 best auto-resolution candidate (the one whose `confidence` sat just below the auto-resolve threshold). It proceeds **reversibly** and **emits a Notification** so the user can see, and undo, what was chosen in their absence. Liveness is preserved.
- **High-stakes work** — work that is **constitutional** (`00` §6), **irreversible** (by the predicate above, *including the unknown-reversibility case*), or carries **significant budget** is **never silently auto-defaulted**. It follows the uniform **bounded escalation-timeout** policy: the Question is held for a bounded escalation window and, on expiry, re-routed up the cross-user precedence order (§3.7) to the next authorized principal. If the window elapses with no authoritative Answer, the gated node **holds and degrades safely** — it stays `Blocked`, sheds its dependent work cleanly, and emits a `Warning` Notification — but **never proceeds on the irreversible action**. There is no auto-default that *acts*: the only fallback is to stay safely stalled, honoring the bootstrap ("do not proceed until answered") without dead-ending availability for the rest of the system. No high-stakes path blocks *indefinitely* — every wait is bounded and resolves to this defined safe fallback.

The blast-radius tier is derived **mechanically** from the gated node — (i) the `reversible` predicate above, (ii) budget magnitude against the significant-budget threshold, (iii) whether it touches kernel/constitutional state — and is recorded on the `Question` so the tier is auditable. Unknown on any objective input resolves to high-stakes.

### 2.5 Escalations as a Mailbox boundary

The Mailbox is the *single* place internal escalations become human-visible:

- **Consensus escalations (`02`).** When the council cannot reach the acceptance threshold, or dispersion is high enough that deliberation does not converge, the decision escalates. A Guardian renders the deadlock as a user-facing item: a Question if a human choice can break it, or a Notification if it is merely informational.
- **Control-loop escalations (`03`).** When the steering loop detects an error it cannot drive down with available control actions (e.g. the goal is infeasible under the cost budget, or progress has flatlined), it escalates. A Guardian renders this as a Question ("relax the deadline or cut scope?") or Notification.

In both cases the Interaction plane is doing its job: translating an internal condition into the typed, scarce, blocking-or-not vocabulary the user understands.

**The deterministic budget notifier (`10`).** Budget-exhaustion escalations are special: they are raised by an **off-budget, non-LLM reflex** that emits a schema-validated `BudgetNotice` (a typed Mailbox item) computed entirely from the `07` ledger. It is self-funding (draws from no budget node) and un-forgeable (a drifting or compromised LLM cannot corrupt the message a funding decision rests on), debounced by the same deadband/hysteresis the steering loop uses. If reserved-floor budget remains, the Guardian LLM *additionally* enriches it — a guaranteed baseline plus best-effort context. The blocked work waits under the usual bounded escalation-timeout and then degrades safely; on top-up or reallocation it resumes.

### 2.6 Channels — the pluggable external boundary

Everything above describes the plane's *internal* contract: raw `Instruction`/`Answer` in, typed `Question`/`Notification` out, keyed by an abstract `ExternalUserId`. That contract is deliberately transport-agnostic. A **Channel** is a concrete way a user reaches the system — an HTTP API, Telegram, Slack, SMS — and a **Channel Adapter** is the translation shell that sits *outside* the Guardian and connects one such transport to the internal contract.

The adapter occupies the same structural position for *user connection* that `AgentHarness` (`04`) occupies for *agent execution*: a pluggable boundary that maps one heterogeneous external world onto one canonical internal contract. Adding a channel is implementing an adapter; **the Guardian intake state machine (§3.1), the two-step gate (§2.3), goal normalization, and the mailbox (§3.3) do not change.**

An adapter has three jobs: (1) **authenticate** the channel-native sender and **resolve** it to an `ExternalUserId` (via the binding table owned by `08`, §3.9); (2) **normalize inbound** channel-native events into a canonical `Instruction` — or, when the event correlates to an open `Question`, an `Answer`; (3) **render outbound** `Question`/`Notification` into channel-native form, best-effort and lossy, tracking a **correlation token** so any reply routes back to the exact `QuestionId` it answers. There is **no capability-negotiation handshake**: an adapter merely *declares* what it can do (`ChannelCapabilities`) and degrades gracefully.

---

## 3. Detailed design

### 3.1 The Guardian intake state machine

Each Instruction is processed by a Guardian **on behalf of the submitting principal** (`ExternalUserId`). The state machine is *per-principal*: each transition is stamped with the principal, and the machine runs concurrently and independently for every active user.

```
                  ┌─[scope OK]─▶ RECEIVED ──normalize──▶ NORMALIZED ──ambiguity?──▶ GATED ──┬─[Step1 resolves]─▶ PROPOSED
 (instr, principal)│                  │                       │                              │
 ──ADMIT(scope)────┤                  │                       └──[no ambiguity]──────────────┘
                  │                  ▼                                                       └─[Step2]─▶ AWAITING_USER ──answer──▶ PROPOSED
                  └─[denied]─▶ REJECTED      (InstructionId + ExternalUserId assigned, persisted, ack'd on the user's Mailbox)
                              (Notification)
```

0. **ADMIT.** The Instruction arrives bound to an authenticated `ExternalUserId`. The Guardian checks it against that principal's **authorization scope** (which goals/budgets the user may set; per `08`). If out of scope it is `REJECTED` with a Notification on the user's mailbox; otherwise it enters `RECEIVED`.
1. **RECEIVED.** The Instruction is assigned an `InstructionId`, stamped with its submitting `ExternalUserId`, time-stamped with `LogicalTime` (`01`), and acknowledged. It is immutable.
2. **NORMALIZED.** The Guardian produces a candidate `Goal`. Normalization is an LLM-backed step but its *output is typed* (per `00` §6.1, constrain the output space): the Guardian must emit a schema-valid `Goal`, not prose. The instruction text is preserved on the Goal as provenance.
3. **Ambiguity check.** The Guardian scans the Goal for ambiguity (and downstream agents may later raise ambiguity against work derived from it). Each ambiguity enters the two-step gate (§2.3).
4. **GATED → resolution.** Step 1 may auto-resolve. Otherwise Step 2 surfaces a Question and the Guardian parks the affected work in `AWAITING_USER`.
5. **PROPOSED.** Once the Goal is unambiguous (or its ambiguities are resolved/parked such that *some* work can proceed), the Guardian authors `Proposal`s that seed the progress layer with the goal's task structure and register the setpoint. From here the Governance plane takes over (`02`).

Note normalization and ambiguity resolution are *interleaved*, not strictly sequential: a Goal may be partially proposed (the unambiguous part proceeds) while one sub-aspect blocks on a Question.

### 3.2 Goal → Setpoint derivation

The Goal is the user-facing statement; the **Setpoint** is its projection into the steering loop's controlled-variable space (`03`). The Guardian computes and maintains this projection:

- **Progress target.** The goal's completion criteria define the `progress` reference: `progress_error = 0` exactly when the goal's acceptance predicate holds over the progress layer.
- **Constraints become bounds.** Budget/deadline/quality constraints on the Goal map onto the `cost` and `latency` reference bands of the `ErrorVector` (`00` §7).
- **Stability.** The setpoint is *versioned*: a new Instruction that revises intent produces a new Goal version and a new setpoint, applied at a `LogicalTime` boundary so the controller sees a clean reference step rather than a mid-flight mutation.

The mapping is owned by the Guardian but *consumed* by `03`; the schema of the setpoint contribution lives here (§4.4) and is referenced by `03`.

### 3.3 Mailbox internals

The Mailbox is **per-user**: each principal has its own pair of logs and its own derived index, all keyed by `ExternalUserId`. A user sees only their own mailbox; the system addresses an outbound item to a specific principal. Concretely the Mailbox is modeled as, *per principal*, two append-only, content-addressed logs plus a derived index:

- **Outbound log** — Questions and Notifications addressed to this user, in emission order.
- **Inbound log** — Answers and Instructions from this user, in arrival order.
- **Open-question index** — the derived set of this user's Questions with no matching Answer, each carrying its gating edge into the progress layer. The index is **keyed by `(ExternalUserId, QuestionId)`** so the tenancy dimension is explicit and one user's open questions never leak into another's surface. A single underlying ambiguity that gates several users' work fans out to one entry per recipient (see §3.6).

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

**A user Answer always wins over a late auto-resolution.** If the user submits an Answer while a late Step-1 auto-resolution is racing to settle the same Question, the human is authoritative: the Answer is applied (and, if the auto-resolution had already committed a *reversible* resolution, it is reverted in favor of the Answer), and a Notification records the correction. The human is never overruled by the machine on their own question.

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

### 3.6 Question deduplication & fan-out

Several agents may independently raise the *same* ambiguity (e.g. multiple Workers all confused by "fast"), and the same underlying ambiguity may gate work belonging to more than one user. Surfacing N near-identical Questions would burn the scarcest resource — user attention — so Guardians **coalesce** before escalating:

1. **Cluster** incoming `AmbiguityReport`s by **semantic similarity**, run **through the decorrelated council** (the same `02` machinery Step 1 uses, so the clustering judgment is itself decorrelation-hardened rather than a single LLM's call).
2. **Raise one Question** per cluster.
3. **Fan its single Answer back** to *every* gated node in the cluster, unblocking them all at once.

Clustering uses a **conservative similarity threshold**: it is biased toward *not* merging, because a false merge (two genuinely-different ambiguities collapsed into one) means one of them is answered wrong. The conservative threshold *bounds* but does not eliminate that risk (see §6 Open questions).

**Fan-out across users.** When a coalesced Question gates work for multiple principals, the single Question is projected into **each affected user's mailbox** (one open-question-index entry per recipient, §3.3). Who is *authorized to answer* is governed by per-user scopes (`08`); when more than one authorized user could answer the same shared question — or issues a conflicting instruction on a shared goal — arbitration follows the routing rules of §3.7, with the cross-user arbitration *policy* itself still open (§6).

### 3.7 Reconciling a new instruction with committed state — route by magnitude

A new Instruction may conflict with intent the user already expressed, or with already-committed progress (`01`), or with another user's instruction on a shared goal. The Guardian **routes by the magnitude of the conflict** rather than treating every conflict the same way:

- **Small conflict → treat as an ambiguity.** The discrepancy is minor / locally reconcilable: route it into the two-step gate (§2.3) as an `AmbiguityReport` and let Step-1 context (or, failing that, a Question) settle it.
- **Medium conflict → a new Goal version.** The instruction is a genuine revision of intent: mint a **new `Goal` version** (§3.2), producing a clean **setpoint step** at a `LogicalTime` boundary that feeds the steering loop (`03`) as a reference change rather than a mid-flight mutation.
- **Large conflict → a proposal to revert.** The instruction contradicts committed progress so fundamentally that the right action is to undo it: author a **proposal to revert** (`02`) the offending committed state, which the Genesis council disposes of like any other proposal.

**Cross-user precedence — deterministic, deadlock-free.** Cross-user conflicts on a *shared* goal use the same magnitude routing. To guarantee that two authorized principals can never *mutually deadlock* — each blocking on the other, or each holding a contradictory answer to the same shared Question (§3.6) — a **deterministic precedence order** breaks every tie: **(1) higher authorization rank wins** (the `rank` carried on each principal's `AuthorizationScope`, issued per `08`); **(2) on equal rank, first-committed-wins** — the instruction whose enclosing artifact reached an earlier `LogicalTime` boundary (`01`) prevails. This order is total and computable, so arbitration always terminates with a single winner rather than a standoff. The losing instruction is not discarded: it is surfaced to its submitter as a Notification and may re-enter as a fresh instruction. This precedence is a **liveness floor**, not the last word on *values*: a richer values-weighted arbitration policy may later refine *which* intent **should** prevail (§6), but it may only override the floor, never reintroduce a deadlock.

### 3.8 Channel adapter data flow, rendering & correlation

```
inbound:  native event ──authenticate──▶ ExternalUserId ──ingest──▶ {Instruction | Answer} ──▶ Guardian (§3.1)
outbound: Question/Notification ──render (lossy)──▶ native message  (+ correlation token for Questions)
reply:    native reply ──match correlation token──▶ QuestionId ──▶ Answer ──▶ deliver_answer (§4.3)
```

**Inbound normalization.** The adapter turns a channel-native event into a canonical `Instruction`. If the event carries a correlation token for an open `Question`, it is instead ingested as an `Answer` to that `QuestionId` (the same one-channel-two-semantics rule as the API's `in_reply_to`, §4.4). Free text stays free text — normalization to a `Goal` remains the Guardian's job (§3.1), unchanged.

**Outbound rendering is best-effort and lossy.** A `Question`'s structured `options` (§4.2) render as native controls where the adapter's `ChannelCapabilities.supports_structured_options` is true (Slack blocks, Telegram inline keyboards) and otherwise degrade to a numbered/keyword list the user answers in plain text. A channel with `supports_push == false` is polled by the client rather than pushed to. Degradation is the adapter's own concern; the Guardian emits one canonical `Question` regardless of channel.

**Correlation is explicit, not threading-dependent.** Every rendered `Question` carries an adapter-managed `CorrelationToken`, so a reply on *any* channel maps unambiguously back to its `QuestionId` even when the channel cannot thread (e.g. SMS). Channel-native threading (Slack `thread_ts`, Telegram reply-to) may *inform* the token but is never the sole basis for correlation.

**The correlation token is not an authorization credential.** It identifies *which* `Question` a reply answers; *who* may authoritatively answer is still the `08` `may_answer` scope check on the resolved `ExternalUserId` (§2.2, §3.6). A guessed or leaked token cannot answer another principal's blocking `Question`.

---

## 4. Interfaces & schemas

Rust-flavored pseudotypes. Names and shapes reuse `00` §7 verbatim where applicable (`AgentId`, `Hash`, `LogicalTime`, `Proposal`, `ErrorVector`).

### 4.1 Core artifacts

```rust
type InstructionId = Hash;   // content address of the raw instruction
type GoalId        = Hash;
type QuestionId    = Hash;

/// External-user principal — a SEPARATE principal type from AgentId (00 §7).
/// It is NOT public-key-derived internal identity; authentication is owned by 08.
type ExternalUserId = Hash;  // stable handle to an authenticated external user

/// What a principal is permitted to set or answer for. Issued/checked per 08;
/// CONSUMED here to admit instructions/answers and to scope Step-1 "existing inputs".
struct AuthorizationScope {
    principal: ExternalUserId,
    goals: GoalSelector,         // which goals this user may set / revise / answer for
    budget_ceiling: Budget,      // max budget this user may commit via a goal/answer
    may_answer: QuestionSelector,// which questions this user may authoritatively answer
    rank: AuthorizationRank,     // total-ordered precedence for cross-user tie-break (§3.7); issued per 08
}

/// Raw, immutable user directive — the only free text the system accepts.
struct Instruction {
    id: InstructionId,
    body: Text,                  // raw natural language
    submitter: ExternalUserId,   // external principal; NOT an AgentId — see 08
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

/// The goal's projection into the steering loop's controlled-variable space (consumed by 03).
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
    recipients: Vec<ExternalUserId>, // whose mailbox(es) this surfaces in (fan-out, §3.6)
    gates: Hash,                 // progress-layer node this Question blocks (01)
    prompt: Text,
    options: Option<Vec<Text>>,  // closed-form if known; else free-form answer
    origin: QuestionOrigin,      // Ambiguity | ConsensusEscalation | ControlEscalation
    blast_radius: BlastRadius,   // tier governing timeout behavior (§2.4)
    cluster: Option<Hash>,       // coalescing cluster id, if deduped (§3.6)
    raised_at: LogicalTime,
    state: QuestionState,        // Draft | Open | Answered | Closed
}

enum QuestionOrigin { Ambiguity, ConsensusEscalation, ControlEscalation }
enum QuestionState  { Draft, Open, Answered, Closed(CloseReason) }
enum CloseReason    { Answered, AutoResolvedLate, Superseded, Withdrawn }

/// Blast-radius tier of the gated work; decides timeout behavior (§2.4).
/// Derived mechanically; `reversible` is the objective predicate of §2.4
/// (no mcp-auth-proxy egress AND a revertible DAG diff). Unknown reversibility => HighStakes.
enum BlastRadius {
    LowStakesReversible, // proceeds after a deadline w/ Step-1 best candidate, reversibly + Notification
    HighStakes,          // constitutional / irreversible (incl. unknown) / significant-budget:
                         // bounded escalation-timeout -> hold + degrade safely, never auto-proceed (§2.4)
}

/// The user's reply. Unblocks the gated node and becomes a new "existing input."
struct Answer {
    question: QuestionId,
    body: Text,                  // selected option or free text
    answered_at: LogicalTime,
    answered_by: ExternalUserId,
}

/// Outbound, non-blocking message. User need not respond.
struct Notification {
    recipient: ExternalUserId,   // whose per-user mailbox this lands in (§3.3)
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
    /// Admit (ADMIT step, §3.1): check a principal's authorization scope before
    /// accepting an instruction/answer. Scopes are issued/checked per 08.
    fn authorize(&self, who: ExternalUserId, what: &Instruction) -> AdmitDecision; // Admit | Reject

    /// Intake: accept and persist a raw instruction (after authorize()).
    fn submit_instruction(&self, body: Text, submitter: ExternalUserId) -> InstructionId;

    /// Normalize an instruction into a typed Goal (output is schema-validated).
    fn normalize(&self, instr: InstructionId) -> Goal;

    /// Derive/maintain the steering setpoint from a goal (consumed by 03).
    fn setpoint(&self, goal: GoalId) -> Setpoint;

    /// STEP 1 of the gate: can existing inputs IN SCOPE FOR THE GATED GOAL
    /// resolve this ambiguity? Consults the council/Guardians; "existing inputs"
    /// is scoped to the authorized principal(s)/goal (§2.3). Some(_) iff confident.
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

The Interaction plane is also the **external boundary**. These are the operations available to a user-facing client (CLI, web, agent). **Every call is made by an authenticated `ExternalUserId`** and is scoped to that principal: instructions are admitted only within the caller's authorization scope, and the notification/question endpoints read only the caller's per-user mailbox. Authentication, identity binding, and scope issuance are deferred to `08` (§5 decision 2); shapes are illustrative (REST-flavored, but transport-agnostic).

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

**Setting budgets (`10`).** Through this surface a user sets or overrides the **stock** and **rate** budgets of any node they are authorized for — the global ceiling and, optionally, per-class / per-agent allocations. Budget setpoints follow the same strict-priority resolution as other setpoints (`03` §7.1): explicit user override → guardrailed learned refinement → safe default. Changes are enacted as tiered typed proposals (`02` §9.4).

### 4.5 Channel adapters

The external API surface of §4.4 is **one concrete adapter** (`ApiAdapter`) over a transport-agnostic contract, not *the* boundary. Every channel — API, Slack, Telegram, SMS — is an implementation of the `ChannelAdapter` trait below; the Guardian is unaware which adapter produced an inbound item or will deliver an outbound one.

````rust
type ChannelId = Hash;               // stable id of one configured channel instance

enum ChannelKind { Api, Slack, Telegram, Sms, Other(String) } // extensible

/// What an adapter can natively do. DECLARED, not negotiated (no handshake).
struct ChannelCapabilities {
    supports_structured_options: bool, // native buttons / quick-replies
    supports_push: bool,               // server-initiated delivery vs poll-only
    supports_threading: bool,          // native reply threading (advisory only)
    max_message_len: Option<u32>,
}

/// An authenticated channel-native sender, PRE-resolution.
/// Resolved to an ExternalUserId via the 08-owned binding table (08 §3.9).
struct ChannelIdentity {
    channel_kind: ChannelKind,
    native_id: Text,      // Slack user id, Telegram user id, API token subject, …
    auth_evidence: Bytes, // channel-native proof; VERIFIED by the adapter, checked per 08
}

/// Opaque, adapter-managed. Identifies WHICH Question a reply answers.
/// NOT an authorization credential — answer-authz is the 08 `may_answer` check.
struct CorrelationToken(Bytes);

/// The channel-boundary contract. One implementation per ChannelKind.
trait ChannelAdapter {
    fn kind(&self) -> ChannelKind;
    fn capabilities(&self) -> ChannelCapabilities;

    /// Authenticate the native sender and resolve to a principal (via 08 binding).
    /// Rejects unauthenticated / unbindable senders.
    fn authenticate(&self, ev: &InboundEvent) -> Result<ExternalUserId, AuthReject>;

    /// Inbound: native event -> canonical Instruction, or Answer if it carries a
    /// CorrelationToken for an open Question.
    fn ingest(&self, ev: InboundEvent, who: ExternalUserId) -> InboundItem; // Instruction | Answer

    /// Outbound: render to native form. render_question mints a CorrelationToken
    /// so the reply routes back to the Question's `gates` node.
    fn render_question(&self, q: &Question) -> (NativeMessage, CorrelationToken);
    fn render_notification(&self, n: &Notification) -> NativeMessage;
}

enum InboundItem { Instruction(Instruction), Answer(Answer) }
````

Authentication *mechanism* per channel (Slack request signing, Telegram webhook/bot-token secret, API OIDC/token) and the `ChannelIdentity → ExternalUserId` binding are owned by `08` (§3.9) and referenced, not redefined, here — exactly as §4.4 already defers authentication to `08`.

---

## 5. Resolved decisions

A design review resolved most of this plane's original open questions. The following are now **normative** design and govern the body above; they are recorded here so the rationale and the prior alternatives remain auditable (`00` §6.6).

1. **Multi-user is first-class (locked).** Metatron supports **concurrent external users from the start**, not a single intent thread. Each principal has its own intent thread, **per-user mailbox** (§3.3), and **authorization scopes** over which goals/budgets it may set or answer for (§2.2, §4.1). The Guardian state machine (§3.1) and the open-question index (§3.3) carry an explicit **tenancy / principal dimension** (`ExternalUserId`), and Step-1 "existing inputs" are **scoped to the relevant user/goal** (§2.3). Conflicting instructions across users on a *shared* goal are routed per §3.7, with the *arbitration policy* itself still open (§6).
2. **External identity is a separate principal type.** `ExternalUserId` is **not** an `AgentId` (the latter is internal, public-key-derived; `00` §7). The **authentication mechanism, identity-to-session binding, and scope issuance are owned by `08-trust-and-security.md`**; this plane *assumes* an authenticated `ExternalUserId` and a resolved set of per-user authorization scopes, and consumes them to admit instructions/answers (§2.2, §4.4).
3. **Timeouts are tiered by blast radius (locked via the liveness fork).** Low-stakes / reversible blocked work **proceeds after a deadline** using the Step-1 best auto-resolution candidate — *reversibly*, emitting a Notification. High-stakes work (constitutional, irreversible — *including the unknown-reversibility case* — or significant budget) is **never silently auto-defaulted**: it follows a **bounded escalation-timeout** and, on expiry, **holds and degrades safely** (stays `Blocked`, never proceeds on the irreversible action) rather than blocking forever. `reversible` is defined operationally in §2.4 (no `mcp-auth-proxy` egress **and** a revertible DAG diff; unknown ⇒ irreversible). See §2.4 and `BlastRadius` (§4.2).
4. **Near-identical questions are coalesced.** `AmbiguityReport`s are clustered by semantic similarity **through the decorrelated council**, **one** Question is raised per cluster, and its single Answer **fans back** to every gated node (and every affected user's mailbox). A **conservative clustering threshold** bounds the false-merge risk (§3.6).
5. **The auto-resolve threshold is per-goal tunable and steering-loop-coupled.** Step 1's confidence threshold is set **per goal** and **tightened when divergence is already high** (coupled to the steering loop, `03`), trading user-interruption rate against silent-misinterpretation rate (relates to calibration in `08`).
6. **A user Answer always wins over a late auto-resolution.** The human is authoritative: if an Answer races a late Step-1 auto-resolution on the same Question, the Answer is applied and any reversible auto-resolution is reverted in its favor (§3.4).
7. **Instruction-vs-committed-state is routed by magnitude.** Small conflict → treat as an ambiguity (gate it, §2.3); medium → a new `Goal` version (setpoint step feeding `03`, §3.2); large → a proposal to **revert** (`02`). See §3.7.
8. **The external boundary is a pluggable Channel Adapter.** The REST surface of §4.4 is **one concrete `ApiAdapter`** over a transport-agnostic contract; any channel (Slack, Telegram, SMS, …) is a `ChannelAdapter` implementation (§4.5) that authenticates a channel-native sender, resolves it to an `ExternalUserId` via the `08` binding table (§3.9), normalizes inbound events to `Instruction`/`Answer`, and renders `Question`/`Notification` best-effort with an explicit **correlation token**. Adapters **declare** capabilities (`ChannelCapabilities`); there is **no negotiation handshake** and the correlation token is **not** an authorization credential (§3.8). The core types and the Guardian state machine are unchanged.

---

## 6. Open questions & ambiguities

Per `00` §9, the genuinely-open items are parked here, not silently decided. (Most of this plane's original open questions are now resolved — see §5.)

1. **Cross-user conflict arbitration *values* policy.** §3.7 now fixes both the *mechanism* (route by magnitude) and a **deterministic precedence floor** (authorization rank, then first-committed-wins) so the system can **never mutually deadlock**. What remains open is the *values* layer above that floor: whether a richer rule — explicit ownership, council adjudication, or a values-weighted scheme — *should* override the default precedence in some cases. Any such refinement must preserve the deadlock-free guarantee. **Governance/values-open.** Parked.
2. **Calibrating the question-clustering threshold.** The conservative similarity threshold (§3.6) **bounds but does not eliminate** the false-merge risk of LLM-based clustering (two genuinely-different ambiguities merged, so one is answered wrong). Where exactly to set it is **empirical** — it must be tuned against observed false-merge and over-asking rates (`07`). Parked.
3. **Cross-channel identity linking.** By default each `(channel_kind, native_id)` binds to its own `ExternalUserId` (§3.8, §4.5; binding owned by `08` §3.9), so the same human on Slack vs Telegram is two principals. The `ChannelIdentity → ExternalUserId` **indirection** makes it possible to later collapse several channel identities onto one principal **without changing the adapter contract**, but *when* and *how* to link — and whether per-channel trust should carry different authorization weight — is deferred. **Governance/identity-open.** Parked.

---

## 7. Relationships to other specs

| Spec | Relationship |
|------|--------------|
| **`00-overview.md`** | Canonical anchor. Guardian role (§3), Mailbox glossary entry, plane table (§2), the closed-loop diagram (§5: "Guardians surface a question … the affected work blocks until answered"), and the canonical types (`Proposal`, `AgentId`, `Hash`, `LogicalTime`, `ErrorVector`) all originate there and are reused verbatim. |
| **`01-state-model.md`** | The Interaction plane *writes into the progress layer* via proposals. The canonical "open question" object is a **progress-layer node** (`01` lists "open questions" as progress-layer content); the Mailbox `Question` is its user-facing projection, linked by the `gates: Hash` edge. Blocking/unblocking flips that node's `Blocked ↔ Ready` state. `LogicalTime` ordering comes from here. |
| **`02-consensus.md`** | Guardians *author* the typed `Proposal`s that this plane produces (goal seeding, answer resolutions, escalation relays); the Genesis council disposes. **Consensus escalations** (deadlock, high dispersion) surface to the user through this plane's Mailbox as Questions/Notifications. The Step-1 auto-resolve "consult the council" query is a decorrelated read using `02` machinery. |
| **`03-control-loop.md`** | The **Goal defines the setpoint/target state** the steering loop steers toward (§3.2). The Setpoint schema (§4.1) is produced here and consumed there. **Control-loop escalations** (infeasible goal, flatlined progress) surface through the Mailbox. Blocked nodes are reported to `03` as *stalled-by-design*, kept distinct from the `divergence`/`progress` error terms so blocking does not look like failure. |
| **`04-runtime-and-harness.md`** | Workers (running under harnesses) are the most frequent *raisers* of `AmbiguityReport`s (§3.5). A raised ambiguity pauses that Worker's unit of work; the Answer/resolution resumes it. |
| **`07-observability.md`** | The Mailbox logs (§3.3) and question lifecycle (§3.4) are a telemetry source: interruption rate, auto-resolve hit-rate, mean time-to-answer, and blocked-node counts are observability signals. Sentinels may watch for Guardians over-interrupting the user (a drift signal). |
| **`08-trust-and-security.md`** | Owns external identity & authorization (§5 decision 2): how `ExternalUserId` authenticates, how its session binds, how per-user **authorization scopes** are issued, and how answer-authorization is checked — the external-vs-internal trust boundary. **Also owns the `ChannelIdentity → ExternalUserId` binding table (§3.9) that each Channel Adapter (§4.5) resolves through.** This plane *assumes* an authenticated `ExternalUserId` and resolved scopes and consumes them; `08` defines how they come to be. The Mailbox is the system's outermost trust boundary. |
