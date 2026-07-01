# Metatron — Architecture Overview

> **Status:** Research architecture specification (v0.1)
> **Audience:** System designers and implementers of Metatron.
> **Scope:** This document is the canonical anchor for the entire spec set. It defines the vision, the planes, the agent taxonomy, the closed-loop data flow, the cross-cutting design principles, the shared glossary, and the canonical interfaces every other spec must reference. When any other spec disagrees with this one on vocabulary or a shared type, this one wins.

---

## 1. Vision

> **The core idea — hold this first; everything below is implementation framing.**
> Metatron is a **deliberative governor wrapped around a reconciliation loop.** Changes
> to the system are **authored by one set of agents (Guardians) and decided by a separate
> council (Genesis)** — *propose ≠ dispose* — and **anything machine-checkable is verified
> deterministically before anyone votes** — *verify-before-vote*. That small mechanism is
> the whole load-bearing idea. The domain analogies that follow (Kubernetes reconciliation,
> control-theoretic steering, an optimizing JIT, a Condorcet jury, a Merkle/identity layer)
> are *implementation framings* layered on this core — each is **skippable on first read**.
> The table at the end of this section states how much of each analogy is actually
> load-bearing.

Metatron is a **principled, extensible orchestration platform for multi-agent systems**. It descends from systems like Gas Town (Steve Yegge), Agent Hub (Andrej Karpathy), and Symphony (OpenAI), but it makes three commitments those systems do not:

1. **Govern, don't dictate.** Instead of a single "Mayor," Metatron is governed by a *council* of **Genesis** agents that reach **consensus** over how the system should evolve. The multi-agent structure itself is an outcome of deliberation, recorded immutably.
2. **Treat agents as an unreliable substrate, and engineer around it.** LLM-backed agents drift, hallucinate, and go off-protocol. Metatron treats a multi-agent system as **probabilistically Byzantine** and applies an explicit protocol — constrain, verify, decorrelate, weight, deliberate — to *tame that nondeterminism* rather than wish it away.
3. **Close the loop; steer on measured error.** An external user sets a target. Metatron **steers** the system toward that target on a **measured error vector** (progress, cost, divergence, latency, …) — a per-dimension *proportional* response gated by deadband/hysteresis/cooldown, never on hope. (The full PID apparatus — integral/derivative terms, anti-windup, Ziegler–Nichols tuning, a MIMO gain matrix — is *framing*, **deferred until a measured oscillation demands it**; see `03` and issue OE-01.)

Two further commitments make it *extensible like Kubernetes*:

- **Abstract over execution.** An agent is a *role + goal + policy* bound to an **`AgentHarness`** (Claude Code, Codex, Cursor, Aider, …). Metatron orchestrates *above* harnesses; it does not re-implement one. Execution itself runs behind an **`ExecutionBackend`** trait with two reference implementations: in-process Rust actors, and Kubernetes CRDs.
- **Abstract over the storage of system evolution.** Every change to the system is a signed, content-addressed commit in a **Merkle DAG**, giving a verifiable, replayable history of how the system became what it is.

And one commitment that ties it all together — **the JIT principle**: any agent whose behavior has stabilized earns cheaper execution — from a live LLM loop (the "interpreter", Tier-0) to a **memoized** input→action policy guarded by **traps** that **deoptimize** back to the LLM when an assumption breaks (Tier-1). (Tier-2 — *generalizing* a stabilized policy into freshly **synthesized** deterministic code — is **deferred** until its equivalence metric exists and Tier-1 is shown insufficient; see `05` and issue OE-03.)

The core system is implemented in **Rust**.

**How much of each analogy is load-bearing.** The framings above are pedagogically useful but unequally earned. Read this before taking any one metaphor literally:

| Analogy | Load-bearing? | What actually ships |
|---------|---------------|---------------------|
| **Kubernetes reconciliation** | **Yes** | The execution loop genuinely reconciles reality toward committed desired-state. |
| **Control theory / PID** | **Mostly framing** | Load-bearing part is "steer on measured error": a *proportional* response + deadband/hysteresis/cooldown. Full PID (I/D, anti-windup, Ziegler–Nichols, `Γ`) is deferred (OE-01). |
| **Optimizing JIT** | **Yes at the mechanism level** | Interpreter/guard/deopt for Tier-0 + Tier-1. Tier-2 code synthesis is deferred (OE-03). |
| **Condorcet / BFT jury** | **Partly — assumption-conditional** | Decorrelation + weighting are real, but voter independence is only approximate; **correlated failure is the headline residual risk** (ROB-02). |
| **Merkle DAG / distributed identity** | **Framing for storage & identity** | The content-addressed signed log is load-bearing; the *bespoke* DAG store is replaced by an off-the-shelf content-addressed store (OE-04), and the SPIFFE/SPIRE PKI ceremony is gated behind multi-cluster (OE-06). |

