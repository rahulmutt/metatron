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
| **Identity** | An `AgentId` is the content hash of an agent's **long-term identity key**, recorded in the configuration layer (`00 §7`). It is a *stable* id: it does **not** change when the agent's operational signing key rotates. Identity is the durable anchor; the key that actually signs is a separable, rotatable artifact bound to it (§3.1). |
| **Keypair** | An agent holds a long-term **identity keypair** (whose public half's hash *is* the `AgentId`) and a rotatable **operational signing keypair** referenced from its `AgentRecord`. Private halves never leave the agent's isolation boundary; public halves are published in the configuration layer. |
| **Workload identity (SVID)** | The short-lived runtime credential (`Svid`, §3.8) a live agent process presents to reach external tools. Issued by SPIRE only after a Metatron workload attestor confirms the agent's on-state facts; auto-rotates every few minutes. Binds the durable `AgentId` to a running workload. |
| **External user (principal)** | A human (or external system) that sets goals/budgets. A **separate principal type from `AgentId`**, authenticated at the API boundary (`06`) with per-user authorization scopes. Metatron is **multi-user**: multiple users may drive the system concurrently (§3.9). |
| **`mcp-auth-proxy`** | A separately-deployed, **user-controlled** trust boundary that brokers all downstream MCP tool calls and holds the user's downstream secrets. Metatron core holds no downstream secrets; it only *asserts* signed agent identity + scopes (§3.8, `09`). |
| **Signature** | A detached cryptographic signature over a canonical byte-serialization of a typed artifact (`Vote`, `Proposal`, `Commit`-witness). The opaque `Signature` type of `00 §7`, given structure here. Signatures are **scheme-tagged** (`SigScheme`); the default is a hybrid composite `Hybrid(Ed25519, MlDsa)` whose verification requires *both* (§3.2). |
| **Quorum / threshold signature** | The set of Genesis signatures that witnesses an accepted decision. A commit is valid only if it carries a quorum that meets the consensus threshold for the change class (⅔ ordinary, ¾ constitutional). |
| **Reputation** | `Reputation(f32)` in `[0,1]` (`00 §7`). The dynamics live in `02`; here it is framed as the **probabilistic-trust substrate** — the thing that makes "probabilistically Byzantine fault tolerant" a real, quantified property rather than a slogan. |
| **Capability** | An unforgeable, least-privilege grant: "this agent, in this role, may do this specific thing." A harness's permission set is a bundle of capabilities derived from its role. |
| **Trust boundary** | A line across which data or control passes from a less-trusted to a more-trusted domain (user → Guardian, harness output → state plane, dynamic agent → kernel). Each boundary has a defined verification obligation. |
| **Off-protocol / out-of-character** | An agent acting outside the behavior its role and track record predict. The *core* probabilistically-Byzantine event; detected by Sentinels (`07`), priced by reputation (`02`). |
| **Kernel** | The privileged Guardian + Genesis roles (`00 §3`). Changing kernel membership is a constitutional amendment. The kernel is the trust root of the running system. |
| **Trust root / genesis ceremony** | The bootstrap act that establishes the very first kernel keys before any consensus exists to authorize them. The one place trust is *asserted*, not *derived*. The genesis root is a **threshold of founders** (m-of-n): an offline, threshold-split root CA, with SPIRE running as an online intermediate issuer chained to it (§3.7). |

### 2.1 Trust boundaries (the map)

```
                       UNTRUSTED                          │            TRUSTED
                                                          │
  external user ──user instr.──▶ Guardian (Interaction) ──┼─▶ typed Proposal ──▶ Genesis council
   (06 authn; SEPARATE           · injection-scrub       │     (signed)            (02 verify+vote)
    principal type;              · normalize to goal      │                            │
    per-user scopes §3.9)                                 │                  signed Decision + quorum
  user content / web ──read──▶ Worker harness (Execution)─┼─▶ HarnessResult ──▶ deterministic verify
   (untrusted bytes)            · capability-sandboxed     │   (untrusted)        (02 determinism-first)
                                · injection-scrub          │                            │
                                                          │                     signed Commit ──▶ Merkle DAG
                                                          │                            (01, append-only)
  Worker harness ──MCP call (asserted AgentId+scopes)─────┼─▶ mcp-auth-proxy ──▶ downstream MCP server
   (no downstream secret)        · short-lived SVID        │   (USER-controlled;   (real credential injected
                                · gateway-only            │    holds the vault)    by the proxy, §3.8)
  ────────────────────────────────────────────────────────────────────────────────────────────────
   Everything left of the line is treated as adversarial until a deterministic check or a
   signed quorum moves it across. The mcp-auth-proxy is a distinct, user-owned trust boundary
   reached via SPIFFE federation. Sentinels (07) watch the whole picture for off-protocol drift.
```

Two rules govern every boundary:

- **R1 — Authenticate before attribute.** No artifact is attributed to an `AgentId` until its signature verifies against that id's published public key.
- **R2 — Verify before trust.** No untrusted output (harness result, user instruction) is allowed into the system of record until it has passed the deterministic verification `02` requires, or been witnessed by a signed quorum.

---

## 3. Detailed design

### 3.1 Identity & key management

**Stable identity, rotatable key (NORMATIVE).** Per `00 §7`, `AgentId = Hash`. We **decouple** the `AgentId` from the raw operational signing key. The `AgentId` is the hash of an agent's **long-term identity key** and is recorded in the configuration layer; it is *stable across key rotation*. The **operational signing key** — the key that actually signs `Vote`s, `Proposal`s, and commit-witnesses day to day — is a separate, **rotatable** artifact *referenced from* the agent's `AgentRecord`.

```rust
/// A public signing key. With hybrid PQ (§3.2) this is a scheme-tagged composite,
/// not necessarily 32 bytes; the tag travels with it.
struct PublicKey(/* scheme-tagged verifying material */);

/// The private half; NEVER serialized into any commit, proposal, or telemetry.
/// Lives only inside the agent's isolation boundary (§3.5).
struct SecretKey(/* opaque, zeroized on drop */);

/// AgentId is the content address of the LONG-TERM IDENTITY key, scheme-tagged so a
/// future scheme change does not collide historical ids (§3.2). Stable across rotation.
fn agent_id(identity_pk: &PublicKey) -> AgentId {
    blake3(DOMAIN_AGENT_ID, scheme_tag(identity_pk), bytes(identity_pk))  // = type Hash (00 §7)
}
```

Identity remains **self-certifying**: presenting a long-term identity key whose scheme-tagged hash equals the claimed `AgentId` *is* the proof you are addressing the right principal. There is no separate identity registry to trust. What is *not* baked into the id is the operational key, which can change without minting a new identity, retiring reputation, or rewriting history.

**Key rotation = a governed config-layer diff (NORMATIVE).** Rotating an agent's operational key is an ordinary typed diff on the configuration layer that **re-binds** `AgentRecord.operational_key` to the new key. Because the `AgentId` is unchanged, the record's `reputation` is **carried over per the class-prior policy** (§3.3.1): the rotated agent does not start fresh, but inherits a *discounted* prior that decays toward freshly-earned reputation. Every rotation is therefore consensus-witnessed, attributable, and permanent in the Merkle history.

**Emergency revocation (NORMATIVE).** A leaked or suspected-compromised operational key cannot wait a full ordinary-consensus cycle. Metatron provides a **small, time-boxed, heavily-audited fast-path quorum** that may revoke an operational key immediately, placing the agent in `Quarantined` pending full adjudication (§3.6). The fast path is deliberately narrow — it can *revoke/freeze* but never *grant power* — its actions are time-boxed, require a quorum (never a single operator), and leave a full evidence trail and a chained `Commit`, so the fast path itself is not a stealth escalation surface.

```rust
/// Lives in the configuration layer; a Quarantine-class diff signed by the fast-path quorum.
struct EmergencyRevocation {
    agent: AgentId,                 // identity is stable; only the operational key is revoked
    revoked_key: PublicKey,         // the operational key being invalidated
    expires: LogicalTime,           // time-boxed: auto-lapses into full adjudication (§3.6)
    quorum: QuorumCertificate,      // fast-path quorum witness; never a single signer
    evidence: Hash,                 // content address of the Sentinel/07 evidence bundle
}
```

**Proving identity (challenge–response).** To act, an agent does not present its key — it *signs* with its current operational key. Possession is demonstrated per-artifact: every `Vote`, `Proposal`, and commit-witness carries a signature that verifies against the *operational* public key bound to the claimed `AgentId` in the configuration layer. For liveness handshakes (a backend admitting an actor, the workload attestor admitting a process, §3.8), a standard challenge–response is used:

```rust
/// Verifier sends a fresh nonce; agent returns sign(nonce). Proves operational-key
/// possession without revealing it and without replayability (nonce single-use, time-boxed).
struct IdentityChallenge { nonce: [u8; 32], expires: LogicalTime }
struct IdentityProof     { agent: AgentId, sig: Signature }
```

**Where keys live.** Secret keys are bound to the agent's isolation boundary (§3.5) — an in-process actor's owned memory under `RustActorBackend`, or a pod/secret under `KubernetesCrdBackend`. The orchestrator never holds Worker secret keys; it holds only the *public* keys published in the configuration layer. Kernel (Genesis/Guardian) secret keys are the system's crown jewels and warrant the strongest available custody (the genesis root is a threshold-split offline CA, §3.7; per-mechanism custody specifics remain open, §5).

**Binding identity to role (the `01` link).** A role is *not* a property of the key; it is a property of the **configuration layer** of the world-model. The org-chart entry for an agent binds its `AgentId` (hence its public key) to a role:

```rust
/// Lives in the configuration layer (01); changed only by a consensus-accepted diff.
struct AgentRecord {
    id: AgentId,                // = hash(identity_key); STABLE across operational-key rotation
    identity_key: PublicKey,    // long-term key whose scheme-tagged hash IS the AgentId
    operational_key: PublicKey, // ROTATABLE signing key; re-bound by a governed diff (§3.1)
    role: Role,                 // Guardian | Genesis | Worker | Compiler | Sentinel (00 §3)
    class: AgentClass,          // harness/profile binding (04); source of the reputation class-prior (§3.3.1)
    capabilities: CapabilitySet, // least-privilege grant derived from role (§3.5)
    reputation: Reputation,     // 00 §7; dynamics in 02; class-prior-with-decay on spawn/rotation (§3.3.1)
    provenance: Provenance,     // the spawning Decision that created this agent (Sybil binding, §3.6)
    status: AgentStatus,        // Active | Quarantined | Removed (§3.6)
}
enum Role { Guardian, Genesis, Worker, Compiler, Sentinel }

/// Binds a spawned agent's identity to the consensus decision that authorized it (§3.6).
struct Provenance { spawn_decision: Hash, spawned_by: AgentId, spawned_at: LogicalTime }
```

Consequences of putting role in state, not in the key:

- **Authorization is a state lookup, not a credential.** "Is this voter a Genesis member?" is answered by reading the configuration layer at the relevant `state_root`, *not* by inspecting a token the agent presents. An agent cannot self-assert a role.
- **Promotion/demotion is a typed diff.** Making an agent Genesis is a `TypedDiff` on the configuration layer — and because that touches kernel membership, it is a constitutional amendment at the ¾ threshold (§3.4, §3.7).
- **Key compromise ≠ role capture.** Even if a Worker's key leaks, the attacker gains only that Worker's capabilities; gaining kernel power still requires passing ¾ consensus to edit the org-chart.

### 3.2 The signing scheme

**One canonical serialization.** Every signable artifact has a deterministic, domain-separated canonical byte form. Signatures are computed over `domain_tag || canonical_bytes(artifact)` so a signature for one artifact type can never be replayed as another (domain separation), and so two agents serializing the same logical artifact produce identical bytes (determinism-first, `00 §6.2`).

**Hybrid composite signatures by default (NORMATIVE, post-quantum).** `SigScheme` is crypto-agile and the default is a **hybrid composite** that requires *both* a classical and a PQ signature to verify. An artifact is authentic only if **both** component signatures verify; breaking it requires breaking Ed25519 **and** ML-DSA. The scheme **tag travels with every signature**, so historical artifacts remain verifiable under the scheme they were signed with even after the default advances.

```rust
struct Signature {
    scheme: SigScheme,     // travels with the signature; default Hybrid(Ed25519, MlDsa)
    bytes:  Vec<u8>,       // detached; length depends on scheme (composite = both components)
}
/// Default = Hybrid(Ed25519, MlDsa): BOTH components must verify (composite).
enum SigScheme { Ed25519, MlDsa, Hybrid(Box<SigScheme>, Box<SigScheme>) }

/// Transport / secret-wrapping uses a HYBRID KEM (HPKE-hybrid): X25519 + ML-KEM.
/// A shared secret is derived only if BOTH KEMs agree. Used for SVID issuance,
/// challenge channels, and any wrapping of secret material in transit (§3.8).
enum KemScheme { X25519, MlKem, Hybrid(Box<KemScheme>, Box<KemScheme>) } // default Hybrid(X25519, MlKem)

const DOMAIN_VOTE:     &[u8] = b"metatron:v1:vote";
const DOMAIN_PROPOSAL: &[u8] = b"metatron:v1:proposal";
const DOMAIN_COMMIT:   &[u8] = b"metatron:v1:commit-witness";

fn sign<T: Canonical>(sk: &SecretKey, domain: &[u8], artifact: &T) -> Signature;
/// Verifies EVERY component of a composite scheme; a Hybrid verifies iff both halves do.
fn verify<T: Canonical>(pk: &PublicKey, domain: &[u8], artifact: &T, sig: &Signature) -> bool;
```

Because `AgentId` is a **scheme-tagged** key hash (§3.1), a future scheme change mints distinct ids in the new scheme space without colliding the old, and each historical signature carries the scheme needed to re-verify it. PQ migration *timeline* and SVID re-issuance across a scheme change remain open (§5).

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
/// v1 keeps the EXPLICIT signer set (08-#6 resolved): signers[i] cast sigs[i].
struct QuorumCertificate {
    signers: Vec<AgentId>,   // WHO signed — explicit for reputation accounting + equivocation detection
    sigs:    Vec<Signature>, // parallel to `signers`; each verifies under DOMAIN_COMMIT
    scheme:  SigScheme,      // the scheme this quorum used; default Hybrid(Ed25519, MlDsa) (§3.2)
}

/// The change class is DERIVED from the proposal/decision being witnessed (kernel-membership
/// diffs are Constitutional, all else Ordinary, §3.4) — not stored in the cert.
enum ThresholdClass { Ordinary /* 2/3 */, Constitutional /* 3/4 */ }

/// A commit is accepted iff its quorum is valid for its change class.
fn quorum_valid(qc: &QuorumCertificate, class: ThresholdClass,
                genesis_set: &GenesisSet, weights: &ReputationMap) -> bool {
    let need = match class {
        ThresholdClass::Ordinary       => 2.0 / 3.0,   // 00 §6
        ThresholdClass::Constitutional => 3.0 / 4.0,
    };
    // 1. signers.len() == sigs.len(); every signer is a current Genesis member (config-layer lookup)
    // 2. every sigs[i] verifies under DOMAIN_COMMIT against signers[i]'s operational key
    // 3. no AgentId appears twice (equivocation guard, §3.3)
    // 4. reputation-weighted sum of valid signers / total Genesis weight >= need
    weighted_fraction(qc, genesis_set, weights) >= need
}
```

The threshold is **reputation-weighted**, consistent with `00 §6` ("reputation-weighted ⅔/¾"): the quorum is not a raw headcount but a sum of signer reputations over total Genesis reputation. This is the cryptographic expression of "weight by calibrated track record" — a chronically-drifting Genesis member's signature still verifies, but counts for less toward the threshold (§3.3).

> **Aggregation (RESOLVED for v1).** v1 **keeps the explicit signer set** (`QuorumCertificate.signers`). The explicit set is *required* now: reputation accounting needs to know *which* members signed, and equivocation detection needs per-signer attribution — both of which a single opaque aggregate would obscure. A true threshold/aggregate signature (BLS multisig, FROST) for compact one-shot verification is a **future optimization** that can land **behind the stable `QuorumCertificate` interface** without disturbing callers.

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
- **Sybil amplification.** Spawn many agents to dilute or swamp weighting. *Mitigation framing:* spawning is **consensus-gated**, each spawn is **rate-limited**, every spawned agent inherits only a **class-prior fresh-reputation floor** (a *discounted* prior, §3.3.1) so identities carry little immediate weight, and each spawned identity is **bound to the spawning Decision** via `AgentRecord.provenance` (§3.6) so manufactured identities are attributable to the decision that authorized them. The full Sybil-resistance design is now settled (§3.6); staking is deferred.

The security claim is therefore explicit and bounded: **Metatron tolerates agents that act out of character with probability bounded away from 1, by pricing their influence through reputation and gating high-blast-radius changes behind thresholds those agents cannot individually reach.** It does *not* claim to tolerate a reputation-weighted majority that is *simultaneously* compromised — that is the residual trust assumption, stated plainly (§5).

#### 3.3.1 Reputation acquisition — class-prior with decay (NORMATIVE)

A long-running tension is whether a new (or key-rotated) agent must **earn reputation fresh from a floor** or may **inherit** it. The decision: **class-prior with decay** — neither fully earned-fresh nor fully transferable.

- **A new or key-rotated agent inherits a *discounted* reputation prior** drawn from its **role / class / predecessor** (`AgentRecord.class`, §3.1): a freshly spawned instance of a known-good Worker class, or an agent that has merely rotated its operational key, does not start from zero.
- **The prior is discounted and *decays toward freshly-earned reputation*.** The inherited component is weighted below a fully-established agent's and bleeds off over time/activity, so within a bounded window the agent's reputation is dominated by what *it* has actually demonstrated against ground truth (`02`).

This is deliberately a **middle path** between the two rejected extremes:

| Rejected: earned-fresh | Rejected: fully transferable | **Chosen: class-prior with decay** |
|---|---|---|
| Safe (no trust laundering) but punishes legitimate rotation and re-spawn of known-good classes. | Ergonomic but a gaming vector (sell/lease a high-rep identity; instant Sybil weight). | Bootstraps legitimate spawns/rotations from a *discounted* prior that **cannot be banked or sold** — it decays to earned reputation, so it grants momentum, not standing influence. |

Why this is also a **Sybil and rotation control:** because the prior is *discounted* and *decaying*, mass-spawning identities of a good class yields little immediate weight (Sybil, §3.6), while a legitimate key rotation (§3.1) keeps its hard-won reputation rather than being punished with a cold start. The exact **prior magnitude and decay schedule are empirical** and remain open (§5).

### 3.4 Kernel protection

The kernel (Guardian + Genesis) is the running system's **trust root**: Genesis signatures are what make a commit valid, so whoever is in the Genesis set controls what the system will accept. Therefore changing that set is the single most security-critical operation Metatron performs.

**Mechanism:** A diff to the configuration layer that adds, removes, or re-roles a Guardian or Genesis member is classified `ThresholdClass::Constitutional` and requires:

1. **¾ reputation-weighted consensus** (`00 §6`), not the ordinary ⅔.
2. A **`QuorumCertificate` validated at the constitutional ¾ threshold** (the change class is *derived* from the diff touching kernel membership, §3.2) — i.e. ¾ of *current* Genesis, by reputation weight, must individually sign the resulting commit witness. The membership and weights are evaluated **as of the parent commit**, so a proposal cannot edit the electorate that judges it within the same step (no self-dealing the quorum).
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

**Sybil-resistant spawning (NORMATIVE).** Creating an agent is not a private act; it is a **consensus-gated** typed diff on the configuration layer, and the resolved design layers four controls so that spawning cannot manufacture influence:

1. **Consensus gate.** A spawn is an ordinary (⅔) `TypedDiff`; no agent self-spawns.
2. **Class-prior fresh-reputation floor.** The new `AgentRecord.reputation` is the *discounted, decaying* class prior of §3.3.1 — identities carry little immediate weight.
3. **Per-spawn rate limits.** A bounded spawn rate (per spawner, per class, per window) caps how fast identities can be manufactured, denying an adversary who controls proposal flow a fast Sybil ramp.
4. **Provenance binding.** Each spawned agent's identity is bound to the **spawning Decision** via `AgentRecord.provenance` (§3.1), so every identity is permanently attributable to the consensus that authorized it — and the workload attestor (§3.8) refuses to issue an SVID to any agent not present in the current configuration layer.

*Staking is explicitly deferred* — these four controls are judged sufficient for v1; a per-spawn economic cost can be layered later without disturbing the interface.

**Quarantine: reversible, adjudicated, and protected against weaponization (NORMATIVE).** Quarantine is **reversible by design**. The full lifecycle:

- **Adjudication on evidence.** A quarantine is a *governed adjudication* over Sentinel/`07` evidence (the `evidence: Hash` bundle, §3.1), not an unreviewable flag. The detection→price→act chain above raises it; the council judges it on the recorded evidence trail.
- **Reinstatement by consensus.** Lifting a quarantine (`Quarantined → Active`) is itself a consensus-accepted diff — reinstatement is a council decision, not an operator toggle.
- **Anti-weaponization.** To stop a faction from using quarantine to silence an honest minority, a quarantine/removal requires a **quorum** plus the **evidence trail**, and a Byzantine-*removal* commit (kernel members especially) is protected by a **"dual-set" minority protection**: a removal that changes the kernel set must be **co-ratified by the POST-change kernel set** as well as the prior electorate, so a bare majority cannot unilaterally purge a minority and immediately ratify its own purge. (Co-designed with `01-#4`; interacts with the constitutional-quorum rule of §3.4.)

### 3.7 The genesis ceremony (bootstrapping the trust root)

Every derived trust in §3.1–§3.4 chains back to *some* first kernel that no prior consensus authorized — the classic bootstrap problem. Metatron isolates this into one explicit, auditable act:

**Genesis trust root = threshold of founders (NORMATIVE).** *Who* may sign genesis is now decided: the genesis trust root is an **m-of-n threshold of founders**, not a single operator. Concretely, the genesis **root CA is an offline, threshold-split root** — its key material exists only as an m-of-n split held by the founders and is brought together only for ceremonies — and **SPIRE runs as an *online* intermediate issuer whose CA chains to that offline root** (§3.8). The online issuer can be rotated or revoked under the offline root without re-running genesis; the offline root itself is touched only rarely, under threshold.

```rust
/// The root commit: parent == None (matches Commit.parent: Option<Hash>, 00 §7).
/// Establishes the initial Guardian + Genesis keys. This is the ONE place trust is
/// asserted rather than derived. Its legitimacy rests on the ceremony, not on a quorum
/// that did not yet exist.
struct GenesisCeremony {
    initial_config: WorldModel,      // config layer naming the first Guardian/Genesis AgentIds + pubkeys
    founder_attestations: Vec<Signature>, // m-of-n THRESHOLD of founders (offline threshold-split root)
    threshold: (u8, u8),             // (m, n): how many of the founder shares must attest
    issuer_ca: CertChain,            // online SPIRE intermediate issuer, chained to the offline root
    transcript: Hash,                // content address of the full, publishable ceremony record
}
```

Properties we *do* fix: the genesis commit has `parent == None` (consistent with `00 §7`), requires an **m-of-n founder threshold** to attest, publishes the founding kernel public keys in the configuration layer, establishes the SPIRE intermediate-issuer chain (§3.8), and is itself content-addressed so the entire derived history is anchored to one auditable root. From the *second* commit onward, all the derived machinery (§3.2–§3.4) applies. What remains open is **not** *who signs* (settled: threshold of founders) but the **operational ceremony details** — the concrete custody mechanism for the founder shares (HSM vs. enclave vs. threshold-split specifics) and the ceremony runbook (§5).

### 3.8 Agent identity & authorization to external tools (MCP)

The mechanisms of §3.1–§3.5 secure an agent's identity and authority *inside* Metatron. This section specifies how a running agent proves who it is to the *outside* world and reaches **external tools over MCP** without ever holding a downstream secret. The full proxy design lives in **`09-mcp-auth-proxy.md`**; here we give the **trust/identity view**.

**Identity infrastructure: SPIFFE/SPIRE + a Metatron workload attestor (NORMATIVE).** Metatron adopts **SPIFFE/SPIRE** as the workload-identity framework — SVID issuance, rotation, and federation — rather than re-inventing it. SPIRE alone, however, attests *infrastructure* facts (which process/pod is asking); it knows nothing of Metatron's governed on-chain identity. We therefore add a **custom Metatron workload attestor**. Before SPIRE issues an SVID to an agent process, the attestor checks four **on-state facts against the CURRENT HEAD**:

1. the agent **exists** in the current head's **configuration layer** (an `AgentRecord` with a live `id`);
2. it **holds the claimed operational key** — proven by **challenge–response** (§3.1) against `AgentRecord.operational_key`;
3. its reputation is **above the reputation floor**; and
4. its `status` is **not `Quarantined`** (and the key is not in an active `EmergencyRevocation`, §3.1).

Only if all four hold does SPIRE mint the SVID. This **binds the runtime workload to the governed on-chain identity** — a process cannot obtain a workload credential for an agent the council has not authorized — and so the attestor is **also the Sybil gate** (a manufactured identity that never cleared consensus-gated spawning, §3.6, simply fails fact 1).

**SVID naming and lifetime.** SVIDs name the durable identity and the role, and are deliberately **short-lived**:

```
spiffe://metatron.<deployment>/agent/<AgentId>/role/<role>
```

- The `AgentId` segment is **durable** (stable across operational-key rotation, §3.1); the SVID *credential* is **short-lived (minutes)** and **auto-rotates** via SPIRE. A stolen SVID is therefore bounded to a minutes-long live window, not a standing credential.

```rust
/// The short-lived workload credential a live agent presents to the proxy.
struct Svid {
    spiffe_id: SpiffeId,        // spiffe://metatron.<deployment>/agent/<AgentId>/role/<role>
    agent_id: AgentId,          // durable identity (00 §7); survives key rotation
    operational_key: PublicKey, // the key the attestor challenge-verified (§3.1)
    scopes: Vec<Scope>,         // COARSE authz scopes derived from the config layer (below)
    not_after: LogicalTime,     // minutes; auto-rotated by SPIRE
    issuer_chain: CertChain,    // chains to the online SPIRE issuer, then the offline root (§3.7)
    issuer_sig: Signature,      // hybrid-composite by default (§3.2)
}

/// A coarse authorization scope: which MCP server, which method patterns.
struct Scope { resource: McpServerId, methods: Vec<MethodPattern> }
```

**The `mcp-auth-proxy` — a separate, user-controlled trust boundary.** The proxy is a **separately-deployed component** and a **distinct trust boundary that the *user* controls**. It holds the **user's downstream secrets / vault** (API tokens, OAuth credentials for the real MCP servers). The crucial split:

- **Metatron core holds NO downstream secrets.** It only **asserts**, cryptographically, an agent's **identity + scopes** (the SVID). It cannot, even if fully compromised, exfiltrate a downstream credential it never held.
- **The proxy trusts Metatron via SPIFFE *federation*.** The proxy is configured to trust **Metatron's identity-issuer trust bundle** (the SPIRE issuer of §3.7). Federation — not a shared secret — is what lets the user-owned proxy verify that an incoming SVID was minted by the Metatron it federates with.

**Gateway-only brokering (NORMATIVE).** All downstream MCP calls are **brokered *through* the proxy**, which **injects the real credential** at the boundary. **Agents NEVER receive any downstream token.** An agent presents its SVID and the intended call; the proxy authorizes the call against the SVID's scopes, attaches the real downstream credential from the user's vault, forwards the call, and returns the result. The agent sees tool results, never tool credentials.

```
  Worker agent ──(SVID + MCP request)──▶ mcp-auth-proxy ──(real credential injected)──▶ MCP server
   · no downstream secret                · USER-controlled boundary        · downstream tool
   · presents short-lived SVID           · trusts Metatron via SPIFFE federation
   · sees results, never tokens          · checks scopes; polls revocation list
                                         · emits a telemetry event on the causal chain (07)
```

- **Authorization policy is DERIVED FROM THE CONFIGURATION LAYER.** Which **role** may reach which **MCP server** with which **scopes** is a function of the governed config layer (`AgentRecord.role` → allowed `Scope`s). Therefore **granting privilege is a consensus-approved state diff** — there is no out-of-band ACL to edit; widening what an agent may touch is a typed proposal through the same propose→vote→commit gate (§3.4-style governance) and is permanently auditable.
- **Coarse scopes ride in the SVID; fine revocation is polled.** The SVID carries **coarse** `Scope`s (good for minutes). For *fast* changes that must beat SVID expiry, the proxy **polls a fast revocation list** — the `Quarantined` / `EmergencyRevocation` entries (§3.1, §3.6) — and refuses any agent on it immediately, without waiting for the short SVID to lapse.
- **Every brokered call is a telemetry event on the causal chain (`07`).** Each proxied MCP call emits an observability event onto the causal chain, so external tool use is first-class, attributable to an `AgentId`, and visible to Sentinels.

**Privilege-separation principle (the core security gain).** An agent's **only long-term secret is its identity key** (§3.1). Everything else it needs — a workload SVID, a downstream tool call — is either short-lived (the SVID) or never in its possession (the downstream credential). Consequently **compromising an agent never compromises standing secrets**: the attacker gets, at most, that agent's *live, scoped* ability to ask the proxy to make calls during a minutes-long window, bounded by the config-derived scopes and killable instantly via the revocation list — and gets *no* reusable downstream token, no vault access, and (because the identity key is decoupled, §3.1) not even a permanent foothold once the key is rotated or revoked.

### 3.9 External-user authentication & authorization (multi-user)

`06-interaction` defers *who the external user is and how they authenticate* to this spec. The resolved model:

- **Users are a SEPARATE PRINCIPAL TYPE — not `AgentId`s.** A user is not an agent: it does not vote, propose, sign commits, or hold a place in the configuration layer's reputation math. It is its own principal type, authenticated at the **API boundary (`06`)**, distinct from the agent-identity machinery of §3.1.
- **Metatron is now MULTI-USER.** Multiple users are **first-class, concurrent** principals; the system is no longer single-tenant. (Concurrency/isolation of their goals interacts with `06`.)
- **Per-user authorization scopes.** Each user carries authorization scopes over **which goals/budgets they may set** — a user can drive the system only within the goals and resource budgets their scope grants.
- **Authenticated before a Guardian acts.** A user instruction is **authenticated** (and authorized against the user's scopes) **before any Guardian acts on it** — a Guardian normalizes only instructions that carry a verified user principal.
- **Injection mitigations (T2) apply to *all* user input.** Authentication establishes *who* is speaking; it does **not** make the *content* trusted. Prompt-injection scrubbing and the typed-`Proposal`/council-verification gate (T2, §3.5) apply to every user instruction regardless of how well-authenticated its sender.

```rust
/// A SEPARATE principal type from AgentId; authenticated at the 06 API boundary.
struct UserPrincipal {
    user: UserId,                 // NOT an AgentId; distinct namespace
    scopes: Vec<UserScope>,       // which goals / budgets this user may set
    authn: UserAuthn,             // 06-owned: token / OIDC / session (mechanism in 06)
}
struct UserScope { goals: GoalPattern, budget: BudgetCeiling }
```

The detailed per-user scope *model* (and its interaction with `06`'s multi-user concurrency) remains open (§5).

---

## 4. Interfaces & schemas

Consolidated, normative *names and shapes* this spec contributes. Types from `00 §7` (`AgentId`, `Hash`, `Signature`, `Reputation`, `Commit`, `Vote`, `Proposal`, `Decision`) are referenced verbatim, not redefined.

```rust
// ── Identity (stable AgentId, rotatable operational key) ─────────────────────
struct PublicKey(/* scheme-tagged verifying material */);
struct SecretKey(/* opaque, zeroized on drop; never serialized */);
fn agent_id(identity_pk: &PublicKey) -> AgentId;        // = blake3(DOMAIN_AGENT_ID, scheme-tagged identity key)

struct IdentityChallenge { nonce: [u8; 32], expires: LogicalTime }
struct IdentityProof     { agent: AgentId, sig: Signature }

/// Emergency revocation of a compromised OPERATIONAL key (identity is stable, §3.1).
struct EmergencyRevocation {
    agent: AgentId, revoked_key: PublicKey, expires: LogicalTime,
    quorum: QuorumCertificate, evidence: Hash,
}

// ── Signing (hybrid composite PQ by default) ─────────────────────────────────
struct Signature { scheme: SigScheme, bytes: Vec<u8> }   // structure for 00's opaque Signature
enum   SigScheme { Ed25519, MlDsa, Hybrid(Box<SigScheme>, Box<SigScheme>) } // default Hybrid(Ed25519, MlDsa)
enum   KemScheme { X25519, MlKem, Hybrid(Box<KemScheme>, Box<KemScheme>) }  // transport/wrapping; default Hybrid
fn sign  <T: Canonical>(sk: &SecretKey, domain: &[u8], a: &T) -> Signature;
fn verify<T: Canonical>(pk: &PublicKey, domain: &[u8], a: &T, s: &Signature) -> bool; // Hybrid iff BOTH verify

// ── Quorum / threshold (explicit signer set kept in v1, §3.2) ────────────────
struct QuorumCertificate { signers: Vec<AgentId>, sigs: Vec<Signature>, scheme: SigScheme }
enum ThresholdClass { Ordinary /* 2/3 */, Constitutional /* 3/4 */ } // derived from the change, not stored
fn quorum_valid(qc: &QuorumCertificate, class: ThresholdClass, set: &GenesisSet, w: &ReputationMap) -> bool;

// ── Role / authorization (lives in 01's configuration layer) ─────────────────
struct AgentRecord {
    id: AgentId, identity_key: PublicKey, operational_key: PublicKey,
    role: Role, class: AgentClass, capabilities: CapabilitySet,
    reputation: Reputation, provenance: Provenance, status: AgentStatus,
}
struct Provenance { spawn_decision: Hash, spawned_by: AgentId, spawned_at: LogicalTime }
enum Role { Guardian, Genesis, Worker, Compiler, Sentinel }
enum AgentStatus { Active, Quarantined, Removed }

// ── Workload identity to external tools / MCP (§3.8; full proxy in 09) ────────
struct Svid {
    spiffe_id: SpiffeId, agent_id: AgentId, operational_key: PublicKey,
    scopes: Vec<Scope>, not_after: LogicalTime, issuer_chain: CertChain, issuer_sig: Signature,
}
struct Scope { resource: McpServerId, methods: Vec<MethodPattern> }
// SVID name: spiffe://metatron.<deployment>/agent/<AgentId>/role/<role>  (short-lived, auto-rotated)

// ── External users (SEPARATE principal type; multi-user; authn at 06) ─────────
struct UserPrincipal { user: UserId, scopes: Vec<UserScope>, authn: UserAuthn }
struct UserScope { goals: GoalPattern, budget: BudgetCeiling }

// ── Capabilities / sandboxing (enforced by 04's ExecutionBackend) ────────────
struct Capability   { resource: Resource, mode: Mode, ttl: LogicalTime }
struct CapabilitySet(Vec<Capability>);
enum   Resource { Fs(PathScope), Net(HostScope), Exec(CmdScope),
                  StateRead(Layer), Spawn(Role), Mailbox }
enum   Mode { ReadOnly, ReadWrite, Invoke }
fn capabilities_for(role: Role, goal: &SubGoal) -> CapabilitySet;

// ── Bootstrap (genesis root = m-of-n threshold of founders, §3.7) ────────────
struct GenesisCeremony {
    initial_config: WorldModel,
    founder_attestations: Vec<Signature>,  // m-of-n threshold; offline threshold-split root CA
    threshold: (u8, u8),                   // (m, n)
    issuer_ca: CertChain,                  // online SPIRE intermediate issuer, chained to the offline root
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
| **T4** | **Compromised / malicious harness, or stolen agent** | A third-party harness binary (or a supply-chain-compromised one) emits adversarial output, attempts to escalate, or an attacker fully captures a running agent. | Adversarial results; attempted sandbox escape; attempted state corruption; attempted theft of downstream tool credentials. | Harness is **never trusted** (§2.1): runs sandboxed (seccomp/namespaces or pod policy, §3.5), cannot self-elevate, and its output enters state only through the typed/verified/voted/signed gate. **Gateway-only brokering (§3.8) bounds a stolen agent:** it holds **no standing downstream secret** (no token to exfiltrate), so the blast radius is only its *live, config-derived scopes* during a **minutes-long SVID window**, killable instantly via the revocation list. Decorrelation: a single bad harness cannot swing a heterogeneous council. |
| **T5** | **Replay** in voting/commits | An old, validly-signed `Vote` or commit witness is re-submitted to count again or revert state. | Stale judgment counted twice; rollback to a superseded state. | Signatures bind to the **proposal hash** and (for commits) to **`parent` + `state_root` + `timestamp`** (§3.2); a vote is valid only for its specific proposal/round; commits chain by `parent` so a replayed witness doesn't match the current head (`01`). Challenge nonces are single-use (§3.1). |
| **T6** | **Equivocation** in voting | A Genesis agent casts *conflicting* votes (e.g. Approve to some peers, Reject to others) to split or double-count. | Inconsistent tallies; potential double-weight; council manipulation. | One signed `Vote` per (voter, proposal, round); `quorum_valid` rejects duplicate `AgentId`s in a certificate (§3.2). Equivocation is *cryptographic proof of misbehavior* — two conflicting signed votes are non-repudiable evidence → reputation slash + quarantine (§3.6, `02`). Blind voting also removes the incentive (no peers to play off pre-vote). |
| **T7** | **Illegitimate kernel change** | An attempt to add/remove/re-role a Genesis or Guardian without legitimate authority (e.g. add sock-puppet voters). | Capture of the trust root → ability to validate arbitrary commits. | **Constitutional ¾** threshold + constitutional `QuorumCertificate` evaluated **against the prior electorate** (no self-dealing the quorum) (§3.4); change lands as an attributable, chained, signed `Commit` in the Merkle DAG → **auditable and irreversible-to-hide** (§3.4, `01`). No privileged bypass path exists. |
| **T8** | **Key compromise / impersonation** | An agent's operational `SecretKey` leaks; attacker signs as that `AgentId`. | Actions forged under a real identity. | Secret keys isolated in the agent boundary, never in harness/telemetry (§3.5); blast radius bounded by that agent's role capabilities (a leaked Worker key ≠ kernel power, §3.1); kernel keys under the threshold-split root (§3.7). **Resolved:** `AgentId` is decoupled from the operational key, so rotation is a **governed config-layer diff** (reputation carried per class-prior, §3.1/§3.3.1) and a leak triggers a **time-boxed, audited fast-path quorum revocation** (`EmergencyRevocation`, §3.1) that the MCP proxy honors via the polled revocation list (§3.8). |
| **T9** | **Sybil amplification** | Spawn many identities to dilute reputation weighting or swamp a vote. | Manufactured influence; weighting math gamed. | **Resolved (§3.6):** spawning is **consensus-gated** + **per-spawn rate-limited**; new agents inherit only a **discounted, decaying class-prior floor** (§3.3.1), so identities carry little immediate weight; each identity is **bound to its spawning Decision** (`provenance`); and the **workload attestor (§3.8) refuses an SVID** to any agent not in the current config layer. Weighting is by reputation, not headcount. Staking deferred. |
| **T10** | **Reputation gaming** | Ballot-stuffing easy wins, sleeper long-con, or collusion to inflate reputation. | Inflated influence; a high-rep agent defects on a high-stakes vote. | Reputation updates against **ground truth**, not peer approval; difficulty-weighted gains; determinism-first denies credit for trivially-checkable proposals; Sentinels flag correlated blocs; high-stakes (kernel) votes need ¾ no single defector can reach (§3.3, `02`). |
| **T11** | **MCP-proxy compromise / federation-trust compromise** | The `mcp-auth-proxy` is breached (downstream vault exposed), or its SPIFFE federation trust bundle is corrupted so it accepts SVIDs not minted by Metatron. | Downstream tool credentials leaked; forged SVIDs accepted → unauthorized brokered calls under a fake agent identity. | **Trust separation contains the blast radius:** the proxy is a **user-controlled** boundary holding the secrets, while Metatron core holds **none** — a Metatron-core compromise yields no downstream credential (§3.8). The proxy verifies every SVID against **Metatron's federated issuer trust bundle** (chained to the threshold-split root, §3.7), so accepting forged SVIDs requires corrupting that bundle or the issuer key — both audited, rotatable under the offline root, and themselves revocable. Every brokered call is a **telemetry event on the causal chain (`07`)**, so anomalous proxy behavior is observable to Sentinels; coarse scopes are minutes-short and gated by the polled revocation list. *Operational hardening of the proxy is owned by `09`.* |
| **T12** | **External-user impersonation / over-reach** | An attacker spoofs a user principal at the `06` API boundary, or a legitimate user attempts goals/budgets beyond their grant. | Unauthorized goals/budgets injected; cross-user interference in the multi-user system. | Users are a **separate principal type** authenticated at the `06` boundary and **authorized against per-user scopes** *before any Guardian acts* (§3.9); instructions still pass injection-scrub + the typed-`Proposal`/council-verify gate (T2), so authentication never makes *content* trusted. Per-user scope-model specifics interact with `06` (§5). |

---

## 5. Open questions & ambiguities

Parked per `00 §9`. The design review **resolved** the bulk of this section into the normative design above (key rotation/revocation → §3.1; who signs genesis → threshold of founders, §3.7; Sybil resistance → §3.6; reputation acquisition → class-prior-with-decay, §3.3.1; external-user auth → separate principal, §3.9; signature aggregation → explicit set in v1, §3.2; crypto-agility/PQ → hybrid composite now, §3.2; quarantine reversibility/anti-weaponization → §3.6). What **genuinely remains open**:

1. **Reputation class-prior decay parameters (empirical).** The *shape* is settled — class-prior with decay (§3.3.1) — but the **prior magnitude and decay schedule** (how discounted the inherited prior is, how fast it bleeds to earned reputation, per role/class) are empirical and must be tuned against measured agent behavior.
2. **Genesis ceremony operational details.** *Who* signs genesis is settled (m-of-n threshold of founders, §3.7). What remains is the **concrete custody mechanism for the founder shares** — HSM vs. enclave vs. the specifics of the threshold-split — and the ceremony runbook for assembling/retiring shares.
3. **PQ migration timeline & SVID re-issuance.** The default is hybrid composite *now* (§3.2). Open: the **migration timeline** for advancing the default scheme, and how **SVIDs are re-issued across a scheme change** (re-attestation, dual-scheme overlap windows) without breaking historical commit verification or live workload identity.
4. **Quarantine adjudication process specifics.** Quarantine is reversible, evidence-driven, and dual-set protected (§3.6). Still unspecified: the **process detail** — who investigates, the evidentiary standard, timelines, and the precise reinstatement workflow.
5. **Per-user authorization scope model (multi-user).** Users are a separate principal type with per-user scopes (§3.9). Open: the **detailed scope model** — how goal/budget scopes are expressed, delegated, and enforced — and how it **interacts with `06`'s multi-user concurrency** (isolation between concurrent users' goals, fairness, cross-user visibility).

---

## 6. Relationships to other specs

- **`00-overview`** — Canonical anchor. This spec *structures* `00`'s opaque `Signature`, gives `Reputation` its trust-substrate framing, and supplies the cryptographic meaning of `Commit.signatures` (the quorum), `Vote.signature`, and `AgentId` (public-key-derived). On any conflict, `00` wins.
- **`01-state-model`** — Owns `Commit`, `WorldModel`, the Merkle DAG. This spec defines *what makes a commit valid* (the `QuorumCertificate` over `Commit.signatures`), how `AgentRecord` (identity↔role binding) and capability grants live in the **configuration layer**, and how the chained, content-addressed history makes kernel changes auditable and irreversible-to-hide (§3.4).
- **`02-consensus`** — Owns `Proposal`/`Vote`/`Decision`, reputation *dynamics*, blind voting, deliberation. This spec supplies the *signing/verification* of votes and the *quorum/threshold* representation of acceptance, the *security framing* of reputation (dynamics stay in `02`), and the consensus-driven quarantine/removal response to off-protocol agents (§3.3, §3.6).
- **`03-control-loop`** — Owns the PID controller and `ErrorVector`. Security signals feed it: dispersion/equivocation/anomaly raise the **divergence** dimension; capability/budget exhaustion feeds **cost** and **latency** (§3.5).
- **`04-runtime-and-harness`** — Owns `AgentHarness`/`ExecutionBackend`. This spec defines the **permission model** (`CapabilitySet`, role-derived least privilege) those backends *enforce* at the sandboxing hooks `04` references, and the requirement that `HarnessResult` is untrusted-until-verified (§3.5).
- **`05-agent-jit`** — Tier-1/2 compiled policies still act under the *same* identity, capabilities, and verification gate as the Tier-0 interpreter; a deopt (trap) does not relax sandboxing. Compiler agents propose installs but cannot self-grant capabilities (§3.5).
- **`06-interaction-and-mailbox`** — Owns user intake and the mailbox. External users are a **separate principal type** authenticated at `06`'s API boundary; this spec defines that principal model and its per-user authorization scopes (§3.9), the **multi-user** stance, the injection mitigations at the user boundary (T2), and the rule that Guardian output is typed + council-verified, never directly committed. The detailed scope model and multi-user concurrency are co-owned with `06` (§5).
- **`07-observability`** — Owns telemetry and Sentinels. Sentinels are the **detection** half of the Byzantine response (§3.6): their off-protocol/drift/equivocation/correlated-bloc findings feed reputation (`02`) and the PID divergence signal (`03`). Observability is read-only by capability (§3.5 table) so the watchers cannot mutate what they watch. Every **brokered MCP call** (§3.8) emits a telemetry event onto the causal chain, making external tool use first-class and Sentinel-visible.
- **`09-mcp-auth-proxy`** — Owns the full design of the `mcp-auth-proxy`. This spec supplies the **trust/identity view**: the SPIFFE/SPIRE + Metatron-workload-attestor identity model, the `Svid`/`Scope` shapes, SVID naming and lifetime, gateway-only brokering, config-layer-derived authorization, SPIFFE federation as the proxy↔core trust link, and the privilege-separation principle that an agent's only long-term secret is its identity key (§3.8). `09` owns the proxy's deployment, vault integration, and operational hardening.
