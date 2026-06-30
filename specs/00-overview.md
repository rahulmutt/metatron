# Metatron — Architecture Overview

> **Status:** Research architecture specification (v0.1)
> **Audience:** System designers and implementers of Metatron.
> **Scope:** This document is the canonical anchor for the entire spec set. It defines the vision, the planes, the agent taxonomy, the closed-loop data flow, the cross-cutting design principles, the shared glossary, and the canonical interfaces every other spec must reference. When any other spec disagrees with this one on vocabulary or a shared type, this one wins.

---

## 1. Vision

Metatron is a **principled, extensible orchestration platform for multi-agent systems**. It descends from systems like Gas Town (Steve Yegge), Agent Hub (Andrej Karpathy), and Symphony (OpenAI), but it makes three commitments those systems do not:

1. **Govern, don't dictate.** Instead of a single "Mayor," Metatron is governed by a *council* of **Genesis** agents that reach **consensus** over how the system should evolve. The multi-agent structure itself is an outcome of deliberation, recorded immutably.
2. **Treat agents as an unreliable substrate, and engineer around it.** LLM-backed agents drift, hallucinate, and go off-protocol. Metatron treats a multi-agent system as **probabilistically Byzantine** and applies an explicit protocol — constrain, verify, decorrelate, weight, deliberate — to *tame that nondeterminism* rather than wish it away.
3. **Close the loop with control theory.** An external user sets a target. Metatron runs a **multi-variable PID controller** over a measured error vector (progress, cost, divergence, latency, …) to steer the system toward that target, the way a control system steers a plant toward a setpoint.

Two further commitments make it *extensible like Kubernetes*:

- **Abstract over execution.** An agent is a *role + goal + policy* bound to an **`AgentHarness`** (Claude Code, Codex, Cursor, Aider, …). Metatron orchestrates *above* harnesses; it does not re-implement one. Execution itself runs behind an **`ExecutionBackend`** trait with two reference implementations: in-process Rust actors, and Kubernetes CRDs.
- **Abstract over the storage of system evolution.** Every change to the system is a signed, content-addressed commit in a **Merkle DAG**, giving a verifiable, replayable history of how the system became what it is.

And one commitment that ties it all together — **the JIT principle**: any agent whose behavior has stabilized can be **compiled** from a live LLM loop (the "interpreter") into faster, cheaper deterministic code, guarded by **traps** that **deoptimize** back to the LLM when an assumption breaks.

The core system is implemented in **Rust**.

---

## 2. The Five Planes

Metatron separates concerns into five planes, echoing the Kubernetes control-plane/data-plane split.

```
┌─────────────────────────────────────────────────────────────┐
│  INTERACTION PLANE   user instructions in · ambiguity         │
│                      mailbox + notifications out              │
│                      (Guardian agents)                        │
├─────────────────────────────────────────────────────────────┤
│  GOVERNANCE PLANE    Genesis council · consensus protocol ·   │
│                      typed proposals · PID controller         │
├─────────────────────────────────────────────────────────────┤
│  STATE PLANE         layered world-model · Merkle DAG ·        │
│                      content-addressed signed commits         │
├─────────────────────────────────────────────────────────────┤
│  EXECUTION PLANE     agent runtime · JIT tiers · pluggable     │
│                      backends (Rust actors | K8s CRDs)        │
│                      (Worker, Compiler agents)                │
├─────────────────────────────────────────────────────────────┤
│  OBSERVABILITY PLANE traces · metrics · events across all      │
│                      planes (cross-cutting; Sentinel agents)  │
└─────────────────────────────────────────────────────────────┘
```

| Plane | Owns | Primary spec |
|-------|------|--------------|
| Interaction | User intake, goal normalization, ambiguity, mailbox | `06-interaction-and-mailbox.md` |
| Governance | Proposals, consensus, the PID controller | `02-consensus.md`, `03-control-loop.md` |
| State | The world-model, the Merkle history | `01-state-model.md` |
| Execution | Harness orchestration, backends, JIT | `04-runtime-and-harness.md`, `05-agent-jit.md` |
| Observability | Telemetry that taps every plane | `07-observability.md` |

