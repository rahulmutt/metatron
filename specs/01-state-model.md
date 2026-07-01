# Metatron — State Plane: The Layered World-Model & Merkle History

> **Status:** Research architecture specification (v0.1)
> **Owning plane:** State (see `00-overview.md` §2).
> **Canonical anchor:** `00-overview.md`. This spec elaborates the State-plane types named there (`Hash`, `Commit`, `WorldModel`) and defines `TypedDiff`, `LogicalTime`, and the storage substrate. Where this document and the anchor disagree on a shared type's name or shape, **the anchor wins** and this document is in error.
> **Reads:** Consumed by `02-consensus.md` (writes commits), `03-control-loop.md` (reads error signals derived from state), `04-runtime-and-harness.md` (reconciles against the configuration layer), `07-observability.md` (taps the history), `08-trust-and-security.md` (owns identity/signing referenced here).

---

## 1. Purpose

The State plane is Metatron's **system of record**. It answers exactly four questions, verifiably, for any reader at any time:

1. **What is the system right now?** — the *current* layered world-model at the head.
2. **How did it get there?** — the immutable, replayable history of accepted state updates.
3. **Can I trust that answer?** — every byte is content-addressed and every accepted update is signed by a Genesis quorum, so integrity and provenance are checkable offline.
4. **What was the history of one thing?** — the evolution of a single agent, sub-goal, artifact, or task, extracted without replaying everything else.

It owns the canonical **System State**, which per the anchor (§4) is a **layered world-model** with two layers — **configuration** (the agent org-chart) and **progress** (progress toward the user's goal) — versioned **together in one Merkle history**. It owns the representation of a **state update** as a **typed, schema-validated diff** (`TypedDiff`). It owns the **storage substrate**: a content-addressed, hash-linked log with BLAKE3 addresses, realized by an **off-the-shelf content-addressed store** (git or a hash-chained append-only table) rather than a bespoke engine or a naive blockchain (§5.10).

The State plane is deliberately **passive and mechanical**. It does *not* decide what is true — that is Governance's job (`02`). It does *not* measure error — that is the steering loop's job (`03`). It does *not* run agents — that is Execution's job (`04`). It stores, addresses, validates the *shape* of, signs-check, serializes, and serves. The discipline that keeps Metatron auditable is precisely that this plane has no opinions: it records what consensus decided, exactly, forever.

This is design principle #6 from the anchor — *Record everything immutably* — made concrete.

### 1.1 Non-goals

- **Not consensus.** Vote aggregation, posterior computation, deliberation, and the acceptance threshold live in `02`. This plane only *applies* an already-accepted update and *verifies* the quorum signatures on it.
- **Not identity.** Keypairs, `AgentId` derivation, signature schemes, key rotation, and reputation live in `08`. This plane defines only the *hooks* (the `signatures` field, the `AgentId` references, the verification predicate it calls).
- **Not the controller.** This plane *exposes* queries that the controller reads to compute the `ErrorVector`; it does not compute that vector.
- **Not execution truth.** The world-model is *desired* + *recorded* state. The gap between recorded progress and physically-true progress (e.g. a file an executor claims to have written) is reconciled in `04` and measured in `07`.

---

## 2. Concepts

### 2.1 The layered world-model

The canonical anchor type (verbatim from `00-overview.md` §7):

```rust
/// The layered world-model root.
struct WorldModel {
    configuration: Hash,         // org-chart layer root
    progress: Hash,              // task/goal layer root
}
```

A `WorldModel` is *just two content addresses*. It is itself a node in the DAG, so a `WorldModel` has its own `Hash` (its `state_root`, referenced from `Commit.state_root`). The two layers are independent subtrees that share the same storage substrate and are advanced together by every commit, but are addressed independently so that an update touching only one layer **structurally shares** the other layer's entire subtree with the parent commit (it copies the parent's `Hash` for the untouched layer — see §2.4, §4.5).

```
            Commit (signed, content-addressed)
                       │ state_root
                       ▼
                  WorldModel
                  ┌────┴─────┐
        configuration       progress
         (org-chart)        (toward goal)
              │                  │
   ┌──────────┼────────┐    ┌────┴───────────┐
 agents    wiring   roles  task-graph  artifacts  open-questions
```

#### Configuration layer — the agent org-chart

This layer **is the agent taxonomy as data** (anchor §3: *"The taxonomy is state."*). It records which agents exist and how they are wired. "Spawn a Worker" and "rewire the team" are ordinary `TypedDiff`s against this layer, decided by consensus.

Its nodes:

- **`AgentNode`** — one per live agent: its `AgentId`, `role` (Guardian | Genesis | Worker | Compiler | Sentinel per anchor §3), an optional `class` (sub-typing within a role, e.g. a Worker's specialty), its **harness binding** (which `AgentHarness` from `04` it runs on, plus negotiated `CapabilitySet`), its **JIT tier** (`Tier` from anchor §7, owned by `05`), and the set of **assigned sub-goals** (references into the progress layer).
- **`WiringEdge`** — a directed relationship between agents: supervision, delegation, review, mailbox routing. The org-chart is a graph, not a tree, so wiring is first-class edges rather than a parent pointer.
- **`KernelSet`** — the privileged Guardian/Genesis membership. Mutations here are **constitutional amendments** (anchor §6) and the diff is flagged so `02` applies the ¾ threshold instead of ⅔. The State plane records the flag; it does not enforce the threshold.

#### `AgentNode` — the one deliberately shared aggregate

Metatron's model is otherwise **plane-sliced**: each plane owns its own state, and "clean slices" is the default. `AgentNode` is the **single intentional exception** — one aggregate, deliberately co-owned, that every plane needs to touch. We make this explicit rather than letting the slice framing imply the planes hold fully disjoint state: they do not, *here, by design*. The State plane owns the **container** (its content-addressing, history, and recorded lifecycle); the other planes own **fields within it**, grouped by owning plane:

| Owning plane | Fields of `AgentNode` (see §3.2 for the struct) | Why it lives here |
|---|---|---|
| **State (01, this plane)** | `id`, `status` (recorded lifecycle), structural placement in the org-chart | State owns the node itself: it is content-addressed, versioned, and replayable like any other node. |
| **Governance (02 / kernel)** | `role`, `class`, and whether the agent is in `KernelSet` | Authority to author/vote derives from role and kernel membership; a Guardian/Genesis change is constitutional. |
| **Execution (04 / 05)** | `harness` (`HarnessBinding` + `CapabilitySet`, `04`), `tier` (`05`) | How and where the agent actually runs; reconciled by the execution backend. |
| **Interaction (06)** | `assigned` (refs to sub-goals) | The bridge to the user-goal decomposition authored through the mailbox. |
| **Observability (07)** | `reputation_ref` (owned by `08`, referenced advisorily), history taps | `07` reads the agent's commit history and the advisory reputation pointer; never canonical. |

This is a common and sound pattern — **one aggregate with per-concern sections** — and stating it openly avoids the false impression that the planes are fully disjoint. The fields still have single owners (the table above); only the *container* is shared.

#### Progress layer — progress toward the goal

This layer records *what has been accomplished*, independent of *who is doing it*.

Its nodes:

- **`GoalNode`** — the user's normalized goal (from a Guardian, `06`) and its decomposition into **sub-goals**. A sub-goal carries a `status` (`Open | Assigned | Blocked | Resolved | Abandoned`).
- **`TaskNode`** — a unit of work in the **task graph**, with dependency edges (`TaskEdge`) to other tasks, a `status`, and a back-reference to the sub-goal it serves and (optionally) the assigned agent.
- **`ArtifactRef`** — a content-addressed pointer to a produced artifact (a blob `Hash` plus metadata: kind, producer, the task that produced it). Large artifact *bytes* may live out-of-band (see §5.6); the world-model holds the `Hash` and provenance.
- **`OpenQuestion`** — an ambiguity surfaced to the user via the mailbox (`06`). Carries `status` (`Pending | Answered | Withdrawn`) and, once answered, a reference to the answering user instruction. The anchor's "affected work blocks until answered" (§5) is represented here: a `TaskNode` may declare a `blocked_on: OpenQuestion` edge.

#### Why two layers, one history

Configuration and progress change for different reasons and on different cadences (the org-chart restructures rarely; progress churns constantly), so separating them gives clean structural sharing and lets a reader subscribe to one layer's evolution cheaply. But they are **causally entangled** — assigning a sub-goal mutates both an `AgentNode` (configuration) and a `GoalNode` (progress) — and an auditor must be able to ask *"what did the system look like, in full, at commit C?"* and get a single consistent answer. Versioning them in **one** Merkle history under **one** head gives both layers a single global order and a single atomic unit of change (the commit). A `TypedDiff` that touches both layers is applied atomically: either the new `WorldModel{configuration', progress'}` is committed whole, or nothing is.

### 2.2 The state update as a typed diff

Per anchor §6 principle #1 (*Constrain the output space*) and §7, an agent never writes free text into the system of record. The only way the world-model changes is a **`TypedDiff`**: a sequence of typed, schema-validated operations on org-chart nodes and progress nodes. The `TypedDiff` is the `diff` field of a `Proposal` (anchor §7). The State plane defines the `TypedDiff` representation (§4.2) and the function that **applies** a validated diff to a `WorldModel` to yield a new `WorldModel`. Consensus (`02`) decides *whether* to apply it; this plane defines *how*.

A `TypedDiff` is **not** a free-form JSON patch and **not** a textual file diff. It is a closed algebra of operations whose operands are typed world-model nodes. This is what makes updates machine-checkable (principle #2, *Determinism-first*): the diff's *well-formedness* (does it reference real nodes? are the types right? does it respect invariants?) is **verified, not voted on**.

### 2.3 The commit and the single head

Per anchor §7, verbatim:

```rust
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
```

A commit is the atomic unit of history. It binds together, in one content-addressed, signed object: the **prior state** (`parent`), the **new state** (`state_root`), the **cause** (`proposal`), the **justification of acceptance** (`decision`), the **authorship** (`author`), the **logical time** (`timestamp`, §2.5), and the **authority** (`signatures`, a Genesis quorum).

The chain of `parent` pointers is the **history**. Because every field is hashed into the commit's address, the chain is tamper-evident: changing anything in any historical commit changes its `Hash`, which changes the `parent` of its child, which cascades to the head. (This is the Merkle property; §3.1.)

**The head is serialized.** Per the anchor glossary: *"Head — the single current commit; consensus serializes the head, so forks are transient."* There is exactly one current head at any logical instant. Competing proposals may transiently form **sibling candidate commits** that share a `parent`, but the consensus vote selects at most one to become the new head; the losers are discarded (§4.6). Therefore Metatron's history is a **chain of accepted commits** embedded in a DAG of content-addressed *nodes* (world-model subtrees are a DAG; the *commit* spine is linear). There are **no permanent forks to reconcile** — this is the property that lets the State plane be a simple append-and-advance store rather than a CRDT/fork-merge engine.

> **Write-path tiering.** The single, serialized, audited head is the **system of record** and earns its keep — there is exactly one ordered log. But not every advance pays for full council consensus. **Routine, reversible advances** — worker spawns, progress-layer status churn — land via **cheap optimistic concurrency on the head** (the per-node preconditions of §4.3) under **single-Guardian authority + post-hoc audit**, bypassing a full vote. **Full council consensus is reserved for high-blast-radius / irreversible / constitutional changes.** The State plane is the mechanism (one serialized head, optimistic CAS); the *gating* of which tier a diff takes is owned by **`02`** (consensus) and **`00`** (the blast-radius tiering), not re-specified here.

> **Terminology.** "Merkle DAG" (anchor §1, §7) refers to the **content-addressed node graph** — world-model layers, nodes, and artifacts form a DAG with heavy structural sharing. The **commit history** is a linear chain within that graph. Both statements are true simultaneously: nodes form a DAG; accepted commits form a chain.

### 2.4 Content addressing & structural sharing

Every node — `Commit`, `WorldModel`, `AgentNode`, `TaskNode`, `ArtifactRef`, a `TypedDiff`, a `Decision` record, an artifact blob — is **content-addressed** by the BLAKE3 hash of its canonical serialization (§4.1). Identical content has an identical address, everywhere, forever. Three consequences this plane exploits:

- **Deduplication.** Two agents with identical harness bindings, or two commits that leave the progress layer untouched, store the shared subtree exactly once.
- **Structural sharing across commits.** A commit that edits one `TaskNode` deep in the progress tree re-stores only the nodes on the path from that task to the `progress` root (path-copying); every sibling subtree is referenced by its unchanged `Hash`. The configuration root is copied by reference if untouched. So a commit costs *O(depth of change)*, not *O(size of world-model)*.
- **Cheap equality & diffing.** "Did the configuration layer change between C₁ and C₂?" is a single `Hash` comparison of the two `WorldModel.configuration` fields. Sub-tree diffing recurses only where hashes differ.

### 2.5 Logical time

`Commit.timestamp: LogicalTime`. Wall-clock time is **insufficient and unsafe** as the canonical ordering for Metatron, for reasons intrinsic to the substrate:

- **Async, distributed agents.** Genesis members, Guardians, and executors may run on different machines/harnesses with **unsynchronized, skewing, or adversarially-set clocks** (anchor §1: agents are *probabilistically Byzantine*). A wall-clock timestamp is an unverifiable claim by the author.
- **Causality, not chronology, is what we must preserve.** What history must encode is *"this state was built on that state"* — a happened-before relation — not *"this happened at 14:03:07.221 UTC"*. The `parent` pointer already encodes causality for the commit spine; `LogicalTime` makes it a totalizable scalar.
- **Determinism of replay.** Replaying the DAG (§3.4) must yield a single canonical order regardless of when or where replay happens. A logical clock derived from the structure does that; wall-clocks do not.

So Metatron uses a **logical clock** as canonical and treats wall-clock as advisory metadata only. The minimal model (§4.7) is exactly **one monotonic counter plus one human-readable hint**: a **Lamport-style counter** monotonic along the commit chain — `head.timestamp = parent.timestamp + 1` — giving every accepted commit a unique, gap-free, totally-ordered logical index. Because the head is serialized (§2.3), there is a single writer of the next index, so the simple scalar counter is **canonical and sufficient** for the *spine*; the per-author vector clock **and** the once-proposed separate Hybrid Logical Clock are both **dropped** as surplus machinery (§4.7, §5.8). Wall-clock survives only as the single **advisory** `wall_hint` inside the `decision` record (for human-facing displays and `07`), explicitly **not** load-bearing for ordering or verification.

### 2.6 Verifiability & replayability

Two distinct guarantees, both owned here:

- **Integrity verification (static).** Given a head `Hash` and the set of reachable nodes, a reader can verify the *entire* history offline: recompute every node's address from its bytes and check it matches its referenced `Hash` (Merkle integrity), and check that each commit's `signatures` are a valid Genesis quorum over its content (authority; predicate defined in `08`). No trusted server required.
- **Replay / re-derivation (dynamic).** Given the genesis commit and the ordered chain of `TypedDiff`s (each reachable via `Commit.proposal`), a reader can **re-derive** every intermediate `WorldModel` by applying diffs in logical-time order, and check that each derived `state_root` matches the `state_root` recorded in the corresponding commit. This proves the recorded states are exactly the consequence of the recorded, accepted updates — nothing was injected out of band. (§3.4.)

These two together make the history **self-certifying**: it carries its own proof of integrity and its own proof of derivation.

---

## 3. Detailed design

### 3.1 The Merkle DAG, and why it is *not* a blockchain

Metatron's store is a **content-addressed Merkle DAG** in the lineage of Git and IPLD, with **BLAKE3** content addresses. The anchor is emphatic (§1) that it is *"optimized for this use case, NOT a naive blockchain."* The contrast is load-bearing, so we make it explicit:

| Property | Naive blockchain | Metatron State plane |
|---|---|---|
| **How the next block/commit is chosen** | Mining: proof-of-work / proof-of-stake lottery; expensive by design to make forking costly. | **The Genesis council *is* the consensus** (defined in `02`). A commit becomes head because a reputation-weighted Genesis quorum signed it — *deliberation, not computation*. **No PoW, no mining, no puzzle.** |
| **Forks** | Permanent forks possible; "longest/heaviest chain" rule reconciles them after the fact; reorgs happen. | **Head is serialized → forks are transient only.** Competing proposals briefly form sibling candidates; the vote picks one; losers are discarded immediately (§4.6). **No reorgs, no permanent forks to reconcile.** |
| **Data model** | Linear chain of opaque blocks; full replication of all transactions. | **DAG of typed nodes with structural sharing** between the two layers and across commits (§2.4). The two layers dedup against each other and across history. |
| **Storage growth** | Append-only, unbounded, immutable by ideology. | Append-only logically, but with **snapshotting, history compaction, and pruning** (§3.5). Old detail can be summarized into a signed snapshot and reclaimed. |
| **Trust model** | Trustless among anonymous adversaries; Sybil-resistance via cost. | Known, identified, **reputation-weighted** Genesis members (`08`); Sybil-resistance via identity + kernel membership, not via burning energy. |
| **Lookup** | Often O(scan) without external indexes. | **Fast content-addressed lookup**: any node by its `Hash` in ~O(1); any layer subtree directly from a `WorldModel` root. |
| **Purpose of the hash chain** | Make rewriting expensive. | Make rewriting **detectable** (tamper-evidence) and make state **deduplicated, shareable, and replayable**. |

So we keep the *good* parts of the blockchain idea — content addressing, hash-linked tamper-evidence, immutable-by-default audit trail, signatures — and discard the parts that exist only to coordinate trustless anonymous miners (mining, fork reconciliation, unbounded full replication), because Metatron has a known, governed, voting council instead.

```
   content-addressed node graph (a DAG; structural sharing everywhere)
   ───────────────────────────────────────────────────────────────────

   C0 ◀──parent── C1 ◀──parent── C2 ◀──parent── C3   ← commit spine (a CHAIN)
   │              │              │              │
   │state_root    │state_root    │state_root    │state_root
   ▼              ▼              ▼              ▼
   WM0            WM1            WM2            WM3
   ├cfg: K0       ├cfg: K0  ◀────┼cfg: K0  ◀────┤cfg: K1   (cfg shared C1→C2,
   └prog:P0       └prog:P1       └prog:P2       └prog:P3    changed at C3)
                       ▲              ▲
                       └─ P1,P2 share unchanged progress subtrees by Hash
```

### 3.2 The configuration layer in detail

```rust
/// Root of the org-chart layer. Content-addressed.
struct ConfigLayer {
    agents:  MerkleMap<AgentId, Hash>,   // AgentId -> AgentNode hash
    wiring:  MerkleSet<Hash>,            // set of WiringEdge hashes
    kernel:  Hash,                       // KernelSet node (constitutional)
    schema_version: u16,                 // codec version, retained for replay (see §5.5)
}

struct AgentNode {
    id:        AgentId,                  // public-key-derived (08)
    role:      Role,                     // Guardian|Genesis|Worker|Compiler|Sentinel
    class:     Option<ClassTag>,         // sub-type within a role
    harness:   HarnessBinding,           // which AgentHarness (04) + CapabilitySet
    tier:      Tier,                     // Tier0/1/2 (anchor §7; owned by 05)
    assigned:  MerkleSet<SubGoalId>,     // refs into the progress layer
    status:    AgentStatus,              // Provisioning|Active|Quiescing|Retired
    reputation_ref: Option<Hash>,        // pointer to reputation record (08); advisory
}

struct WiringEdge {
    from: AgentId,
    to:   AgentId,
    kind: WiringKind,                    // Supervises|Delegates|Reviews|Routes
}

struct KernelSet {
    guardians: MerkleSet<AgentId>,
    genesis:   MerkleSet<AgentId>,
    // quorum policy parameters that 02 reads (thresholds live in 02's config,
    // but the *membership* that the threshold is computed over lives here).
}
```

`MerkleMap` / `MerkleSet` are content-addressed, balanced, hash-keyed collections (a HAMT or Merkle-search-tree, §4.4) giving O(log n) point update with path-copying structural sharing — the property that makes a one-agent edit cheap.

Notably, `reputation` itself is *not stored inline* and is not part of what makes a config commit canonical — it is owned by `08`, changes on a different cadence, and is referenced advisorily so that reputation churn does not thrash the configuration history.

**Budget allocations (`10`).** The `BudgetTree` — the governed global→class→agent cost-allocation hierarchy — is part of the configuration layer: allocations are ordinary typed diffs, versioned and governed like any other config change. Their *spend* counterpart is deliberately **not** here — measured consumption lives in the runtime accounting ledger (`07`) and is never written to the Merkle log. This keeps the desired(allocation)/actual(spend) split aligned with the rest of the model, so metering never touches the write path.

### 3.3 The progress layer in detail

```rust
/// Root of the progress layer. Content-addressed.
struct ProgressLayer {
    goal:      Hash,                      // root GoalNode
    tasks:     MerkleMap<TaskId, Hash>,   // task graph nodes
    artifacts: MerkleMap<ArtifactId, Hash>,
    questions: MerkleMap<QuestionId, Hash>,
    schema_version: u16,
}

struct GoalNode {
    statement:  Text,                     // normalized user goal (from 06)
    subgoals:   MerkleMap<SubGoalId, SubGoal>,
}

struct SubGoal {
    id:       SubGoalId,
    statement: Text,
    status:   SubGoalStatus,              // Open|Assigned|Blocked|Resolved|Abandoned
    assignee: Option<AgentId>,            // mirror of config-layer assignment
}

struct TaskNode {
    id:        TaskId,
    serves:    SubGoalId,
    deps:      MerkleSet<TaskId>,         // task-graph edges (must be acyclic; invariant I4)
    status:    TaskStatus,                // Todo|InProgress|Done|Failed|Cancelled
    assignee:  Option<AgentId>,
    blocked_on: Option<QuestionId>,       // anchor §5: blocks until answered
    artifacts: MerkleSet<ArtifactId>,     // produced by this task
}

struct ArtifactRef {
    id:        ArtifactId,
    blob:      Hash,                      // content address of the bytes (may be out-of-band, §5.6)
    kind:      ArtifactKind,
    producer:  AgentId,
    by_task:   TaskId,
}

struct OpenQuestion {
    id:        QuestionId,
    prompt:    Text,                      // surfaced to the user via mailbox (06)
    status:    QuestionStatus,            // Pending|Answered|Withdrawn
    answer:    Option<Hash>,              // ref to the answering user instruction (06)
}
```

### 3.4 Applying a diff, and replay

The State plane defines a single pure function at the heart of the plane:

```rust
/// Pure, deterministic. No I/O, no clocks, no randomness.
/// Returns the new WorldModel root, or a typed error if the diff is ill-formed
/// against `base` (dangling ref, type mismatch, invariant violation).
fn apply(base: &WorldModel, diff: &TypedDiff, store: &impl NodeStore)
        -> Result<WorldModel, DiffError>;
```

`apply` is **total, deterministic, and side-effect-free** given the immutable `store`. This is what makes both *verification* and *replay* possible:

- **Commit-time** (`02` calls it): given the accepted proposal's diff and the current head's `WorldModel`, compute the new `WorldModel`, content-address it as the new `state_root`, and write the `Commit`. (The acceptance decision and signatures come from `02`/`08`; this plane just applies + addresses + appends.)
- **Replay-time** (any reader): start from genesis `WorldModel` (the empty/bootstrap model under `C0`), fold `apply` over the chain of diffs in logical-time order, and assert at each step that the derived `state_root` equals the recorded `Commit.state_root`. Any mismatch is a proof of corruption or unauthorized injection.

```
replay:  WM0 ──apply(d1)──▶ WM1' ?= C1.state_root
                 WM1 ──apply(d2)──▶ WM2' ?= C2.state_root
                          WM2 ──apply(d3)──▶ WM3' ?= C3.state_root
         (✓ at every step  ⇒  history is exactly the consequence of accepted diffs)
```

Because `apply` is deterministic and content addresses are collision-resistant, a single matching `state_root` at the head is *strong* evidence the whole derivation is intact; checking every intermediate step gives the exact corruption point if not.

### 3.5 Snapshotting, compaction, and pruning

> **Deferred (§5.10).** The mechanisms in this section — snapshots, compaction, pruning — are **dropped/deferred for v0.1**: they are satellites of the bespoke store, replaced by the chosen off-the-shelf store's own retention/reclamation. The section is retained for design context, not as committed v0.1 scope.

A naive blockchain keeps every transaction forever. Metatron does not have to, because verification can be re-anchored to a **signed snapshot**.

- **Snapshot.** A `SnapshotCommit` is a special commit whose `state_root` is a *fully materialized* `WorldModel` (all reachable nodes present, no reliance on ancestor-only nodes) and which is signed by a Genesis quorum *attesting that replay from the previous snapshot reproduces this state_root*. A snapshot is a new trust anchor: readers may verify from the latest snapshot forward instead of from genesis.
- **Compaction.** Between snapshots, the *detailed* history (individual diffs, decision records, superseded node versions) can be **summarized**: e.g. fifty progress-layer churns that net to "sub-goal 7 resolved, 3 artifacts produced" can be archived behind the snapshot. The snapshot preserves the *state*; compaction trades away *intermediate replay granularity* for space.
- **Pruning.** Once a snapshot is established and a retention policy elapses, nodes that are (a) unreachable from any retained head/snapshot and (b) older than the retention horizon may be **garbage-collected**. Pruning is a governed, consensus-proposed operation with *differential per-layer retention* (configuration is permanent, progress is prunable — §5.1); unreachable-node reclamation is epoch-based mark-and-sweep from retained anchors (§5.2).

The key invariant: **pruning never removes a node reachable from a retained trust anchor**, and **every retained head remains fully verifiable from the nearest snapshot**. What you lose by pruning is the ability to replay *below* the snapshot — a deliberate, governed trade. Snapshots are **permanent signed trust anchors** and do not age out (§5.1).

### 3.6 Querying the store

The State plane exposes read APIs (§4.8). Two canonical queries called out by the anchor mandate:

- **"Current world-model."** Resolve `head` → `Commit.state_root` → `WorldModel{configuration, progress}`. From there, any node by content-addressed lookup, or whole-layer materialization. O(1) to the roots; O(nodes touched) to materialize a region.
- **"History of an agent / sub-goal."** Two strategies, both supported:
  - *Spine scan with hash short-circuit.* Walk the commit chain from head to genesis; at each commit, compare the relevant subtree `Hash` (e.g. the `AgentNode` hash for that `AgentId`, reached through the config layer's `MerkleMap`) against the previous commit's. The agent's history is exactly the commits where that hash changed — found cheaply because unchanged spans share a hash and are skipped in O(1) per commit.
  - *Secondary index (derived, untrusted-but-rebuildable).* An observability-side index (`07`) mapping `AgentId`/`SubGoalId` → list of commits that touched it, for O(1) lookup. This index is a **cache**: it is never canonical and is always rebuildable by the spine scan, so corrupting it cannot corrupt history.

A sub-goal's history is the same pattern keyed by `SubGoalId` through the progress layer; an artifact's provenance is the `ArtifactRef.producer`/`by_task` chain.

---

## 4. Interfaces & schemas

### 4.1 Canonical serialization & addressing

```rust
type Hash = [u8; 32];          // BLAKE3-256 (anchor §7)

/// Every storable node implements this. Addressing is over the CANONICAL
/// encoding, so the same logical value always hashes identically.
trait ContentAddressed {
    fn canonical_bytes(&self) -> Vec<u8>;          // deterministic codec (§ below)
    fn hash(&self) -> Hash { blake3_256(&self.canonical_bytes()) }
}
```

**Canonicalization rules** (so identical content ⇒ identical hash, the bedrock of dedup and verification):

- A fixed, deterministic binary codec (e.g. DAG-CBOR-style) with **sorted map keys**, no insignificant whitespace, fixed integer widths, and **no floats in addressed structures** (reputation/posteriors are stored in the `decision` record, not in the addressed world-model spine; if a float must be addressed it is encoded as a fixed-precision rational/decimal).
- Child references are encoded **as their `Hash`**, never inlined, so a node's bytes are bounded and structural sharing is automatic.
- The codec version is pinned per node via `schema_version`; older codecs are retained for bit-exact replay, migrations are governed diffs, and a snapshot may re-canonicalize to the current codec as a signed re-anchoring (§5.5).

### 4.2 The TypedDiff algebra

The concrete representation of a state update. A `TypedDiff` is an **ordered, atomic batch** of typed operations; either the whole batch applies or none does. Operations are partitioned by target layer.

```rust
struct TypedDiff {
    target: Layer,                 // Configuration | Progress | Both (anchor: Proposal.target_layer)
    ops:    Vec<DiffOp>,           // applied in order, atomically
    pre:    Vec<Precondition>,     // optimistic-concurrency guards (§4.3)
    constitutional: bool,          // set iff ops touch KernelSet; 02 applies ¾ threshold
}

enum Layer { Configuration, Progress, Both }   // anchor §7

enum DiffOp {
    // ---- Configuration-layer ops (org-chart) ----
    SpawnAgent      { node: AgentNode },
    RetireAgent     { id: AgentId },
    RebindHarness   { id: AgentId, harness: HarnessBinding },
    SetTier         { id: AgentId, tier: Tier },                 // authored by Compiler flow (05)
    AssignSubGoal   { agent: AgentId, subgoal: SubGoalId },
    UnassignSubGoal { agent: AgentId, subgoal: SubGoalId },
    AddWiring       { edge: WiringEdge },
    RemoveWiring    { edge: WiringEdge },
    AmendKernel     { change: KernelChange },                    // constitutional

    // ---- Progress-layer ops (toward goal) ----
    SetGoal         { goal: GoalNode },
    AddSubGoal      { subgoal: SubGoal },
    SetSubGoalStatus{ id: SubGoalId, status: SubGoalStatus },
    AddTask         { task: TaskNode },
    SetTaskStatus   { id: TaskId, status: TaskStatus },
    AddTaskDep      { task: TaskId, dep: TaskId },               // must keep DAG acyclic (I4)
    RecordArtifact  { artifact: ArtifactRef },
    OpenQuestion    { question: OpenQuestion },                  // blocks dependent tasks
    AnswerQuestion  { id: QuestionId, answer: Hash },            // unblocks (06)
    WithdrawQuestion{ id: QuestionId },
}
```

**Schema validation** is the determinism-first check (anchor principle #2). Before consensus even votes (`02`), and again at `apply`-time, a `TypedDiff` is checked against the **structural invariants**; only diffs that pass are *valid to apply*. The vote concerns *desirability*, not *well-formedness* — the latter is checked, never voted on.

| ID | Invariant (checked at validate + apply) |
|----|-----------------------------------------|
| **I1** | Every referenced node id (`AgentId`, `SubGoalId`, `TaskId`, …) resolves in `base` (no dangling refs), except for ids freshly introduced earlier in the same `ops` batch. |
| **I2** | Type/role rules: e.g. `AssignSubGoal` targets an existing agent and existing sub-goal; `SetTier` targets an agent; you cannot `SpawnAgent` with an `AgentId` already present. |
| **I3** | `constitutional` is set **iff** any op mutates `KernelSet` (`AmendKernel`, or spawning/retiring a Guardian/Genesis). Mismatch ⇒ invalid. (Protects the ¾ threshold from being dodged.) |
| **I4** | Task-graph dependency edges remain **acyclic** after the batch (the progress task graph is a DAG). |
| **I5** | Status transitions are legal (e.g. a `Resolved` sub-goal cannot go back to `Open` without an explicit reopening op; a `Done` task cannot be `Failed`). State machines defined per node type. |
| **I6** | A task with a `Pending` `blocked_on` question may not transition to `InProgress`/`Done` (enforces anchor §5 blocking). |
| **I7** | `target` declared on the diff matches the layers actually touched by `ops`. |

`apply` (§3.4) re-checks I1–I7 against `base` and additionally enforces atomicity: a failure on any op aborts the whole batch with a `DiffError` and produces no new state.

### 4.3 Optimistic concurrency: preconditions

Multiple Guardians may author proposals concurrently against the same head. Consensus serializes *acceptance*, but a diff authored against head Hₙ might be applied after the head has already advanced to Hₙ₊₁ by another accepted proposal. To make `apply` safe under this, a `TypedDiff` carries **preconditions** — a compare-against expected hashes, evaluated at apply-time:

```rust
enum Precondition {
    NodeUnchanged { id: NodeRef, expected: Hash },   // this node still has this hash
    HeadIs        { expected: Hash },                 // strict: only apply onto this exact head
    LayerUnchanged{ layer: Layer, expected: Hash },   // whole-layer guard
}
```

If a precondition fails at apply-time, the diff is **rejected as stale** (a `DiffError::Stale`) and `02` may re-base and re-vote, or the controller may re-derive a fresh proposal. This is how Metatron avoids lost updates *without* permanent forks: stale candidates simply do not become head. The **default granularity is per-node `NodeUnchanged`** (optimistic concurrency: non-overlapping diffs both land), with conflict *detection* mechanical here and *resolution* deferred to governance — no structural auto-merge (§5.3).

### 4.4 Merkle collections

> **Deferred (§5.10).** This bespoke collection engine — and the unresolved "HAMT or MST" leaf choice below — is **dropped**: keyed lookup, per-path history, and structural sharing come from the off-the-shelf content-addressed store. The `MerkleMap`/`MerkleSet` types below are read as the *logical* keyed-collection abstraction the store realizes, not a structure Metatron hand-builds.

```rust
/// Content-addressed, hash-keyed map with O(log n) path-copying update.
/// Realized as a HAMT or Merkle Search Tree. Two maps are equal iff their
/// root hashes are equal; diffing recurses only where child hashes differ.
struct MerkleMap<K, V> { root: Hash, /* ... */ }
struct MerkleSet<T>    { root: Hash, /* ... */ }
```

These give the structural-sharing and cheap-diff properties (§2.4) to the agent map, task map, wiring set, etc. An update to one entry re-stores O(log n) interior nodes; the rest is shared by hash with the parent commit.

### 4.5 Store traits

```rust
/// The content-addressed blob store. Immutable, append-only at this layer;
/// GC/pruning (§3.5) is an out-of-band, policy-governed operation.
trait NodeStore {
    fn put(&self, bytes: &[u8]) -> Hash;            // idempotent: dedup by content
    fn get(&self, h: &Hash) -> Option<Vec<u8>>;     // O(1) content-addressed lookup
    fn has(&self, h: &Hash) -> bool;
}

/// The head register: the one mutable cell in the whole plane.
/// Advanced only by the head-advance protocol (§4.6), which 02 drives.
trait HeadRegister {
    fn head(&self) -> Hash;                          // current Commit hash
    /// CAS the head: succeeds iff current head == expected. The serialization point.
    fn advance(&self, expected: Hash, next: Hash) -> Result<(), HeadCasError>;
}
```

The entire mutability of the State plane is concentrated in **one compare-and-swap** on the head register. Everything else is immutable content-addressed storage. This is what makes "the head is serialized" a mechanical fact rather than a hope: two candidate commits racing to advance the head both call `advance(expected, …)` with the same `expected`; the CAS lets exactly one win.

### 4.6 The head-advance protocol & transient forks

How a winning proposal becomes head, and how a loser's transient fork is discarded:

```
1. Guardians author proposals P_a, P_b, ... each against current head H_n.
   (Authorship/normalization in 06; we only care that diff is valid here.)

2. For each accepted-by-vote proposal (decision from 02), the State plane:
   a. validates the diff against H_n's WorldModel (I1–I7, preconditions §4.3);
   b. computes WM_{n+1} = apply(WM_n, diff);            // pure (§3.4)
   c. stores all new nodes via NodeStore.put (dedup);   // candidate subtree
   d. builds candidate Commit C_x { parent: H_n, state_root: hash(WM_{n+1}),
        proposal, decision, author, timestamp: H_n.time + 1, signatures };
   e. attempts HeadRegister.advance(expected = H_n, next = hash(C_x)).

3. Exactly ONE advance() succeeds (CAS). That C_x is the new head H_{n+1}.

4. Every losing candidate C_y:
   - shares H_n as parent  ⇒  it formed a TRANSIENT sibling fork;
   - its advance() failed (expected H_n, but head is now H_{n+1});
   - it is DISCARDED as head. Its nodes were content-addressed writes; any
     that are now unreferenced become GC candidates (§3.5, §5.2).
   - 02 may re-base C_y's proposal onto H_{n+1} and re-run, subject to the
     diff's preconditions (a stale precondition forces an explicit re-derive).
```

```
        ┌── C_a (candidate)   advance(exp=Hn) ─▶ ✗ stale  ──▶ discarded
   Hn ──┤
        └── C_b (candidate)   advance(exp=Hn) ─▶ ✓ wins    ──▶ becomes H(n+1)
                                                              (single head)
```

Crucially, the fork is **never written to the head** and is **never reconciled** — there is no merge, no reorg, no longest-chain rule. The only durable artifact of a losing candidate is some content-addressed nodes that may be GC'd. This is the mechanical realization of the anchor's *"forks exist only transiently among competing proposals and are resolved by the vote."*

> The *ordering* of which accepted proposals even get to race, and how `02` schedules them, is Governance's concern. The State plane guarantees only: (i) at most one head advance per logical tick, (ii) advance is a CAS against the expected parent, (iii) `apply` is deterministic, so any party can recompute the winner's `state_root`.

### 4.7 LogicalTime

```rust
/// Canonical ordering for the commit spine. NOT wall-clock (§2.5).
/// Exactly one monotonic counter + one human-readable hint (§5.8, OE-04).
struct LogicalTime {
    index: u64,        // Lamport counter; head.index = parent.index + 1, gap-free
    // The per-author VersionVector (`vclock`) is DROPPED (§5.8): candidate
    // causality never needs more than "same parent ⇒ concurrent".
    // A separate HybridLogicalClock is also DROPPED — see WallHint below.
}

/// The single human-readable hint. Advisory only — never load-bearing for
/// ordering or verification (§2.5). Lives in the decision record (02).
struct WallHint { unix_millis: u64, source: AgentId }
```

The `index` totally orders accepted commits (the spine is linear, so it is gap-free and unique), and because the head is serialized there is a single writer of the next index — the scalar suffices and the `vclock` is **dropped** (§5.8). For human-readable timelines the **`WallHint`** (advisory, non-canonical) in the decision record is the single human hint, used by `07` for display and correlation; no separate logical display clock is carried.

### 4.8 Read / query interface

```rust
trait StateReader {
    // --- current state ---
    fn head(&self) -> Hash;
    fn world_model(&self, commit: Hash) -> WorldModel;          // resolve a commit's state_root
    fn current(&self) -> WorldModel { self.world_model(self.head()) }
    fn config_layer(&self, wm: &WorldModel) -> ConfigLayer;
    fn progress_layer(&self, wm: &WorldModel) -> ProgressLayer;
    fn node<T: ContentAddressed>(&self, h: Hash) -> Option<T>;  // O(1) by content address

    // --- history (anchor-mandated queries) ---
    fn commit(&self, h: Hash) -> Commit;
    fn parent_chain(&self, from: Hash) -> impl Iterator<Item = Commit>;  // head→genesis
    /// Commits that changed a given agent's node (spine scan w/ hash short-circuit, §3.6).
    fn agent_history(&self, id: AgentId) -> Vec<Hash>;
    /// Commits that changed a given sub-goal.
    fn subgoal_history(&self, id: SubGoalId) -> Vec<Hash>;
    /// Provenance of an artifact: producer agent + producing task + commit.
    fn artifact_provenance(&self, id: ArtifactId) -> ArtifactProvenance;

    // --- verification (§2.6) ---
    /// Recompute every reachable node's address; check it matches. Integrity.
    fn verify_integrity(&self, from: Hash) -> IntegrityReport;
    /// Re-derive each state_root by replaying diffs; check it matches. Replay.
    fn verify_replay(&self, from_snapshot: Hash, to: Hash) -> ReplayReport;
    /// Check each commit's quorum signatures (predicate defined in 08).
    fn verify_authority(&self, from: Hash) -> AuthorityReport;
}
```

### 4.9 Write interface (driven by `02`)

```rust
trait StateWriter {
    /// Validate a diff against the current head's world-model (I1–I7 + preconditions).
    fn validate(&self, diff: &TypedDiff) -> Result<(), DiffError>;
    /// Build (but do not yet head) a candidate commit for an accepted proposal.
    fn stage(&self, accepted: AcceptedProposal) -> Result<Candidate, DiffError>;
    /// Attempt to make a staged candidate the new head (CAS, §4.6).
    fn commit(&self, c: Candidate) -> Result<Hash /*new head*/, HeadCasError>;
    /// Create a signed snapshot trust anchor (§3.5); Genesis-quorum signed.
    fn snapshot(&self) -> Result<Hash, SnapshotError>;
}
```

The State plane never *originates* a write. `02` (consensus) calls `validate` → `stage` → `commit` for an accepted proposal; `08` supplies the signatures and the quorum-verification predicate; `06` originates the proposals that `02` decides on. This plane's job is to make those operations deterministic, content-addressed, atomic, and verifiable.

### 4.10 Identity & signing hooks (owned by `08`)

This plane defines only the *hooks*; the mechanisms are in `08-trust-and-security.md`.

```rust
type AgentId = Hash;          // public-key-derived identity (anchor §7; defined in 08)
struct Signature(/* ... */);  // anchor §7; scheme defined in 08

// The hooks this plane CALLS but does not IMPLEMENT:
//   verify_quorum(commit_bytes, &commit.signatures, &kernel.genesis) -> bool   [08]
//   verify_sig(node_bytes, &sig, author_id) -> bool                            [08]
// A commit is "authoritative" iff verify_quorum returns true over a Genesis
// quorum drawn from the KernelSet *as of the parent commit* (avoids the council
// re-authorizing its own membership change in the same step). EXCEPTION: a
// Byzantine-removal AmendKernel must be co-ratified by the POST-change kernel
// set too — a dual-set signature (§5.4).
```

The State plane treats signatures as **opaque blobs it stores and feeds to `08`'s verifier**. It enforces structurally only that the `signatures` field is present and that `verify_authority` (§4.8) is run during verification; it makes no cryptographic decisions itself.

---

## 5. Resolved decisions

A design review closed the structural tensions previously parked here. Each item below is now **committed, normative design**. The body sections above remain authoritative; these decisions refine and bind them. They are stated as decided design, not as questions. **§5.10 (adopt an off-the-shelf content-addressed store) supersedes and marks deferred several earlier items here** — read §5.1, §5.2, §5.5, §5.7 as deferred under §5.10. No genuinely-open design parameter remains (§6).

### 5.1 Pruning is governed, with differential retention

Pruning is a **consensus-proposed operation** — a state-affecting act authored as a proposal and decided by `02` like any other change, never an unprivileged background sweep. Retention is **differential by layer**:

- The **configuration layer is the permanent constitutional record.** The org-chart/kernel history is never pruned below the snapshot line; it is the audit trail of how authority evolved.
- The **progress layer is prunable** past a retention horizon. High-churn, low-long-term-value detail (superseded task/artifact churn) may be compacted and reclaimed once a snapshot covers it.

**Snapshots are permanent, signed trust anchors** — they do not age out. (Refines §3.5.)

### 5.2 Garbage collection: epoch-based mark-and-sweep from retained anchors

GC of unreachable nodes (losing candidates §4.6, superseded versions) is **epoch-based mark-and-sweep**, not refcounting (refcounting is unsafe under content dedup and under concurrent staging).

- The **root set** is the retained trust anchors: all **snapshots**, the **current head**, and **in-flight candidate commits**.
- GC **never collects before the next snapshot** establishes a fresh anchor.
- An **epoch guard** protects nodes that a not-yet-committed candidate will reference, so staging a candidate cannot race a sweep.
- **GC is itself a recorded, signed maintenance operation** — reclamation is part of the auditable history, not an invisible side effect.

(Refines §3.5, §4.6.)

### 5.3 Concurrent Guardians: mechanical detect, governance resolve

The **default precondition granularity is per-node `NodeUnchanged`** (§4.3), not strict `HeadIs` — optimistic concurrency, so two **non-overlapping** diffs against the same head both land.

- **Conflict detection is mechanical** — a State-plane operation (the apply-time precondition compare).
- **Conflict resolution is governance** — a losing diff simply **fails stale** (`DiffError::Stale`) and `02` re-bases or re-derives. The plane makes no merge judgment.
- **No structural auto-merge.** 3-way structural merge of concurrent diffs is explicitly out of scope; *forks-are-transient* (§2.3) stands.

(Refines §4.3.)

### 5.4 Kernel-change window: dual-set signature for Byzantine removal

A commit is signed by the **kernel set as of the parent** (§4.10) — the council does not re-authorize its own membership change in the same step. The **one exception** is a **Byzantine-removal `AmendKernel`**, which must additionally be **co-ratified by the post-change kernel set**: a **dual-set signature** in which both the pre-change set and the surviving post-change set sign. This prevents a compromised member from blocking their own removal while still grounding authority in a legitimate set. Co-designed with `08`. (Refines §4.10; the `AmendKernel` op, §4.2.)

### 5.5 Schema/codec evolution: retain codecs, govern migrations, re-anchor at snapshot

- **Versioned codecs are retained for replay.** A node written under an older `schema_version` is replayed with the codec it was written under, so replay (§3.4) stays bit-exact.
- **Migrations are governed diffs** — a schema change is a typed, consensus-decided state update, not an out-of-band rewrite.
- A **snapshot MAY re-canonicalize** the materialized state to the current codec as a **deliberate, signed re-anchoring.** This changes hashes below the snapshot by design, and the re-anchoring is itself recorded.

(Refines §4.1, §3.5.)

### 5.6 Artifact residency: hash always committed, bytes may resolve lazily

- The artifact's **content `Hash` is always in the commit** (`ArtifactRef.blob`) — provenance integrity is never optional.
- **Large blob bytes MAY resolve lazily out-of-band** (object store, executor filesystem, via `04`).
- A commit is **valid with an addressed-but-dangling blob.** The system of record commits to *what* the artifact is, not to physically holding its bytes.

Stated explicitly: **verifiable-by-address ≠ retrievable.** The hash proves identity and provenance offline; retrieval is a separate, best-effort `04`/object-store concern. (Refines §3.3 `ArtifactRef`, §4.5.)

### 5.7 Verification is incremental from the latest snapshot

`verify_integrity`/`verify_replay` (§4.8) run **incrementally/streaming from the latest snapshot forward**, not from genesis. Snapshots are the verification anchor, so steady-state cost is bounded by inter-snapshot history rather than total history. A **periodic full re-verification from genesis runs as a background audit** (defense-in-depth), decoupled from the hot path. (Refines §2.6, §3.5, §4.8.)

### 5.8 Logical clock: one monotonic counter + one human hint (drop `vclock` and the HLC)

The three-clock apparatus is reduced to exactly **one monotonic counter plus one human-readable hint** (OE-04):

- The scalar **Lamport `index` remains canonical** (§4.7): the serialized head gives a single writer, so a gap-free scalar totally orders the spine — sufficient.
- The **`vclock` / `VersionVector` is dropped.** Candidate causality never needs more than "same parent ⇒ concurrent," so the per-author vector is unused weight.
- The once-proposed **separate Hybrid Logical Clock is also dropped.** Human-readable timelines are served by the advisory **`WallHint`** already carried in the decision record (§4.7) — explicitly non-authoritative — so a second display clock is surplus machinery, not a concrete need.

This also settles `07`'s clock question: `07` orders displays by `WallHint`, never by a load-bearing clock. (Refines §2.5, §4.7.)

### 5.9 Storage: one content-addressed store, separate retention namespaces (`07` cross-ref)

The immutable **event log** and the **Merkle DAG share one content-addressed store** — a single immutable truth, joined by the commit's content address (`CommitHash`) — with **separate retention namespaces**, so configuration-vs-progress retention (§5.1) and log-vs-DAG compaction are governed independently over the same underlying blobs. This answers the `07` storage cross-reference. (Refines §3.1, §4.5; cross-refs `07`.)

### 5.10 Storage engine: adopt an off-the-shelf content-addressed store (OE-04)

The State plane is the system of record for an artifact this very spec proves is a **signed, single-writer, linear chain** of commits (§2.3, §3.1). Building a bespoke content-addressed database under a linear log is over-built for v0.1, so the storage substrate is realized by an **off-the-shelf content-addressed store — git, or a hash-chained append-only table** — not a hand-rolled engine. Off the shelf we get exactly the load-bearing properties: **content-addressing, tamper-evidence (hash-linking), structural sharing, and per-path history.**

**Kept — these earn their keep and remain fully normative:**

- The **typed-diff algebra** (§4.2): the closed, schema-validated operation set is what makes updates machine-checkable and is independent of how bytes are stored.
- The **invariant checks** I1–I7 (§4.2) and the deterministic `apply` (§3.4): verification and replay of the *logical* state are properties of the diff algebra, not of the store.
- The content-addressed signed-log model itself (§2.3, §2.6), `LogicalTime` reduced to one counter + one hint (§5.8), and the optimistic-concurrency preconditions (§4.3) the store backs with a compare-and-swap on its head ref.

**Dropped / deferred — not load-bearing for a v0.1 signed linear log; off-the-shelf or later concerns:**

- The **bespoke HAMT / Merkle-Search-Tree collection engine** (§3.2, §4.4). This also **resolves the unresolved "HAMT or MST" non-decision by removing it** — the off-the-shelf store provides keyed lookup and per-path history directly; Metatron picks no bespoke leaf structure.
- **Path-copying as a hand-implemented mechanism** (§2.4): structural sharing comes from the store, not from code Metatron maintains.
- **Epoch GC** (§5.2), **snapshots / compaction** (§3.5), **differential per-layer retention** (§5.1), and **versioned-codec replay** (§5.5). These are deferred; where retention or reclamation is needed it is an operational concern of the chosen store (e.g. `git gc`, table partition retention), governed but not bespoke-built. **Snapshot-anchored incremental verification (§5.7)** likewise becomes an optimization deferred behind the store's own capabilities — full integrity/replay over a v0.1 linear log is cheap.

The decision is to adopt the off-the-shelf store; no concrete v0.1 requirement was found that git or a hash-chained table cannot meet. This decision **supersedes and marks deferred** §5.1, §5.2, §5.5, §5.7 and the bespoke machinery they refine; the §5.9 "one content-addressed store" intent is satisfied directly by the chosen substrate. (Refines §1, §2.4, §3.1, §3.2, §3.5, §4.4, §4.5; supersedes §5.1, §5.2, §5.5, §5.7.)

---

## 6. Open questions & ambiguities

The design review (§5) closed the structural questions. The one previously-open tuning parameter has since been **deferred along with the machinery it parameterized**:

1. **Snapshot cadence / retention horizons — deferred (§5.10).** This used to trade incremental verification/replay cost against snapshot-production overhead and prunable-history depth (snapshots §3.5, retention §5.1, incremental verification §5.7). With the adoption of an **off-the-shelf content-addressed store** (§5.10), snapshots, compaction, and differential retention are dropped/deferred for v0.1, so this is no longer a Metatron design parameter: any future retention/compaction tuning becomes an **operational setting of the chosen store** (e.g. `git gc` cadence, table partition retention), not a substrate to be designed on paper.

---

## 7. Relationships to other specs

| Spec | Relationship |
|------|--------------|
| **`00-overview.md`** | Canonical anchor. This spec elaborates `Hash`, `Commit`, `WorldModel` (verbatim shapes) and `LogicalTime`; defines `TypedDiff` (referenced by `Proposal.diff`). Honors §3 *"the taxonomy is state,"* §4 layered world-model, §6 principles #1/#2/#6, and the §7/glossary statements that the **head is serialized** and **forks are transient**. |
| **`02-consensus.md`** | The **only writer** through this plane. Defines `Proposal`, `Vote`, `Decision`; drives `validate → stage → commit` (§4.9) and the head-advance CAS (§4.6). The Genesis council *is* the consensus that replaces mining (§3.1). Supplies the `decision` hash and the quorum that signs each commit. Owns the acceptance threshold (⅔ / ¾); this plane only records the `constitutional` flag. |
| **`03-control-loop.md`** | A **reader**. Computes the `ErrorVector` from world-model queries (progress distance from the progress layer; divergence from `Decision.dispersion`; cost/latency from `07`). Emits control actions that become the *next* proposals `02` decides on. Does not write state directly. |
| **`04-runtime-and-harness.md`** | A **reader** of the configuration layer: `ExecutionBackend.reconcile(desired, actual)` reads desired org-chart state from the world-model and drives Workers via harnesses toward it. The *gap* between recorded progress and physical reality is `04`'s reconciliation concern, not this plane's. `HarnessBinding` referenced in `AgentNode` is defined there. |
| **`05-agent-jit.md`** | Produces `SetTier` diffs (Compiler flow) that this plane applies to `AgentNode.tier`. `Tier` is the anchor §7 enum, owned by `05`; stored here as configuration. |
| **`06-interaction-and-mailbox.md`** | Guardians (its agents) author the `TypedDiff`s this plane applies. The `OpenQuestion`/`AnswerQuestion` ops and the `blocked_on` invariant (I6) realize the anchor §5 "block until answered." Normalized user goals become `GoalNode`/`SubGoal`. |
| **`07-observability.md`** | Taps the history. Builds the *derived, rebuildable* secondary indexes (§3.6) for fast `agent_history`/`subgoal_history`; correlates the advisory `WallHint`. Never canonical — always reconstructable from the spine, so it cannot corrupt the record. |
| **`08-trust-and-security.md`** | Owns `AgentId` derivation, the `Signature` scheme, the `verify_quorum`/`verify_sig` predicates this plane calls (§4.10), reputation (referenced advisorily from `AgentNode`), and the Byzantine-response policy behind kernel amendments (dual-set co-ratification, §5.4). This plane defines only the hooks. |