---

## 2. The Five Planes

Metatron separates *concerns* into five planes, echoing the Kubernetes control-plane/data-plane split. "Separation" here means each plane owns a distinct **concern and its logic** — it does **not** mean the planes own fully disjoint *state*. The central `AgentNode` object is a deliberately **shared aggregate** carrying fields touched by every plane (grouped by owning plane); this one intentional exception is documented in `01-state-model.md` §2.1. Treat the planes as a decomposition by concern, not as disjoint data silos.

```
┌─────────────────────────────────────────────────────────────┐
│  INTERACTION PLANE   user instructions in · ambiguity         │
│                      mailbox + notifications out              │
│                      (Guardian agents)                        │
├─────────────────────────────────────────────────────────────┤
│  GOVERNANCE PLANE    Genesis council · consensus protocol ·   │
│                      typed proposals · steering loop          │
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
| Governance | Proposals, consensus, the steering loop | `02-consensus.md`, `03-control-loop.md` |
| State | The world-model, the Merkle history | `01-state-model.md` |
| Execution | Harness orchestration, backends, JIT | `04-runtime-and-harness.md`, `05-agent-jit.md` |
| Observability | Telemetry that taps every plane | `07-observability.md` |

Trust and identity (signing, reputation, sandboxing, Byzantine response, agent identity & external-tool authorization) cut across every plane and are specified in `08-trust-and-security.md`. The separately-deployed **`mcp-auth-proxy`** — the gateway through which agents safely perform privileged external actions without ever holding downstream secrets — is specified in `09-mcp-auth-proxy.md`.

---

## 3. Agent Taxonomy

Five roles, designed as a **separation of powers** (proposer ≠ voter, so no agent both authors and decides a change):

| Role | Power | Responsibility |
|------|-------|----------------|
| **Guardian** | *Propose* | User-facing. Normalize instructions into goals; detect ambiguity; decide whether existing user inputs already resolve it; own the mailbox; author **typed proposals**. The user's advocate. |
| **Genesis** | *Dispose* | The governance council. Deliberate + vote on proposals via the consensus protocol; reach consensus over state updates. Does **not** author proposals — only judges them. |
| **Worker** | *Execute* | The task-doers; each is a role+goal bound to an `AgentHarness`. The bulk of the org-chart. Ephemeral; spawned/wired by consensus. |
| **Compiler** | *Optimize* | Perform JIT tiering: observe stable Worker behavior, synthesize Tier-1/Tier-2 policies, install deopt guards. |
| **Sentinel** | *Watch* | Detect off-protocol/out-of-character behavior, drift, and trap rates; feed reputation, the observability plane, and the steering loop's divergence signal. A single Sentinel finding cannot, by itself, move reputation/vote weight — findings require k-of-n corroboration (ROB-06). |

**Planes and roles are different decompositions — not a 1:1 grid.** The five planes (§2) decompose the system by *concern*; the five roles decompose it by *power*. The matching count is coincidental, and the mapping is deliberately **not** one-to-one: the **State plane has no owning role** (it is maintained by consensus, not any single agent class), and the **Execution plane has two** (Worker *and* Compiler). Do not read the two five-item lists as parallel rows of one table.

**Checks-and-balances cycle:** Guardians propose → Genesis disposes → Workers execute → Sentinels watch → Compilers optimize → measurements feed the steering loop → next proposal.

**Kernel vs. dynamic roles.** Guardian and Genesis are the privileged **kernel** roles, established at bootstrap. Workers, Compilers, and Sentinels are instantiated dynamically under consensus. Changing kernel membership is a **constitutional amendment** with a higher consensus threshold (see §6).

**The taxonomy is state.** Which agents exist and how they are wired *is* the configuration layer of the world-model (§4). "Spawn a worker" and "rewire the team" are ordinary typed diffs decided by consensus.

---

## 4. The System State (layered world-model)

The canonical **System State** is a **layered world-model** with two layers, versioned together in one Merkle history:

- **Configuration layer** — the agent org-chart: which agents exist, their roles/classes, their wiring, their assigned sub-goals, and their JIT tier.
- **Progress layer** — progress toward the user's goal: the task graph, artifacts produced, sub-goals resolved, open questions.

A **state update** is a **typed diff** that touches one or both layers. Consensus and the steering loop operate on whichever layer a proposal touches. Full schema in `01-state-model.md`.

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
        │                          Steering loop: error vector      │
        │                                  │                        │
        └──────────────────────────────────┘  control actions ──▶ (next proposal)
```