Trust and identity (signing, reputation, sandboxing, Byzantine response) cut across every plane and are specified in `08-trust-and-security.md`.

---

## 3. Agent Taxonomy

Five roles, designed as a **separation of powers** (proposer ≠ voter, so no agent both authors and decides a change):

| Role | Power | Responsibility |
|------|-------|----------------|
| **Guardian** | *Propose* | User-facing. Normalize instructions into goals; detect ambiguity; decide whether existing user inputs already resolve it; own the mailbox; author **typed proposals**. The user's advocate. |
| **Genesis** | *Dispose* | The governance council. Deliberate + vote on proposals via the consensus protocol; reach consensus over state updates. Does **not** author proposals — only judges them. |
| **Worker** | *Execute* | The task-doers; each is a role+goal bound to an `AgentHarness`. The bulk of the org-chart. Ephemeral; spawned/wired by consensus. |
| **Compiler** | *Optimize* | Perform JIT tiering: observe stable Worker behavior, synthesize Tier-1/Tier-2 policies, install deopt guards. |
| **Sentinel** | *Watch* | Detect off-protocol/out-of-character behavior, drift, and trap rates; feed reputation, the observability plane, and the PID divergence signal. |

**Checks-and-balances cycle:** Guardians propose → Genesis disposes → Workers execute → Sentinels watch → Compilers optimize → measurements feed the PID controller → next proposal.

**Kernel vs. dynamic roles.** Guardian and Genesis are the privileged **kernel** roles, established at bootstrap. Workers, Compilers, and Sentinels are instantiated dynamically under consensus. Changing kernel membership is a **constitutional amendment** with a higher consensus threshold (see §6).

**The taxonomy is state.** Which agents exist and how they are wired *is* the configuration layer of the world-model (§4). "Spawn a worker" and "rewire the team" are ordinary typed diffs decided by consensus.

---

## 4. The System State (layered world-model)

The canonical **System State** is a **layered world-model** with two layers, versioned together in one Merkle history:

- **Configuration layer** — the agent org-chart: which agents exist, their roles/classes, their wiring, their assigned sub-goals, and their JIT tier.
- **Progress layer** — progress toward the user's goal: the task graph, artifacts produced, sub-goals resolved, open questions.

A **state update** is a **typed diff** that touches one or both layers. Consensus and the PID controller operate on whichever layer a proposal touches. Full schema in `01-state-model.md`.

---

## 5. The Closed Loop (data flow)

```
        ┌──────────────────────────────────────────────────────────┐
        │                                                          │
  user  │  Guardian          Genesis council        State plane    │
  ─────▶ normalize ─▶ typed ─▶ verify ─▶ blind ─▶ commit ─▶ Merkle  │
 instr. │   goal     proposal  (det.)   vote+      to head  DAG     │
        │     ▲                          deliberate                │
        │     │ ambiguity?                                          │
        │     │ (mailbox)                  │ accepted desired state │
        │   user                           ▼                        │
        │                          Execution plane: reconcile       │
        │                          (Workers via harnesses, JIT)     │
        │                                  │                        │
        │                          Observability: measure           │
        │                                  │                        │
        │                          PID controller: error vector     │
        │                                  │                        │
        └──────────────────────────────────┘  control actions ──▶ (next proposal)
```

The loop is **Kubernetes-style reconciliation** wrapped in a **deliberative, control-theoretic governor**: the council sets desired state by consensus; the execution plane drives actual state toward it; observability measures the gap; the PID controller turns the measured error vector into control actions that become the next proposals. When ambiguity blocks progress, Guardians surface a question to the user via the mailbox and **the affected work blocks until answered**.

---

## 6. Cross-cutting Design Principles

These principles recur throughout the specs. They exist to **tame the nondeterminism of LLM-backed agents**.

