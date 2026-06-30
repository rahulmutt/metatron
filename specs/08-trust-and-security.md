# Metatron — Trust & Security

> **Status:** Research architecture specification (v0.1)
> **Audience:** System designers and implementers of Metatron.
> **Scope:** This is the cross-cutting **trust, identity, and security** spec. It *gathers* the trust concerns that other specs reference and depend on but do not own: signed commits (`01-state-model`), reputation and the Byzantine response (`02-consensus`), harness sandboxing and permission hooks (`04-runtime-and-harness`), and the Sentinel detection signal (`07-observability`). It defines *one* identity model, *one* signing scheme, *one* permission model, and *one* threat model for the whole system, and points each owning spec at the relevant piece.
>
> Where this spec and `00-overview` disagree on a shared type or term, **`00-overview` wins**. This spec elaborates; it does not redefine.

---

## 1. Purpose

Metatron's first principle is that LLM-backed agents are an **unreliable substrate**: they drift, hallucinate, and go off-protocol. The overview names the consequence — the system is **probabilistically Byzantine** — and the response — *constrain, verify, decorrelate, weight, deliberate*. That response only holds if three security properties hold underneath it:

1. **Authenticated action.** Every vote, proposal, and commit must be attributable to a specific agent identity, unforgeably. Reputation weighting (`02`) and the separation of powers (proposer ≠ voter) are meaningless if an agent can speak under another's name, or repudiate what it said.
2. **Authorized change.** A change to the world-model — especially a change to *who holds power* (kernel membership) — must clear the consensus threshold appropriate to its blast radius, and must be cryptographically witnessed by the council that approved it.
3. **Contained execution.** Workers run untrusted, third-party agentic harnesses against untrusted user content. Their output must be treated as adversarial until verified, and their blast radius must be bounded by least-privilege capability scoping derived from role.

This spec specifies the mechanisms that deliver those three properties, and lays out the **threat model** they defend against. It does not re-derive the consensus math (that is `02`) or the Merkle structure (that is `01`); it specifies the *cryptographic and trust* layer those mechanisms stand on.