The system has **two nested loops** (kept terminologically distinct — see Glossary):

- the **execution / reconciliation loop** — the execution plane drives *actual* state toward the *committed* desired state (Kubernetes-style); it owns convergence of **reality → committed desired-state**;
- the **steering loop** — the deliberative governor moves *desired* state by authoring proposals the council accepts; it is nested *around* the reconciliation loop and owns convergence of **desired-state → user target**.

So: the council sets desired state by consensus; reconciliation drives actual state toward it; observability measures the gap; the steering loop turns the measured error vector into control actions that become the next proposals.

**Not every advance pays for full consensus.** Consensus cost is tiered by **blast radius** (see `02`): routine, reversible advances — worker spawns, progress-layer updates — proceed under a **single Guardian with post-hoc audit** and optimistic concurrency on the head, while a full blind-vote council round is **reserved for high-blast-radius, irreversible, or constitutional** proposals.

When ambiguity or a high-stakes gate blocks progress, Guardians surface a question to the user via the mailbox; the affected work **waits under a bounded escalation timeout and then degrades safely** (it never silently proceeds on an irreversible action — see `06`), rather than blocking indefinitely.

---

## 6. Cross-cutting Design Principles

These principles recur throughout the specs. They exist to **tame the nondeterminism of LLM-backed agents**.

1. **Constrain the output space.** Agents act through *typed, schema-validated* artifacts (proposals, diffs), never free text into the system of record. You cannot be nondeterministic in a space you are not allowed to express.
2. **Determinism-first.** Anything machine-checkable is *checked, not voted on*. LLM judgment is the fallback reserved for the genuinely subjective. (This is also the philosophical root of the JIT: collapse to determinism wherever you can.)
3. **Decorrelate to tame nondeterminism.** Independent, diverse agents fail in independent ways; by the Condorcet jury theorem, aggregating independent better-than-random judgments drives error toward zero. Heterogeneous harnesses and blind (isolated-first) voting are the mechanisms. Premature discussion is an anti-pattern: it *correlates* errors. **Caveat:** independence is only ever *approximate* — agents sharing a base model fail together — so this is a **mitigation, not a guarantee**. **Correlated, confidently-wrong agreement is the headline residual risk** (ROB-01/ROB-02); measured base-model/harness diversity is an *operational precondition* for treating a quorum as independent, not an assumption.
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
    dispersion: f32,             // how split the council was -> feeds steering-loop divergence
    passed: bool,
    rounds: u32,                 // deliberation rounds used (0 if decided on blind vote)
    verification: VerificationReport,
}

/// The steering-loop error signal: a vector, one component per controlled dimension.
/// NOTE: `divergence` measures council *disagreement*, not *wrongness* — a correlated,
/// confidently-wrong council reads as low divergence (ROB-01). See 03/07 for the
/// verification-coverage companion signal that compensates.
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

// ---- Identity & external-tool authorization (08, 09) ----
/// Stable long-term identity = hash of the agent's long-term public key,
/// recorded in the configuration layer. Decoupled from the *rotatable*
/// operational signing key, so key rotation does not change the AgentId.
type AgentId = Hash;

/// Crypto-agile, hybrid-composite by default: verification requires BOTH halves.
enum SigScheme { Ed25519, MlDsa, Hybrid(Box<SigScheme>, Box<SigScheme>) } // default Hybrid(Ed25519, MlDsa)
struct Signature { scheme: SigScheme, bytes: Vec<u8> }
struct Reputation(f32);    // calibrated, in [0,1]; class-prior on spawn, decays on drift