1. **Constrain the output space.** Agents act through *typed, schema-validated* artifacts (proposals, diffs), never free text into the system of record. You cannot be nondeterministic in a space you are not allowed to express.
2. **Determinism-first.** Anything machine-checkable is *checked, not voted on*. LLM judgment is the fallback reserved for the genuinely subjective. (This is also the philosophical root of the JIT: collapse to determinism wherever you can.)
3. **Decorrelate to tame nondeterminism.** Independent, diverse agents fail in independent ways; by the Condorcet jury theorem, aggregating independent better-than-random judgments drives error toward zero. Heterogeneous harnesses and blind (isolated-first) voting are the mechanisms. Premature discussion is an anti-pattern: it *correlates* errors.
4. **Weight by calibrated track record.** Reputation, updated against ground truth, lets chronically-drifting agents decay toward zero influence automatically.
5. **Close the loop, measure the error.** Every decision feeds back. The system steers on a measured error vector, not on hope.
6. **Record everything immutably.** System evolution is a verifiable, replayable Merkle history. Monitoring is first-class, not an afterthought.
7. **Compile the hot path, trap on surprise.** Stable behavior earns cheaper deterministic execution; novelty deoptimizes safely back to the LLM.

**Consensus thresholds (defaults, tunable):** ordinary proposals pass at reputation-weighted **⅔**; constitutional (kernel) changes at **¾**.

---

## 7. Canonical Interfaces & Types

These are the shared types every other spec references. They are normative *names and shapes*; each owning spec elaborates the details. Rust-flavored pseudotypes.

```rust
// ---- State plane (01) ----
/// Content address (e.g. BLAKE3) of any node in the Merkle DAG.
type Hash = [u8; 32];

/// A signed, content-addressed commit: one accepted state update.
struct Commit {
    parent: Option<Hash>,        // previous head; None at genesis
    state_root: Hash,            // root of the layered world-model after this update
    proposal: Hash,              // the proposal that produced this commit
    decision: Hash,              // the consensus decision record (votes, posterior)
    author: AgentId,             // Guardian that authored the proposal
    timestamp: LogicalTime,      // logical clock; see 01
    signatures: Vec<Signature>,  // quorum of Genesis signatures
}

/// The layered world-model root.
struct WorldModel {
    configuration: Hash,         // org-chart layer root
    progress: Hash,              // task/goal layer root
}

// ---- Governance plane (02, 03) ----
/// A typed, schema-validated change to the world-model. Never free text.
struct Proposal {
    target_layer: Layer,         // Configuration | Progress | Both
    diff: TypedDiff,             // structured mutation
    rationale: Text,             // human/LLM-readable justification (advisory only)
    author: AgentId,             // a Guardian
    derived_from: Option<Hash>,  // control action or user instruction that prompted it
}

/// One Genesis member's judgment, cast in isolation before any deliberation.
struct Vote {
    proposal: Hash,
    verdict: Verdict,            // Approve | Reject | Abstain
    confidence: f32,             // self-estimated, in [0,1]
    voter: AgentId,
    signature: Signature,
}

/// The outcome of running the consensus protocol on a proposal.
struct Decision {
    proposal: Hash,
    posterior: f32,              // aggregated probability the proposal is correct
    dispersion: f32,             // how split the council was -> feeds PID divergence
    passed: bool,
    rounds: u32,                 // deliberation rounds used (0 if decided on blind vote)
    verification: VerificationReport,
}

/// The PID error signal: a vector, one component per controlled dimension.
struct ErrorVector {
    progress: f32,               // distance to goal completion
    cost: f32,                   // budget pressure
    divergence: f32,             // council/agent disagreement
    latency: f32,                // responsiveness pressure
    // extensible; see 03
}

// ---- Execution plane (04, 05) ----
/// Uniform contract over agentic harnesses (Claude Code, Codex, ...).
trait AgentHarness {
    fn capabilities(&self) -> CapabilitySet;             // negotiated; telemetry is best-effort
    fn run(&self, task: TaskSpec, ctx: Context) -> HarnessResult;
}

/// Where agents actually run.
trait ExecutionBackend {
    fn reconcile(&self, desired: &WorldModel, actual: &WorldModel) -> ReconcilePlan;
    // reference impls: RustActorBackend, KubernetesCrdBackend
}

/// JIT execution tier of an agent (05).
enum Tier {
    Tier0Interpreter,   // pure LLM harness
    Tier1Memoized,      // learned input->action policy (inline cache)
    Tier2Compiled,      // synthesized deterministic code
}

// ---- Identity (08) ----
type AgentId = Hash;       // public-key-derived identity
struct Signature(/* ... */);
struct Reputation(f32);    // calibrated, in [0,1]; decays on drift
```