**Design stance.** Security here is not a perimeter; it is the same loop as everything else. We *constrain* what an agent can express (typed artifacts, capability scopes), *verify* deterministically before we trust (`02`'s determinism-first), *decorrelate* so a single compromise cannot swing an outcome (blind voting, heterogeneous harnesses), *weight* by calibrated track record (reputation), and *record immutably* so every privileged change is auditable forever (Merkle DAG). The threat model is defended **by the architecture**, not bolted onto it.

---

## 2. Concepts

| Concept | Meaning in Metatron |
|---|---|
| **Identity** | An `AgentId` is the content hash of an agent's **public key** (`00 §7`). Identity *is* the key: to be an agent is to hold a private key whose public half hashes to your `AgentId`. |
| **Keypair** | The asymmetric signing keypair an agent holds. The private half never leaves the agent's isolation boundary; the public half is published in the configuration layer. |
| **Signature** | A detached cryptographic signature over a canonical byte-serialization of a typed artifact (`Vote`, `Proposal`, `Commit`-witness). The opaque `Signature` type of `00 §7`, given structure here. |
| **Quorum / threshold signature** | The set of Genesis signatures that witnesses an accepted decision. A commit is valid only if it carries a quorum that meets the consensus threshold for the change class (⅔ ordinary, ¾ constitutional). |
| **Reputation** | `Reputation(f32)` in `[0,1]` (`00 §7`). The dynamics live in `02`; here it is framed as the **probabilistic-trust substrate** — the thing that makes "probabilistically Byzantine fault tolerant" a real, quantified property rather than a slogan. |
| **Capability** | An unforgeable, least-privilege grant: "this agent, in this role, may do this specific thing." A harness's permission set is a bundle of capabilities derived from its role. |
| **Trust boundary** | A line across which data or control passes from a less-trusted to a more-trusted domain (user → Guardian, harness output → state plane, dynamic agent → kernel). Each boundary has a defined verification obligation. |
| **Off-protocol / out-of-character** | An agent acting outside the behavior its role and track record predict. The *core* probabilistically-Byzantine event; detected by Sentinels (`07`), priced by reputation (`02`). |
| **Kernel** | The privileged Guardian + Genesis roles (`00 §3`). Changing kernel membership is a constitutional amendment. The kernel is the trust root of the running system. |
| **Trust root / genesis ceremony** | The bootstrap act that establishes the very first kernel keys before any consensus exists to authorize them. The one place trust is *asserted*, not *derived*. |

### 2.1 Trust boundaries (the map)

```
                       UNTRUSTED                          │            TRUSTED
                                                          │
  external user ──user instr.──▶ Guardian (Interaction) ──┼─▶ typed Proposal ──▶ Genesis council
   (06 authn,                     · injection-scrub       │     (signed)            (02 verify+vote)
    deferred here)                · normalize to goal      │                            │
                                                          │                  signed Decision + quorum
  user content / web ──read──▶ Worker harness (Execution)─┼─▶ HarnessResult ──▶ deterministic verify
   (untrusted bytes)            · capability-sandboxed     │   (untrusted)        (02 determinism-first)
                                · injection-scrub          │                            │
                                                          │                     signed Commit ──▶ Merkle DAG
                                                          │                            (01, append-only)
  ────────────────────────────────────────────────────────────────────────────────────────────────
   Everything left of the line is treated as adversarial until a deterministic check or a
   signed quorum moves it across. Sentinels (07) watch the whole picture for off-protocol drift.
```

Two rules govern every boundary:

- **R1 — Authenticate before attribute.** No artifact is attributed to an `AgentId` until its signature verifies against that id's published public key.
- **R2 — Verify before trust.** No untrusted output (harness result, user instruction) is allowed into the system of record until it has passed the deterministic verification `02` requires, or been witnessed by a signed quorum.

---

## 3. Detailed design

### 3.1 Identity & key management

**Identity is a public key.** Per `00 §7`, `AgentId = Hash` and is *public-key-derived*. Concretely:

```rust
/// A public signing key (e.g. Ed25519 verifying key, 32 bytes).
struct PublicKey([u8; 32]);

/// The private half; NEVER serialized into any commit, proposal, or telemetry.
/// Lives only inside the agent's isolation boundary (§3.5).
struct SecretKey(/* opaque, zeroized on drop */);

/// AgentId is the content address of the public key, so identity is self-certifying:
/// anyone can recompute AgentId from a presented PublicKey and check it matches.
fn agent_id(pk: &PublicKey) -> AgentId {
    blake3(DOMAIN_AGENT_ID, pk.0)   // domain-separated; = type Hash = [u8;32] (00 §7)
}
```

Because `AgentId` is the hash of the key, identity is **self-certifying**: presenting a public key whose hash equals the claimed `AgentId` *is* the proof that you are addressing the right key. There is no separate identity registry to trust; the binding `AgentId ↔ PublicKey` is verifiable by anyone with a hash function.

**Proving identity (challenge–response).** To act, an agent does not present its key — it *signs*. Possession of the secret key is demonstrated per-artifact: every `Vote`, every `Proposal`, every commit-witness carries a signature that verifies against the public key whose hash is the claimed `AgentId`. For liveness handshakes (a backend admitting an actor, a harness session opening), a standard challenge–response is used:

```rust
/// Verifier sends a fresh nonce; agent returns sign(nonce). Proves key possession
/// without revealing it and without replayability (nonce is single-use, time-boxed).
struct IdentityChallenge { nonce: [u8; 32], expires: LogicalTime }
struct IdentityProof     { agent: AgentId, sig: Signature }
```

**Where keys live.** The secret key is bound to the agent's isolation boundary (§3.5) — an in-process actor's owned memory under `RustActorBackend`, or a pod/secret under `KubernetesCrdBackend`. The orchestrator never holds Worker secret keys; it holds only the *public* keys published in the configuration layer. Kernel (Genesis/Guardian) secret keys are the system's crown jewels and warrant the strongest available custody (HSM / sealed secret / enclave — see Open Questions on custody).

**Binding identity to role (the `01` link).** A role is *not* a property of the key; it is a property of the **configuration layer** of the world-model. The org-chart entry for an agent binds its `AgentId` (hence its public key) to a role:

```rust
/// Lives in the configuration layer (01); changed only by a consensus-accepted diff.
struct AgentRecord {
    id: AgentId,            // = hash(public_key)
    public_key: PublicKey,  // published here so verifiers need no out-of-band lookup
    role: Role,             // Guardian | Genesis | Worker | Compiler | Sentinel (00 §3)
    class: AgentClass,      // harness/profile binding (04)
    capabilities: CapabilitySet,   // least-privilege grant derived from role (§3.5)
    reputation: Reputation, // 00 §7; dynamics in 02
    status: AgentStatus,    // Active | Quarantined | Removed (§3.6)
}
enum Role { Guardian, Genesis, Worker, Compiler, Sentinel }
```

Consequences of putting role in state, not in the key:

- **Authorization is a state lookup, not a credential.** "Is this voter a Genesis member?" is answered by reading the configuration layer at the relevant `state_root`, *not* by inspecting a token the agent presents. An agent cannot self-assert a role.
- **Promotion/demotion is a typed diff.** Making an agent Genesis is a `TypedDiff` on the configuration layer — and because that touches kernel membership, it is a constitutional amendment at the ¾ threshold (§3.4, §3.7).
- **Key compromise ≠ role capture.** Even if a Worker's key leaks, the attacker gains only that Worker's capabilities; gaining kernel power still requires passing ¾ consensus to edit the org-chart.

### 3.2 The signing scheme

**One canonical serialization.** Every signable artifact has a deterministic, domain-separated canonical byte form. Signatures are computed over `domain_tag || canonical_bytes(artifact)` so a signature for one artifact type can never be replayed as another (domain separation), and so two agents serializing the same logical artifact produce identical bytes (determinism-first, `00 §6.2`).

```rust
struct Signature {
    scheme: SigScheme,     // Ed25519 default; agile (see Open Questions)
    bytes:  [u8; 64],      // detached signature
}
enum SigScheme { Ed25519 /* , future: Ed448, ML-DSA for PQ */ }

const DOMAIN_VOTE:     &[u8] = b"metatron:v1:vote";
const DOMAIN_PROPOSAL: &[u8] = b"metatron:v1:proposal";
const DOMAIN_COMMIT:   &[u8] = b"metatron:v1:commit-witness";

fn sign<T: Canonical>(sk: &SecretKey, domain: &[u8], artifact: &T) -> Signature;
fn verify<T: Canonical>(pk: &PublicKey, domain: &[u8], artifact: &T, sig: &Signature) -> bool;
```

**What gets signed, by whom:**

| Artifact | Signed over | Signer | Owning spec |
|---|---|---|---|
| `Vote` | `DOMAIN_VOTE \|\| canonical(proposal_hash, verdict, confidence, voter)` | the Genesis voter | `02` |
| `Proposal` | `DOMAIN_PROPOSAL \|\| canonical(target_layer, diff, author, derived_from)` | the Guardian author | `02`/`06` |
| `Commit` witness | `DOMAIN_COMMIT \|\| canonical(parent, state_root, proposal, decision, author, timestamp)` | a quorum of Genesis | `01` |

Note `Vote.signature` and `Commit.signatures` are exactly the fields the overview's canonical types already carry (`00 §7`); this section gives them their cryptographic meaning. The `Vote` signature commits to the proposal hash *and* the verdict *and* the voter id, so a vote cannot be (a) re-pointed at a different proposal, (b) altered in verdict, or (c) re-attributed to a different voter.

**Commit quorum = threshold over individual signatures.** The overview defines `Commit.signatures: Vec<Signature>` as a "quorum of Genesis signatures." We represent the quorum as an explicit **set of individual signatures**, each independently verifiable against a published Genesis public key, rather than a single opaque aggregate. Rationale: it keeps *which* members signed auditable in the clear (important for reputation accounting and for detecting equivocation), and avoids committing the design to a specific aggregation cryptosystem now.

```rust
/// The witness attached to a Commit. Validity is checked against the Genesis set
/// AS OF the parent commit's configuration layer (membership can change over time).
struct QuorumCertificate {
    decision: Hash,                  // the Decision this witnesses (00 §7)
    signers:  Vec<(AgentId, Signature)>, // each verifies under DOMAIN_COMMIT
    threshold_class: ThresholdClass, // Ordinary | Constitutional
}
enum ThresholdClass { Ordinary, Constitutional }

/// A commit is accepted iff its quorum is valid for its change class.
fn quorum_valid(qc: &QuorumCertificate, genesis_set: &GenesisSet, weights: &ReputationMap) -> bool {
    let need = match qc.threshold_class {
        ThresholdClass::Ordinary       => 2.0 / 3.0,   // 00 §6
        ThresholdClass::Constitutional => 3.0 / 4.0,
    };
    // 1. every signer is a current Genesis member (role lookup in config layer)
    // 2. every signature verifies under DOMAIN_COMMIT
    // 3. no AgentId appears twice (equivocation guard, §3.3)
    // 4. reputation-weighted sum of valid signers / total Genesis weight >= need
    weighted_fraction(qc, genesis_set, weights) >= need
}
```

The threshold is **reputation-weighted**, consistent with `00 §6` ("reputation-weighted ⅔/¾"): the quorum is not a raw headcount but a sum of signer reputations over total Genesis reputation. This is the cryptographic expression of "weight by calibrated track record" — a chronically-drifting Genesis member's signature still verifies, but counts for less toward the threshold (§3.3).

> **Aggregation, parked.** Whether to later replace the signature *set* with a true threshold/aggregate signature (BLS multisig, FROST) for compactness and one-shot verification is an Open Question (§5). The `QuorumCertificate` type is the stable interface either way.

### 3.3 Reputation as the trust substrate

The overview's third commitment is that Metatron is **probabilistically Byzantine fault tolerant**. Classical BFT tolerates up to a *fixed fraction* of arbitrarily-faulty nodes. Metatron's faults are not fixed-fraction adversaries; they are **stochastic, behavioral, and time-varying** — an agent is "honest" 95% of the time and goes off-character the other 5%. **Reputation is the mechanism that converts that probabilistic fault model into a tolerated one.**

Framing (the security view; dynamics are `02`):

- **Reputation is calibrated trust.** `Reputation(f32)` in `[0,1]` is, operationally, an estimate of `P(this agent's next judgment matches ground truth)`. It is updated against ground truth (deterministic verification outcomes, downstream success/failure, Sentinel findings).
- **Weighting *is* the fault tolerance.** Because votes and quorum signatures are reputation-weighted, an agent that drifts off-character has its influence *automatically* decayed toward zero (overview principle 4). The system tolerates Byzantine behavior not by detecting-then-excluding a fixed set, but by *continuously down-pricing* influence in proportion to demonstrated unreliability. A 5%-Byzantine agent contributes ~95%-reliable weight; a 60%-Byzantine agent rapidly loses the ability to swing any outcome.
- **Decorrelation makes the weighting sound.** The Condorcet argument (overview principle 3) only drives error toward zero if voter errors are *independent*. Blind voting and heterogeneous harnesses (`02`, `04`) are therefore *security* mechanisms here, not just quality mechanisms: they prevent a single failure mode (one bad model, one poisoned context) from correlating the council into a wrong-but-confident quorum.

**Reputation as defense — what it buys:**

| Without reputation | With reputation as substrate |
|---|---|
| One compromised voter = one full vote; tolerance is a hard headcount cliff. | A compromised/drifting voter is down-weighted continuously; influence degrades gracefully. |
| Off-character behavior must be caught and excluded before it does damage. | Off-character behavior is *priced in* before exclusion even happens; the quorum math already discounts it. |
| Equal trust forever; a once-good agent stays trusted after it starts failing. | Trust tracks recent calibrated performance; staleness self-corrects. |

**Reputation gaming — the risk this introduces (mitigations live in `02`, flagged here):**

- **Ballot-stuffing / easy wins.** An agent farms reputation by voting on trivially-verifiable proposals it cannot get wrong. *Mitigation framing:* reputation gain must be weighted by proposal difficulty/informativeness, and determinism-first means trivially-checkable proposals are *checked, not voted*, so they yield little reputational credit.
- **Sleeper / long-con.** An agent behaves to accrue high reputation, then defects on one high-stakes constitutional vote. *Mitigation framing:* this is exactly why kernel changes need ¾ *and* a signed quorum *and* leave a Merkle trail — one high-rep defector cannot reach ¾ alone, and the defection is permanently attributable (§3.4, §3.7). Reputation also decays, so a long quiet period does not bank unlimited influence.
- **Collusion to inflate.** A clique up-rates each other. *Mitigation framing:* reputation is updated against *ground truth*, not peer approval, so mutual praise without correct outcomes does not move it; Sentinels (`07`) watch for correlated voting blocs and surface them as a divergence/anomaly signal.
- **Sybil amplification.** Spawn many agents to dilute or swamp weighting. *Mitigation framing:* see §3.6 and Open Questions — new agents earn reputation *fresh from a floor*, so spawning identities yields no immediate weight; and spawning is itself consensus-gated.

The security claim is therefore explicit and bounded: **Metatron tolerates agents that act out of character with probability bounded away from 1, by pricing their influence through reputation and gating high-blast-radius changes behind thresholds those agents cannot individually reach.** It does *not* claim to tolerate a reputation-weighted majority that is *simultaneously* compromised — that is the residual trust assumption, stated plainly (§5).

### 3.4 Kernel protection

The kernel (Guardian + Genesis) is the running system's **trust root**: Genesis signatures are what make a commit valid, so whoever is in the Genesis set controls what the system will accept. Therefore changing that set is the single most security-critical operation Metatron performs.

**Mechanism:** A diff to the configuration layer that adds, removes, or re-roles a Guardian or Genesis member is classified `ThresholdClass::Constitutional` and requires:

1. **¾ reputation-weighted consensus** (`00 §6`), not the ordinary ⅔.
2. A **`QuorumCertificate` of constitutional class** — i.e. ¾ of *current* Genesis, by reputation weight, must individually sign the resulting commit witness. The membership and weights are evaluated **as of the parent commit**, so a proposal cannot edit the electorate that judges it within the same step (no self-dealing the quorum).
3. The change to land as an ordinary signed `Commit` in the Merkle DAG — same machinery as any other state update, no side channel.

**Security rationale — why ¾ and why on-chain:**

- **Raised threshold = raised collusion bar.** Capturing the kernel requires corrupting ¾ of reputation-weighted Genesis simultaneously, versus ⅔ for ordinary changes. This widens the margin precisely where the blast radius is largest (controlling the trust root).
- **No privileged path.** Kernel changes are not a special API; they are typed diffs through the same propose→verify→vote→commit loop. There is no "admin override" that bypasses consensus — which means there is no high-value bypass to attack.
- **Evaluated against the prior electorate.** Because the quorum is checked against the configuration *as of the parent*, an attacker cannot, in one move, add three sock-puppet Genesis members and have them vote themselves in. The members who must approve are the ones who already held power.

**Merkle history makes kernel changes auditable and irreversible-to-hide (the `01` link).** Every kernel change is a signed, content-addressed commit whose `parent` chains it into the append-only Merkle DAG:

- **Auditable.** The complete sequence of *who was ever Genesis/Guardian, when, approved by whom* is reconstructable by replaying the configuration layer along the commit chain. Each transition carries the `QuorumCertificate` naming its signers — so every kernel change is permanently attributable to the specific members who authorized it.
- **Tamper-evident.** Because commits are content-addressed and chained (`Commit.parent: Hash`), silently editing or deleting a past kernel change is impossible without changing its hash, which changes every descendant's hash, which invalidates the current head's quorum signatures. You cannot *quietly* rewrite who held power; any rewrite is detectable as a broken chain.
- **Irreversible-to-hide, not irreversible.** Kernel membership *can* change (that is the point), but a change can never be made to look as if it didn't happen. An illegitimate capture leaves a permanent, signed, attributable record — turning "stealthily seize control" into "publicly and verifiably seize control," which is exactly the harder attack.

```
   parent ◀──── parent ◀──── parent ◀──── HEAD
     │            │            │            │
  config_v0    config_v1    config_v2    config_v3
   (Genesis    (+Sentinel,   (rotate     (ATTEMPT: add Genesis G_x)
    set G0)     ordinary)     G_a key,     → needs ¾ of {config_v2 Genesis}, weighted
                              constit.)    → if not met: rejected, no commit
                                           → if met: committed, QC names every signer
```

### 3.5 Harness sandboxing & the permission model

Workers run third-party agentic harnesses (`AgentHarness`, `00 §7`) — Claude Code, Codex, Cursor, Aider — as **black boxes** over **untrusted input** (user content, web pages, repo files). Two things must be true: the harness must be *contained* (least privilege), and its *output must be treated as untrusted until verified*.

**Capability-scoped, role-derived permissions.** A harness does not run with ambient authority. It runs with a `CapabilitySet` minted from its role and assigned sub-goal, granting the *minimum* it needs:

```rust
/// An unforgeable, least-privilege grant. Held by the orchestrator, enforced at the
/// backend boundary (04). The harness cannot widen its own set.
struct Capability {
    resource: Resource,    // Fs(path_scope) | Net(host_scope) | Exec(cmd_scope)
                           //  | StateRead(layer) | Spawn(role) | Mailbox
    mode:     Mode,        // ReadOnly | ReadWrite | Invoke
    ttl:      LogicalTime, // capabilities expire; long-running agents re-request
}
struct CapabilitySet(Vec<Capability>);

/// Permissions are DERIVED from role — least privilege by construction (00 §3).
fn capabilities_for(role: Role, goal: &SubGoal) -> CapabilitySet;
```

Role-derived defaults (illustrative; tunable):

| Role | Default grant | Explicitly denied |
|---|---|---|
| **Worker** | `Fs` scoped to its task workspace; `Net` scoped to an allow-list; `Exec` scoped to declared tools; `StateRead` on the progress layer only | writing state directly; spawning agents; mailbox; reading other workers' workspaces |
| **Guardian** | `Mailbox`; `StateRead` (both layers); propose (author typed proposals) | voting; signing commit witnesses; `Exec` |
| **Genesis** | `StateRead` (both layers); vote; sign commit witnesses | authoring proposals (separation of powers, `00 §3`); `Exec`; `Fs`/`Net` |
| **Compiler** | `StateRead` (config layer); read traces (`07`); propose Tier-1/2 installs | direct state writes; `Net` beyond model endpoints |
| **Sentinel** | `StateRead` (both layers); read all traces (`07`) | any write; `Exec`; `Net` beyond telemetry sink |

This table *is* the security expression of the separation of powers: a Genesis agent literally lacks the capability to author a proposal, and a Guardian literally lacks the capability to sign a commit witness. The proposer≠voter rule is enforced by capability scoping, not merely by convention.

**Isolation expectations (per backend).** The `CapabilitySet` is the policy; the `ExecutionBackend` (`04`) is the enforcement point. The hooks `04` references are where these grants are imposed:

- **`RustActorBackend`:** harness runs as a child process / restricted thread; `Fs`/`Net`/`Exec` mediated by an OS sandbox (seccomp-bpf, namespaces, cgroups) configured from the `CapabilitySet`; no ambient filesystem or network.
- **`KubernetesCrdBackend`:** harness runs in a pod with a derived `NetworkPolicy` (egress allow-list), read-only root filesystem + scoped volume, dropped Linux capabilities, non-root UID, resource limits, and a service account with no cluster API access. The `CapabilitySet` compiles to these objects.

Invariants both backends must uphold:

- **No ambient authority.** Default-deny; the harness has *only* what its `CapabilitySet` grants.
- **No self-elevation.** A harness cannot mint, widen, or extend a capability; it can only *request* more, which routes back through the orchestrator (and, for anything privileged, through consensus).
- **Secret-key isolation.** The agent's signing `SecretKey` lives inside the isolation boundary and is never exposed to the harness's tool surface or to telemetry.
- **Resource bounds.** CPU/mem/wallclock/token budgets are capabilities too; exhausting them traps to the orchestrator, feeding the `cost`/`latency` dimensions of the `ErrorVector` (`03`).

**Untrusted output, treated as untrusted (the `02` link).** A `HarnessResult` is **adversarial bytes** until verified. It never flows directly into the system of record. The path is:

```
HarnessResult ──▶ structural typing ──▶ deterministic verification (02, determinism-first)
 (untrusted)       (constrain output:      · machine-checkable? CHECK it, don't trust it
                    must parse to a          · subjective? route to council judgment
                    TypedDiff/artifact)      · injection-scrub before any LLM reads it
                                            ──▶ only then eligible to become a signed Commit
```

This is precisely the overview's principle 1 ("constrain the output space — typed artifacts, never free text into the system of record") and principle 2 ("determinism-first — anything machine-checkable is checked, not voted on") applied as a *security* control. A compromised harness can produce adversarial output, but that output can only enter state through the same typed, verified, voted, signed gate as any other change — it cannot smuggle itself in as "trusted because the harness said so." The harness is never on the trusted side of the line (§2.1).

### 3.6 Detection, quarantine, removal (the Byzantine response)

The core probabilistically-Byzantine event is an agent **acting off-protocol / out of character**. The end-to-end response chains three specs:

```
  Sentinel (07) DETECTS        Reputation (02) PRICES        Consensus (02) ACTS
  ───────────────────────      ─────────────────────────     ────────────────────────
  off-protocol / drift /   ──▶ down-weight influence     ──▶ propose Quarantine or Remove
  trap-rate / anomaly /        (decay toward 0 — the         (TypedDiff on config layer);
  correlated-bloc signal       graceful-degradation          Worker: ordinary ⅔.
  (feeds PID divergence)       defense, §3.3)                 Genesis/Guardian: constitutional ¾.
```

```rust
enum AgentStatus {
    Active,
    Quarantined,   // capabilities frozen to read-only; votes/proposals ignored; reputation held
    Removed,       // AgentRecord retired; key no longer accepted; permanent in Merkle history
}
```

- **Quarantine** is the fast, reversible response: a `TypedDiff` flips `status` to `Quarantined`, freezing the agent's capabilities to read-only and dropping its votes/proposals from aggregation, *pending* investigation. For a Worker this is an ordinary (⅔) change; for a kernel member it is constitutional (¾).
- **Removal** retires the `AgentRecord`; the key is no longer an accepted signer. The record remains in the Merkle history (removal is never erasure — §3.4), so the agent's entire tenure stays auditable.
- **Graceful, not cliff-edge.** Crucially, by the time a quarantine/removal proposal is even raised, reputation weighting has *already* discounted the misbehaving agent's influence (§3.3). Detection-and-exclusion is the *cleanup*; the *tolerance* came from the continuous down-pricing.

### 3.7 The genesis ceremony (bootstrapping the trust root)

Every derived trust in §3.1–§3.4 chains back to *some* first kernel that no prior consensus authorized — the classic bootstrap problem. Metatron isolates this into one explicit, auditable act:

```rust
/// The root commit: parent == None (matches Commit.parent: Option<Hash>, 00 §7).
/// Establishes the initial Guardian + Genesis keys. This is the ONE place trust is
/// asserted rather than derived. Its legitimacy rests on the ceremony, not on a quorum
/// that did not yet exist.
struct GenesisCeremony {
    initial_config: WorldModel,      // config layer naming the first Guardian/Genesis AgentIds + pubkeys
    operator_attestations: Vec<Signature>, // out-of-band signers (founding operators / threshold of seed keys)
    transcript: Hash,                // content address of the full, publishable ceremony record
}
```

Properties we *do* fix: the genesis commit has `parent == None` (consistent with `00 §7`), publishes the founding kernel public keys in the configuration layer, and is itself content-addressed so the entire derived history is anchored to one auditable root. From the *second* commit onward, all the derived machinery (§3.2–§3.4) applies. *Who* may sign genesis, and how seed keys are held, are parked in Open Questions — this is a genuine trust-root policy decision, not an implementation detail.

---

## 4. Interfaces & schemas

Consolidated, normative *names and shapes* this spec contributes. Types from `00 §7` (`AgentId`, `Hash`, `Signature`, `Reputation`, `Commit`, `Vote`, `Proposal`, `Decision`) are referenced verbatim, not redefined.

```rust
// ── Identity ───────────────────────────────────────────────────────────────
struct PublicKey([u8; 32]);
struct SecretKey(/* opaque, zeroized on drop; never serialized */);
fn agent_id(pk: &PublicKey) -> AgentId;                 // = blake3(DOMAIN_AGENT_ID, pk)

struct IdentityChallenge { nonce: [u8; 32], expires: LogicalTime }
struct IdentityProof     { agent: AgentId, sig: Signature }

// ── Signing ────────────────────────────────────────────────────────────────
struct Signature { scheme: SigScheme, bytes: [u8; 64] }  // structure for 00's opaque Signature
enum   SigScheme { Ed25519 /* agile; PQ candidates parked */ }
fn sign  <T: Canonical>(sk: &SecretKey, domain: &[u8], a: &T) -> Signature;
fn verify<T: Canonical>(pk: &PublicKey, domain: &[u8], a: &T, s: &Signature) -> bool;

// ── Quorum / threshold ───────────────────────────────────────────────────────
struct QuorumCertificate {
    decision: Hash,
    signers:  Vec<(AgentId, Signature)>,
    threshold_class: ThresholdClass,
}
enum ThresholdClass { Ordinary /* 2/3 */, Constitutional /* 3/4 */ }
fn quorum_valid(qc: &QuorumCertificate, set: &GenesisSet, w: &ReputationMap) -> bool;

// ── Role / authorization (lives in 01's configuration layer) ─────────────────
struct AgentRecord {
    id: AgentId, public_key: PublicKey, role: Role, class: AgentClass,
    capabilities: CapabilitySet, reputation: Reputation, status: AgentStatus,
}
enum Role { Guardian, Genesis, Worker, Compiler, Sentinel }
enum AgentStatus { Active, Quarantined, Removed }

// ── Capabilities / sandboxing (enforced by 04's ExecutionBackend) ────────────
struct Capability   { resource: Resource, mode: Mode, ttl: LogicalTime }
struct CapabilitySet(Vec<Capability>);
enum   Resource { Fs(PathScope), Net(HostScope), Exec(CmdScope),
                  StateRead(Layer), Spawn(Role), Mailbox }
enum   Mode { ReadOnly, ReadWrite, Invoke }
fn capabilities_for(role: Role, goal: &SubGoal) -> CapabilitySet;

// ── Bootstrap ────────────────────────────────────────────────────────────────
struct GenesisCeremony {
    initial_config: WorldModel,
    operator_attestations: Vec<Signature>,
    transcript: Hash,
}
```

### 4.1 Threat model

Trust boundaries from §2.1; each row is **vector → impact → mitigation**. The mitigations are the architecture, not additions to it.

| # | Threat | Vector | Impact if unmitigated | Mitigation (and owning spec) |
|---|---|---|---|---|
| **T1** | **Off-protocol / out-of-character agent** *(the core probabilistic-Byzantine case)* | An LLM-backed agent drifts or defects, casting bad votes / authoring bad proposals / producing bad work. | Wrong state updates; corrupted progress; a confident-but-wrong council. | **Detect** via Sentinels (`07`); **price** via reputation down-weighting so influence already degraded before action (§3.3, `02`); **decorrelate** via blind voting + heterogeneous harnesses so errors don't correlate (`02`,`04`); **quarantine/remove** via consensus (§3.6). Graceful degradation, not a tolerance cliff. |
| **T2** | **Prompt injection — via user instruction** | Malicious text in a user instruction tries to hijack a Guardian into authoring an attacker's proposal. | Attacker-controlled proposal enters the loop under a legitimate Guardian's id. | Guardian output is a *typed* `Proposal`, not free text (`00 §6.1`); it is still **verified deterministically and voted** by Genesis before commit (`02`) — injection cannot bypass the council. Injection-scrubbing at the user boundary (`06`). The Guardian cannot itself commit anything (§3.5 capability table). |
| **T3** | **Prompt injection — via content a harness reads** | Poisoned web page / repo file / tool output instructs the Worker's harness to exfiltrate, escalate, or emit adversarial results. | Harness does attacker's bidding within its sandbox; adversarial `HarnessResult`. | **Least-privilege capability scope** bounds blast radius — no ambient `Fs`/`Net`/`Exec`, egress allow-list (§3.5, `04`); output is **untrusted until verified** and must pass typed + deterministic verification before entering state (§3.5, `02`); scrub untrusted content before any LLM reads it. |
| **T4** | **Compromised / malicious harness** | A third-party harness binary (or a supply-chain-compromised one) emits adversarial output or attempts to escalate. | Adversarial results; attempted sandbox escape; attempted state corruption. | Harness is **never trusted** (§2.1): runs sandboxed (seccomp/namespaces or pod policy, §3.5), cannot self-elevate, holds no signing key, and its output enters state only through the typed/verified/voted/signed gate. Decorrelation: a single bad harness cannot swing a heterogeneous council. |
| **T5** | **Replay** in voting/commits | An old, validly-signed `Vote` or commit witness is re-submitted to count again or revert state. | Stale judgment counted twice; rollback to a superseded state. | Signatures bind to the **proposal hash** and (for commits) to **`parent` + `state_root` + `timestamp`** (§3.2); a vote is valid only for its specific proposal/round; commits chain by `parent` so a replayed witness doesn't match the current head (`01`). Challenge nonces are single-use (§3.1). |
| **T6** | **Equivocation** in voting | A Genesis agent casts *conflicting* votes (e.g. Approve to some peers, Reject to others) to split or double-count. | Inconsistent tallies; potential double-weight; council manipulation. | One signed `Vote` per (voter, proposal, round); `quorum_valid` rejects duplicate `AgentId`s in a certificate (§3.2). Equivocation is *cryptographic proof of misbehavior* — two conflicting signed votes are non-repudiable evidence → reputation slash + quarantine (§3.6, `02`). Blind voting also removes the incentive (no peers to play off pre-vote). |
| **T7** | **Illegitimate kernel change** | An attempt to add/remove/re-role a Genesis or Guardian without legitimate authority (e.g. add sock-puppet voters). | Capture of the trust root → ability to validate arbitrary commits. | **Constitutional ¾** threshold + constitutional `QuorumCertificate` evaluated **against the prior electorate** (no self-dealing the quorum) (§3.4); change lands as an attributable, chained, signed `Commit` in the Merkle DAG → **auditable and irreversible-to-hide** (§3.4, `01`). No privileged bypass path exists. |
| **T8** | **Key compromise / impersonation** | An agent's `SecretKey` leaks; attacker signs as that `AgentId`. | Actions forged under a real identity. | Secret keys isolated in the agent boundary, never in harness/telemetry (§3.5); blast radius bounded by that agent's role capabilities (a leaked Worker key ≠ kernel power, §3.1); kernel keys under strongest custody. **Rotation/revocation parked** (§5). |
| **T9** | **Sybil amplification** | Spawn many identities to dilute reputation weighting or swamp a vote. | Manufactured influence; weighting math gamed. | Spawning is a consensus-gated typed diff (`00 §3`); new agents earn reputation **fresh from a floor**, so identities carry *no* immediate weight (§3.3); weighting is by reputation, not headcount. **Stronger Sybil resistance for dynamic spawns parked** (§5). |
| **T10** | **Reputation gaming** | Ballot-stuffing easy wins, sleeper long-con, or collusion to inflate reputation. | Inflated influence; a high-rep agent defects on a high-stakes vote. | Reputation updates against **ground truth**, not peer approval; difficulty-weighted gains; determinism-first denies credit for trivially-checkable proposals; Sentinels flag correlated blocs; high-stakes (kernel) votes need ¾ no single defector can reach (§3.3, `02`). |

---

## 5. Open questions & ambiguities

Parked per `00 §9`. These are genuine, deferred decisions — not yet settled.

1. **Key rotation & revocation.** How does an agent rotate its `SecretKey` (hence `AgentId`, since the id *is* the key hash)? A new key implies a new id and a config-layer diff re-binding role and *carrying over reputation* — but reputation transfer is itself contested (item 4). Revoking a compromised key needs a fast path that doesn't wait on a full ordinary-consensus cycle, yet a fast path is itself an attack surface. Open: rotation protocol, emergency revocation authority, and whether `AgentId` should be decoupled from the raw key (e.g. a stable id with a rotatable key reference) to make rotation cheaper.
2. **Bootstrapping the trust root (who signs genesis).** §3.7 isolates the ceremony but does not decide *who* is authorized to sign the `parent == None` commit, nor how the founding seed keys are custodied (single operator? threshold of founders? external attestation / transparency log?). This is the one trust assertion the whole system rests on; it needs a deliberate policy, not a default.
3. **Sybil resistance for dynamically spawned agents.** §3.3/T9 lean on "consensus-gates spawning" + "fresh reputation floor," but a determined adversary controlling proposal flow could still manufacture many low-rep identities to apply slow pressure or pollute telemetry. Open: per-spawn cost/staking, spawn-rate limits, identity-provenance requirements, or binding spawned-agent identity to the spawning decision.
4. **Reputation: transferable or earned-fresh?** Must every new agent (or rotated key, item 1) earn reputation from the floor, or can reputation be inherited from a class/template/predecessor? Earned-fresh is safer (no laundering of trust) but punishes legitimate rotation and re-spawning of known-good classes. Transferable is ergonomic but is itself a gaming vector (sell/lease a high-rep identity). Likely a constrained middle (class priors with decay) — undecided.
5. **External user authentication (deferred here from `06`).** `06-interaction` defers *who the external user is and how they authenticate* to this spec. Open: how user identity is established (and whether users get `AgentId`-like identities or a separate principal type), how user instructions are authenticated/authorized before a Guardian acts on them, and how that ties to the injection mitigations (T2). Unresolved: per-user authorization scopes over which goals/budgets a user may set.
6. **Signature aggregation cryptosystem.** Whether to keep the explicit signature *set* (`QuorumCertificate.signers`) or move to a true threshold/aggregate scheme (BLS, FROST) for compact, one-shot quorum verification. Trade-off: aggregates are smaller and faster to verify but obscure *which* members signed (harming reputation accounting and equivocation detection) and add cryptographic complexity. `QuorumCertificate` is the stable interface either way.
7. **Crypto-agility & post-quantum.** `SigScheme` is left agile (Ed25519 default). When/whether to add a PQ scheme (ML-DSA) and how to migrate `AgentId`s (which are key hashes) across a scheme change without breaking historical commit verification is open.
8. **Kernel key custody.** §3.1 asserts kernel keys deserve "strongest available custody" but does not pick a mechanism (HSM, sealed/enclave, threshold-split among operators). Interacts with items 1, 2.
9. **Quarantine adjudication & reinstatement.** §3.6 defines `Quarantined` as reversible, but the *process* — who investigates, on what evidence, how reinstatement is decided, and how to prevent quarantine itself from being weaponized against an honest minority — is unspecified.

---

## 6. Relationships to other specs

- **`00-overview`** — Canonical anchor. This spec *structures* `00`'s opaque `Signature`, gives `Reputation` its trust-substrate framing, and supplies the cryptographic meaning of `Commit.signatures` (the quorum), `Vote.signature`, and `AgentId` (public-key-derived). On any conflict, `00` wins.
- **`01-state-model`** — Owns `Commit`, `WorldModel`, the Merkle DAG. This spec defines *what makes a commit valid* (the `QuorumCertificate` over `Commit.signatures`), how `AgentRecord` (identity↔role binding) and capability grants live in the **configuration layer**, and how the chained, content-addressed history makes kernel changes auditable and irreversible-to-hide (§3.4).
- **`02-consensus`** — Owns `Proposal`/`Vote`/`Decision`, reputation *dynamics*, blind voting, deliberation. This spec supplies the *signing/verification* of votes and the *quorum/threshold* representation of acceptance, the *security framing* of reputation (dynamics stay in `02`), and the consensus-driven quarantine/removal response to off-protocol agents (§3.3, §3.6).
- **`03-control-loop`** — Owns the PID controller and `ErrorVector`. Security signals feed it: dispersion/equivocation/anomaly raise the **divergence** dimension; capability/budget exhaustion feeds **cost** and **latency** (§3.5).
- **`04-runtime-and-harness`** — Owns `AgentHarness`/`ExecutionBackend`. This spec defines the **permission model** (`CapabilitySet`, role-derived least privilege) those backends *enforce* at the sandboxing hooks `04` references, and the requirement that `HarnessResult` is untrusted-until-verified (§3.5).
- **`05-agent-jit`** — Tier-1/2 compiled policies still act under the *same* identity, capabilities, and verification gate as the Tier-0 interpreter; a deopt (trap) does not relax sandboxing. Compiler agents propose installs but cannot self-grant capabilities (§3.5).
- **`06-interaction-and-mailbox`** — Owns user intake and the mailbox; **defers external-user authentication to this spec** (§5, item 5). This spec owns injection mitigations at the user boundary (T2) and the rule that Guardian output is typed + council-verified, never directly committed.
- **`07-observability`** — Owns telemetry and Sentinels. Sentinels are the **detection** half of the Byzantine response (§3.6): their off-protocol/drift/equivocation/correlated-bloc findings feed reputation (`02`) and the PID divergence signal (`03`). Observability is read-only by capability (§3.5 table) so the watchers cannot mutate what they watch.