/// A quorum of Genesis signatures over a commit. Explicit signer set in v1
/// (needed for reputation accounting + equivocation detection); BLS/FROST
/// aggregation is a future optimization behind this stable interface.
struct QuorumCertificate { signers: Vec<AgentId>, sigs: Vec<Signature>, scheme: SigScheme }

/// SPIFFE Verifiable Identity Document — the short-lived (minutes), auto-rotating
/// operational credential SPIRE issues after the Metatron workload attestor checks
/// the agent against the current head (exists, holds key, above rep floor, not quarantined).
/// NOTE: the SPIRE/attestor issuance path is the *multi-cluster* form. The single-node
/// default issues a short-lived orchestrator-signed token over the same fields, with a
/// polled revocation list; SPIRE is gated behind a multi-cluster trigger (OE-06, see 08).
struct Svid {
    spiffe_id: SpiffeId,         // "spiffe://metatron.<deployment>/agent/<AgentId>/role/<role>"
    agent_id: AgentId,
    operational_key: PublicKey,  // rotatable; rotation does NOT change AgentId
    scopes: Vec<Scope>,          // coarse authorization claims, sourced from the configuration layer
    not_after: LogicalTime,
    issuer_chain: CertChain,     // SPIRE intermediate -> genesis threshold-of-founders root CA
    issuer_sig: Signature,
}
struct Scope { resource: McpServerId, methods: Vec<MethodPattern> }

/// External users are a SEPARATE principal type (NOT AgentId). The system is multi-user.
struct UserPrincipal { id: ExternalUserId, scopes: Vec<AuthorizationScope> }

/// The user-deployed, separately-trusted MCP gateway. Gateway-only: all downstream
/// MCP calls are brokered through it; agents never receive a downstream token.
trait McpAuthProxy {
    fn discover_tools(&self, svid: &Svid) -> ToolList;             // filtered to authorized scopes
    fn invoke(&self, svid: &Svid, call: McpToolCall) -> McpResult; // brokered; credential injected, never returned
}

// ---- Budgets (10) ----
/// Normalized accounting currency: the RD-4 common cost unit
/// (tokens × price + wallclock × rate), tokens dominant. See 04 (RD-4), 07.
type CostUnit = f64;
type CostRate = f64;                 // CostUnit per second

/// The budget hierarchy. Part of the CONFIGURATION layer (01); governed state.
/// Allocation only — measured spend is runtime, in the 07 ledger (never committed).
struct BudgetTree { root: BudgetNodeId, nodes: Map<BudgetNodeId, BudgetNode> }
type BudgetNodeId = Hash;

struct BudgetNode {
    scope:  BudgetScope,             // Global | Class(Role) | Agent(AgentId)
    stock:  StockBudget,
    rate:   RateBudget,
    parent: Option<BudgetNodeId>,    // None at the Global root
}
enum BudgetScope { Global, Class(Role), Agent(AgentId) }   // Role = the 00 §3 taxonomy role

/// Cumulative allocation. `floor` is guaranteed (may be 0); `burst_cap` bounds
/// draw from the shared parent burst pool; `shutdown_reserve` is carved under
/// the cap to fund a clean stop (notify + drain + checkpoint). See 10.
struct StockBudget { floor: CostUnit, burst_cap: CostUnit, shutdown_reserve: CostUnit }