---

## 8. Glossary

| Term | Meaning |
|------|---------|
| **Metatron** | The whole system. |
| **Plane** | A horizontal separation of concerns (Interaction, Governance, State, Execution, Observability). |
| **Genesis** | A kernel agent that *votes* on proposals. The council disposes. |
| **Guardian** | A kernel agent that interfaces with the user and *authors* proposals. The user's advocate. |
| **Worker / Compiler / Sentinel** | Dynamic agents that execute tasks / perform JIT / monitor behavior. |
| **System State / World-Model** | The versioned `{configuration, progress}` layered model. |
| **Configuration layer** | The agent org-chart (who exists, how wired). |
| **Progress layer** | Progress toward the user's goal (task graph, artifacts). |
| **State update / Proposal** | A typed, schema-validated diff against the world-model. |
| **Commit** | A signed, content-addressed node recording one accepted state update. |
| **Merkle DAG** | The content-addressed, append-only history of commits. |
| **Head** | The single current commit; consensus serializes the head, so forks are transient. |
| **Consensus protocol** | typed → verify → blind vote → reputation-weight → bounded deliberation → posterior+dispersion. |
| **Blind vote** | A vote cast in isolation, before deliberation, to keep errors decorrelated. |
| **Reputation** | A calibrated, decaying measure of an agent's track record against ground truth. |
| **Posterior** | Aggregated probability a proposal is correct; acceptance is a threshold on it. |
| **Dispersion** | How split a vote was; fed to the PID controller as the divergence dimension. |
| **PID controller** | Multi-variable proportional-integral-derivative controller over the error vector. |
| **Error vector** | The measured gap between desired and actual state, per controlled dimension. |
| **AgentHarness** | A wrapped agentic tool (Claude Code, Codex, …) Metatron drives as a black box. |
| **ExecutionBackend** | Where agents run: Rust actors or Kubernetes CRDs. |
| **Tier / JIT / Trap / Deopt** | Execution tier (0/1/2); compiling stable behavior; a guard; the fallback to a lower tier. |
| **Constitutional amendment** | A change to kernel-role membership; higher consensus threshold. |
| **Mailbox** | The notification/question channel between the system and the user. |

---

## 9. How the specs relate

```
00-overview  (this file — vocabulary + canonical types; everything depends on it)
   │
   ├── 01-state-model ............ defines WorldModel, Commit, Merkle DAG
   │       │
   │       ├── 02-consensus ...... defines Proposal, Vote, Decision (writes commits)
   │       │       │
   │       │       └── 03-control-loop ... defines ErrorVector, PID (emits proposals)
   │       │
   │       └── 06-interaction .... Guardians author proposals; mailbox blocks on ambiguity
   │
   ├── 04-runtime-and-harness .... AgentHarness, ExecutionBackend (reconciles desired state)
   │       │
   │       └── 05-agent-jit ...... Tier 0/1/2, traps, Compiler + Sentinel
   │
   ├── 07-observability .......... taps every plane; feeds Sentinels + PID estimators
   │
   └── 08-trust-and-security ..... identity, signing, reputation, sandboxing, Byzantine response
```

Each subsystem spec follows the same structure: **Purpose → Concepts → Detailed design → Interfaces/schemas → Open questions & ambiguities → Relationships.** The *Open questions* section in each is where surfaced ambiguities are parked and tracked.