/// Flow allocation as a token bucket: `sustained` = refill rate, `burst_depth` = depth.
struct RateBudget { sustained: CostRate, burst_depth: CostUnit }
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
| **Dispersion** | How split a vote was; fed to the steering loop as the divergence dimension. Measures *disagreement*, not *wrongness* (ROB-01). |
| **Verification coverage** | Fraction of a decision that was machine-verifiable (vs. left to LLM judgment); a first-class control/health signal alongside dispersion (ROB-01; see `07`). |
| **Steering loop** | The governance-level loop: the deliberative governor moves *desired* state by authoring proposals consensus accepts. Steers on a measured error vector (proportional + deadband/hysteresis/cooldown; full PID deferred — OE-01). Nested *around* the reconciliation loop; owns convergence of desired-state → user target. |
| **Reconciliation loop** | The execution-level loop: the `ExecutionBackend` drives *actual* running state toward the *committed* desired state (Kubernetes-style). Owns convergence of reality → committed desired-state. "Reconciliation" refers only to this loop. |
| **Error vector** | The measured gap between desired and actual state, per controlled dimension; the steering loop's input. |
| **AgentHarness** | A wrapped agentic tool (Claude Code, Codex, …) Metatron drives as a black box. |
| **ExecutionBackend** | Where agents run: Rust actors or Kubernetes CRDs. |
| **Tier / JIT / Trap / Deopt** | Execution tier (0 interpreter / 1 memoized / 2 synthesized); compiling stable behavior; a guard; the fallback to a lower tier. v1 ships Tier-0 + Tier-1; **Tier-2 is deferred** (OE-03). |
| **Constitutional amendment** | A change to kernel-role membership; higher consensus threshold. |
| **Mailbox** | The notification/question channel between the system and the user. |
| **External user / `UserPrincipal`** | A human user of the system — a *separate* principal type from `AgentId`. The system is **multi-user**: concurrent users with per-user mailboxes and authorization scopes. |
| **SVID** | A SPIFFE Verifiable Identity Document: an agent's short-lived, auto-rotating operational credential, issued by SPIRE after the Metatron workload attestor validates it against the current head. |
| **Workload attestation** | The check (agent exists in config layer, holds its key, above reputation floor, not quarantined) gating SVID issuance — binding the runtime workload to the governed on-chain identity; also the Sybil gate. |
| **Hybrid-PQ crypto** | Composite classical+post-quantum cryptography: `Ed25519+ML-DSA` signatures, `X25519+ML-KEM` transport. Verification requires both halves. |
| **`mcp-auth-proxy`** | The user-deployed gateway (its own trust boundary, holding the user's secrets) that brokers all agent calls to external MCP servers. **Gateway-only**: agents never receive downstream tokens. |
| **Privilege separation** | The principle that an agent's only long-term secret is its identity key, so compromising an agent never compromises standing secrets. |
| **Budget tree / `BudgetNode`** | The governed global→class→agent hierarchy of cost *allocations*, part of the configuration layer. Spend is measured separately in `07`. (`10`) |
| **Stock budget** | A node's cumulative cost allowance over the goal's life. (`10`) |
| **Rate budget** | A node's flow allowance (cost per unit time), enforced as a token bucket. (`10`) |
| **Shutdown reserve** | Cost carved under a node's cap to fund a clean stop (notify + drain + checkpoint) before the hard cap. (`10`) |
| **Deterministic budget notifier** | An off-budget, non-LLM reflex that emits a typed mailbox alert on stock depletion — self-funding, un-forgeable. (`10`, `06`) |
| **`CostUnit`** | The normalized accounting currency (RD-4: tokens×price + wallclock×rate), the denomination of all budgets. (`10`, `04`, `07`) |

---

## 9. How the specs relate

```
00-overview  (this file — vocabulary + canonical types; everything depends on it)
   │
   ├── 01-state-model ............ defines WorldModel, Commit, Merkle DAG
   │       │
   │       ├── 02-consensus ...... defines Proposal, Vote, Decision (writes commits)
   │       │       │
   │       │       └── 03-control-loop ... defines ErrorVector, steering loop (emits proposals)
   │       │
   │       ├── 06-interaction .... Guardians author proposals; mailbox blocks on ambiguity
   │       │
   │       └── 10-budgets ......... budget tree in config layer; enforcement, notifier
   │
   ├── 04-runtime-and-harness .... AgentHarness, ExecutionBackend (reconciles desired state)
   │       │
   │       └── 05-agent-jit ...... Tier 0/1/2, traps, Compiler + Sentinel
   │
   ├── 07-observability .......... taps every plane; feeds Sentinels + steering-loop estimators
   │
   ├── 08-trust-and-security ..... identity, signing, reputation, sandboxing, Byzantine
   │       │                       response, agent identity & external-tool authorization
   │       │
   │       └── 09-mcp-auth-proxy .. user-deployed gateway; gateway-only brokering of
   │                               privileged external (MCP) actions; no agent-held secrets
   │
   └── (00 overview, this file)
```

Each subsystem spec follows the same structure: **Purpose → Concepts → Detailed design → Interfaces/schemas → Open questions & ambiguities → Relationships.** The *Open questions* section in each is where surfaced ambiguities are parked and tracked.
