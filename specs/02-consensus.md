# Metatron — Consensus Protocol (Governance Plane)

> **Status:** Research architecture specification (v0.1)
> **Plane:** Governance
> **Owns:** How a typed `Proposal` becomes (or fails to become) a signed `Commit` on the Merkle DAG.
> **Anchor:** This spec is subordinate to [`00-overview.md`](./00-overview.md). It reuses that document's vocabulary and canonical types (`Proposal`, `Vote`, `Decision`, `Commit`, `WorldModel`, `TypedDiff`, `ErrorVector`, `Reputation`, `AgentId`, `Signature`) verbatim. Where this spec disagrees with the anchor, the anchor wins.
> **Reads from / writes to state:** consumes the current `WorldModel` head and writes accepted updates as `Commit`s to the Merkle DAG defined in [`01-state-model.md`](./01-state-model.md) (not yet authored; this spec relies on the anchor's `Commit`/`WorldModel` shapes until it is).

---

## 1. Purpose

The Governance plane answers exactly one question, repeatedly:

> Given the current world-model head and a typed `Proposal` authored by a Guardian, should the proposal be **committed** as the new desired state — and if the council can't decide, **what does it do instead**?

This document specifies the **consensus protocol** that produces that answer. It is the mechanism by which a *council of stochastically unreliable LLM-backed Genesis agents* nonetheless makes **trustworthy, replayable, signed** decisions about how Metatron evolves.

The protocol is **not** a classical BFT agreement protocol (PBFT, Tendermint, HotStuff) bolted onto a chat room. Those protocols solve a *different* problem — agreement among a fixed set of nodes in the presence of an adversary who may behave arbitrarily and **collude**. Our failure model is different (see §2), and so our protocol is different. We keep the BFT *posture* (assume members fail, require a supermajority, sign everything, serialize a single head) but replace the adversarial-collusion threat model with a **stochastic-independent-error** model, and we replace "vote on the raw question" with a **layered funnel** that constrains, mechanically checks, decorrelates, weights, and only then aggregates judgment.

What this spec **does not** own:

- The *shape* of a `TypedDiff` and the world-model it mutates → [`01-state-model.md`](./01-state-model.md).
- Where the steering-loop divergence signal *goes* once we emit `dispersion` → [`03-control-loop.md`](./03-control-loop.md).
- Who *authors* proposals and how ambiguity is escalated to the user → [`06-interaction-and-mailbox.md`](./06-interaction-and-mailbox.md).
- Key material, the signing scheme, equivocation forensics, and the full threat model → [`08-trust-and-security.md`](./08-trust-and-security.md).

---

## 2. The Failure Model: Probabilistically Byzantine

This section is the conceptual foundation. Every design choice below derives from it.

### 2.1 LLM agents are not classically Byzantine

Classical Byzantine Fault Tolerance assumes faulty nodes may behave **arbitrarily and adversarially**, including **colluding** to maximize damage: lying consistently, coordinating their lies, and targeting the precise weak point of the protocol. BFT buys safety against a worst-case, *correlated*, intelligent adversary controlling up to *f* of *n* nodes.

A council of Genesis agents — each an LLM behind a harness — fails differently:

- **They fail independently.** Two agents from different model families, given the same proposal under different prompts and seeds, do not coordinate their mistakes. There is no shared adversarial controller.
- **They fail stochastically.** A given agent is *right with some probability* on a given class of judgment, and *wrong with the complementary probability*. The wrongness is drift, hallucination, going off-protocol, latching onto a spurious feature — not a targeted attack.
- **Their errors are, by default, only weakly correlated** — and crucially, the correlation is something we can **engineer down** (decorrelation) or accidentally **engineer up** (premature deliberation → herding).

We call this regime **probabilistically Byzantine**: members do produce arbitrary, wrong, off-protocol outputs (the "Byzantine" part), but they do so as *independent random faults* rather than as a *coordinated adversary* (the "probabilistic" part). The residual possibility of a *genuinely* adversarial or compromised member — a leaked key, a poisoned model — is real but is treated as a security threat, handled in [`08`](./08-trust-and-security.md), not as the common case the consensus protocol is tuned for.

> **Design consequence.** Because the common-case fault is *independent and stochastic*, we are not forced to pay the full price of adversarial BFT for every decision. We can instead **exploit independence** — which is precisely what classical BFT cannot assume and therefore cannot use.

### 2.2 The Condorcet Jury Theorem: independence is a resource

The **Condorcet Jury Theorem (CJT)** is the load-bearing result. In its basic form:

> Let *n* voters each decide a binary question independently, each correct with probability *p*. If *p > ½* (better than random) and votes are aggregated by majority, then the probability the *majority* is correct **strictly increases** with *n* and **tends to 1** as *n → ∞*. If *p < ½*, the same aggregation drives the majority's correctness toward 0.

Three corollaries drive the entire protocol:

1. **Better-than-random + independent + aggregated ⇒ error → 0.** A council of mediocre-but-honest, *independent* jurors is collectively far more reliable than its best single member. This is *why a council can be trustworthy even though every member is unreliable.*
2. **The premises are the design targets.** CJT's power is contingent on two premises we must actively manufacture:
   - **Competence (`p > ½`).** Each member must be *better than random on the question actually put to it*. We don't get to assume this — we **engineer** it by **constraining the question** (§4) so that what remains is something an LLM juror is actually good at.
   - **Independence.** The "independent" in the theorem is doing enormous work. Correlated jurors behave like *one* juror with the reliability of one juror — the *n →* benefit evaporates. We **engineer** independence by **decorrelating the council** (§5).
3. **The theorem inverts below ½.** If we put a question to the council on which members are *worse than random* (e.g. a deeply subjective aesthetic call dressed up as a factual one, or a domain all members hallucinate in the same direction on), aggregation makes things **worse**, confidently. This is the protocol's most important failure mode to guard against, and the reason **determinism-first** (§4.2) and **escalation** (§7) exist: never aggregate votes on a question the council is collectively worse-than-random on — *check it* or *escalate it* instead.

> **Low dispersion is not evidence of correctness.** A *correlated, confidently-wrong* council — members sharing a base model that hallucinate in the same direction — produces **low** dispersion *and* a confident posterior while being collectively wrong (the §2.2-corollary-3 inversion in its most dangerous form). Agreement measures correlation, not truth. The protocol therefore never treats low dispersion as a health signal on its own; it must be read against **verification coverage** — the fraction of the decision that was machine-decidable (G0) — which is surfaced as a first-class signal owned by [`07`](./07-observability.md) and consumed by the controller in [`03`](./03-control-loop.md). Stress-testing confident agreement with a **decorrelated red-team lane** (§5.1) is the in-protocol defense.

### 2.3 The two central levers

From §2.2, everything we can do to make the council trustworthy reduces to **two levers**:

| Lever | What it does | Mechanism in this spec |
|-------|--------------|------------------------|
| **L1 — Constrain the output space** | Raises each juror's per-question competence `p` toward 1 and shrinks the space in which a juror can be nondeterministic. The more a judgment is mechanically pinned, the higher `p`; in the limit (machine-checkable) `p = 1` and no vote is needed. | Typed proposals (§4.1) + deterministic verification-first (§4.2). |
| **L2 — Decorrelate the agents** | Restores the independence premise so the `n →` benefit of CJT is real, not nominal. | Diverse council composition + **blind** isolated-first voting (§5). The chief threat is **premature deliberation**, which *correlates* errors via herding/sycophancy (§5.3). |

> **Reading the rest of this spec:** §4 is L1. §5 is L2. §6 weights jurors by a **scalar track record** (a CJT refinement: weight competent jurors more) and **quarantines mechanical off-protocol behavior separately**. §7 is bounded deliberation, used *only* when blind aggregation is genuinely split. §8 turns the aggregate into a posterior + dispersion. Everything serves the two levers.

### 2.4 What "probabilistically Byzantine fault tolerant" buys us

We claim the protocol is **probabilistically Byzantine fault tolerant (pBFT-stochastic)** in this precise sense:

- For decisions reducible to machine-checkable predicates, tolerance is **deterministic and total**: a wrong member cannot flip the outcome, because the outcome isn't voted on (§4.2).
- For genuinely subjective decisions, tolerance is **probabilistic**: the probability that the *committed* decision is wrong decreases (a) with council size, (b) with per-member competence, and (c) as inter-member error correlation → 0; and it is *softly* nudged by track-record weighting letting chronically-out-of-step members' influence sag (§6).
- Against a *truly adversarial* minority (compromised keys, colluding members), safety degrades gracefully to the classical supermajority guarantee: an adversary controlling `< ⅓` of *voting weight* cannot force an ordinary commit, and `< ¼` cannot force a constitutional one. The forensic/eviction response to detected adversaries lives in [`08`](./08-trust-and-security.md).

> **This is a *mitigated*, not a *guaranteed*, tolerance claim — correlated failure is the headline residual risk.** Premise (c) above is the load-bearing one and it is **never fully met**: at `n = 5–7` the council is nowhere near CJT's asymptotic regime, and a *novel* correlated failure (a shared model basin, a shared prompt blind spot) breaks the independence the bound assumes — directly, not gracefully. Track-record weighting **cannot** rescue this: a first-time correlated failure has no record to weight against. We therefore treat independence as something to **measure and manufacture, not assume**: a quorum is only treated as independent when its **base-model / harness diversity is measured** to clear a floor (operational precondition, §5.1, §10.1), and confident agreement is stress-tested by a decorrelated red-team lane (§5.1). The open question of *correlation-aware aggregation* is tracked in §12(a).

---

## 3. Concepts

A glossary local to this spec, building on the anchor's §8.

| Term | Meaning |
|------|---------|
| **Council** | The set of Genesis agents eligible to vote on a given proposal. Membership is itself world-model state (`Configuration` layer); changing it is a constitutional amendment (§9.2). |
| **Quorum** | The minimum participating reputation weight required for a decision to be valid at all (liveness/safety floor; §10). Distinct from the **pass threshold**. |
| **Pass threshold** | The fraction of participating reputation weight whose posterior contribution must clear acceptance: **⅔** ordinary, **¾** constitutional. |
| **Verification** | The deterministic, machine-checkable phase (§4.2) producing a `VerificationReport`. Runs *before* any vote. |
| **Blind vote** | A `Vote` cast by a Genesis member **in isolation**, before seeing peers' votes or rationales (§5). The decorrelation primitive. |
| **Round** | One propose→critique→revise→re-vote cycle of bounded deliberation (§7). `rounds = 0` means the blind vote was decisive. |
| **Posterior** | Aggregated probability the proposal is correct (anchor `Decision.posterior`); the acceptance test is a threshold on it (§8). |
| **Dispersion** | A scalar measuring how *split* the council was after aggregation (anchor `Decision.dispersion`); emitted as the steering-loop **divergence** dimension (§8.3, → [`03`](./03-control-loop.md)). |
| **Track record** | A member's observed agreement-with-ground-truth rate on the **machine-measurable subset** of past decisions, blended with a class prior. A **scalar weight in [0,1]** that decays toward the prior (§6). Not a trained calibration model. |
| **Off-protocol** | Mechanically-detectable misbehavior — equivocation, schema violation, signature failure — caught deterministically and **quarantined** via quorum / human escalation, *separately* from the learned weight (§6.5). |
| **Ground truth** | The eventual signal a vote is scored against: the verification outcome where one exists, plus later execution outcomes and user feedback (§6.2). Often **lagged**. |
| **Escalation** | Handing an unresolved split to the user via the mailbox (§7.4, → [`06`](./06-interaction-and-mailbox.md)). |

### 3.1 The pipeline at a glance

```
                         Guardian authors
                              │
                              ▼
        ┌──────────────────────────────────────────────────────┐
        │  L1: CONSTRAIN                                         │
        │  ┌────────────┐   reject (malformed)                  │
        │  │ 1. Typed   │───────────────────────────▶ ✗ Rejected │
        │  │  proposal  │   schema-valid                        │
        │  └─────┬──────┘                                       │
        │        ▼                                              │
        │  ┌────────────┐   FAIL (invariant / type / test)     │
        │  │ 2. Determ. │───────────────────────────▶ ✗ Rejected │
        │  │  verify    │   PASS / INDETERMINATE                │
        │  └─────┬──────┘   (machine-decided → no vote needed)  │
        └────────┼──────────────────────────────────────────────┘
                 │  remaining subjective residue
        ┌────────┼──────────────────────────────────────────────┐
        │  L2: DECORRELATE                                       │
        │        ▼                                              │
        │  ┌────────────┐                                       │
        │  │ 3. BLIND   │  each member votes in isolation       │
        │  │  vote      │  (diverse harness/model/seed/role)    │
        │  └─────┬──────┘                                       │
        │        ▼                                              │
        │  ┌────────────┐                                       │
        │  │ 4. TRACK   │  weight each vote by SCALAR           │
        │  │  RECORD    │  track record (drifters → 0);         │
        │  │            │  off-protocol → quarantine (§6.5)     │
        │  └─────┬──────┘                                       │
        └────────┼──────────────────────────────────────────────┘
                 ▼
           decisive? ──yes──▶ rounds = 0 ─────────┐
                 │ no (genuine split)              │
                 ▼                                 │
        ┌────────────┐  bounded propose→critique   │
        │ 5. DELIB.  │  →revise→re-vote; critiques │
        │  (split    │  attach to PROPOSAL TEXT,    │
        │   only)    │  not to agents              │
        └─────┬──────┘                             │
              │ still split after max rounds?      │
              ├── yes ──▶ ESCALATE to user (06)    │
              ▼                                    ▼
        ┌──────────────────────────────────────────────┐
        │ 6. POSTERIOR + DISPERSION                      │
        │   posterior ≷ threshold → passed?             │
        │   dispersion → ErrorVector.divergence (03)    │
        └───────────────────┬───────────────────────────┘
                            ▼
                 passed → sign → Commit (01)
```

---

## 4. Lever 1 — Constrain the output space

> *You cannot be nondeterministic in a space you are not allowed to express.* — anchor §6.1

### 4.1 Layer 1: Typed proposals

A `Proposal` is **never free text**. It carries a `TypedDiff` (defined in [`01`](./01-state-model.md)) — a structured, schema-validated mutation of the world-model — plus an *advisory-only* `rationale`.

```rust
/// (anchor canonical type, repeated for locality)
struct Proposal {
    target_layer: Layer,         // Configuration | Progress | Both
    diff: TypedDiff,             // structured mutation; the ONLY load-bearing field
    rationale: Text,             // advisory; never parsed into the decision
    author: AgentId,             // a Guardian
    derived_from: Option<Hash>,  // control action (03) or user instruction (06)
}
```

**Admission control runs before anything else.** A proposal is mechanically gated by:

```rust
enum AdmissionError {
    SchemaInvalid(SchemaError),     // diff doesn't typecheck against the world-model schema
    StaleBase(Hash),                // derived_from / base head no longer current; rebase required
    UnauthorizedAuthor(AgentId),    // author is not a Guardian (separation of powers, anchor §3)
    SelfDealing,                    // author is also a Genesis voter on this proposal (proposer ≠ voter)
    RateLimited,                    // anti-spam / liveness protection
    MalformedRationaleEncoding,     // rationale not valid UTF-8 / exceeds bound (cheap, mechanical)
}

fn admit(p: &Proposal, head: &WorldModel, council: &Council) -> Result<Admitted, AdmissionError>;
```

> **This is the cheapest and most powerful filter in the system.** A malformed or out-of-schema proposal is **rejected mechanically, before any vote, at zero LLM cost**. Every malformed-output failure mode of an LLM author is absorbed here. The council never spends a token — let alone a vote — adjudicating something a parser can reject. This is L1 at its sharpest: the expressible space *is* the schema.

`rationale` is explicitly **advisory**. It may inform a juror's reasoning and is recorded for audit, but it is **not** machine-parsed into the decision and **never** substitutes for the typed `diff`. This prevents free-text smuggling of un-typed intent into the system of record.

### 4.2 Layer 2: Deterministic verification — *first*

> **Determinism-first (anchor §6.2):** anything machine-checkable is *checked, not voted on.* Voting is the fallback reserved for genuinely subjective judgment.

Before the council votes, the proposal is run through a **deterministic verification pipeline**: a battery of machine-checkable predicates over `(head, diff)`. These are *decided*, not *deliberated*. A verifier is, in CJT terms, a juror with `p = 1` — so it preempts the vote entirely.

```rust
enum CheckStatus { Pass, Fail, Indeterminate, Skipped }

struct Check {
    name: CheckName,             // stable id, e.g. "well_typed_diff", "invariant.acyclic_orgchart"
    status: CheckStatus,
    detail: Text,                // machine-generated evidence (counterexample, type error, failing test)
    cost: ResourceCost,          // time/compute spent; feeds ErrorVector.cost (03)
    deterministic: bool,         // true for replayable checks; must be true to be decision-bearing
}

struct VerificationReport {
    proposal: Hash,
    checks: Vec<Check>,
    verdict: VerificationVerdict,   // see below
    state_after: Option<Hash>,      // speculative world-model root if applied (for Pass)
    digest: Hash,                   // content hash; embedded in Decision and re-checkable on replay
}

enum VerificationVerdict {
    Refuted,        // >=1 deterministic, decision-bearing check FAILED -> reject WITHOUT a vote
    Certified,      // all applicable deterministic checks PASSED and they fully decide the proposal
    Residual,       // checks passed/indeterminate but a SUBJECTIVE residue remains -> proceed to vote
}
```

**Check categories** (the menu; which apply depends on `target_layer` and diff kind):

| Category | Example checks | Layer | Decision-bearing? |
|----------|----------------|-------|-------------------|
| **Well-formedness** | diff typechecks; references resolve; addresses exist | both | yes (subsumes §4.1 at semantic level) |
| **Invariant preservation** | org-chart stays acyclic; every Worker has ≥1 reachable goal; no orphaned sub-goal; kernel roles never drop below bootstrap minimum | Configuration | yes |
| **Progress consistency** | task-graph stays a DAG; no artifact references a non-existent task; resolved sub-goals stay resolved (monotonicity where required) | Progress | yes |
| **Executable checks** | *if the diff implies code/config that compiles or has tests:* it compiles; tests pass; lints clean | both | yes (when applicable) |
| **Resource/budget bounds** | proposed spawn count within budget; cost projection under the steering-loop cost ceiling | Configuration | yes |
| **Subjective residue** | "is this the *right* re-org?", "is this sub-goal decomposition *good*?" | both | **no — this is what the vote is for** |

**The branch that defines the protocol:**

- `Refuted` → the proposal is **rejected immediately, no vote**. (A wrong member cannot rescue a type-incorrect or invariant-violating diff. Determinism dominates.)
- `Certified` → the proposal is **accepted into the vote-free fast path**: it is *fully* decided by machine and may be committed without convening a vote (subject to the constitutional carve-out below). This is the ideal — L1 taken to completion.
- `Residual` → there is a genuinely subjective question left. *Only now* do we spend votes, and we spend them **only on the residue**, never on the parts already certified.

> **Constitutional carve-out.** Even a `Certified` proposal that changes **kernel membership** (adds/removes a Genesis or Guardian) is **never** auto-committed on the fast path. Constitutional amendments always require the council's signed ¾ vote regardless of how machine-checkable the diff is (§9.2). Determinism decides *correctness*; it does not get to decide *who governs*.

**Why verify first and not in parallel with voting?** Two reasons. (1) **Cost:** a `Refuted` proposal must never burn council tokens. (2) **Anchoring:** jurors who have seen a clean `VerificationReport` reason from facts, not vibes — the report *constrains the residue*, raising per-juror `p` (Lever 1 feeding Lever-1-on-the-residue). The verification `digest` is embedded in the `Decision` and re-runnable on replay, so the whole determinism-first claim is auditable.

**The verification suite is itself versioned state under consensus** (committed design, §11.7). The §4.2 boundary between "machine-checkable" and "subjective residue" is *not* fixed: when the Compiler ([`05`](./05-agent-jit.md)) compiles a formerly-subjective judgment into a deterministic check, **promoting that check into the suite is a governed proposal** decided by this same protocol. The self-referential loop — consensus governing the checks that preempt consensus — is explicit and governed.

---

## 5. Lever 2 — Decorrelate the agents

CJT's `n →` benefit is **entirely contingent on independence**. This section manufactures it, and guards the one thing that destroys it.

### 5.1 Council diversity (decorrelate by construction)

The council is composed to **maximize the diversity of failure modes**. The more orthogonal the jurors' errors, the closer the realized correlation is to zero, and the faster CJT drives aggregate error down. Diversity axes:

```rust
struct JurorProfile {
    voter: AgentId,
    harness: HarnessKind,        // Claude Code | Codex | Cursor | Aider | ...  (different tools)
    model_family: ModelFamily,   // different base models -> different hallucination basins
    seed: u64,                   // different sampling seeds
    role_lens: RoleLens,         // the angle this juror is told to judge from (see below)
    system_prompt: PromptId,     // distinct instruction framing
    temperature: f32,
}

/// Deliberately heterogeneous "hats" so jurors weight different aspects.
enum RoleLens {
    Correctness,     // does the diff actually do the right thing?
    Safety,          // does it risk invariants / runaway cost / security?
    Parsimony,       // is it the simplest change that suffices?
    UserIntent,      // does it serve the user's actual goal (advocate's lens)?
    Adversary,       // red-team: how could this be wrong / exploited?
}
```

The intuition: a homogeneous council (same model, same prompt, same seed) is *one juror wearing a costume n times* — its votes are near-perfectly correlated and CJT gives almost nothing. A heterogeneous council approximates *n* independent draws. **Composing a maximally-diverse council is committed design (§11.4):** the protocol maintains a running agreement-beyond-chance correlation matrix and composes councils to *minimize expected inter-juror correlation subject to a per-agent competence floor*, with the correlation prior keyed off a juror descriptor (`{tool, version, model_family, scaffold, prompt_template_hash}`, `model_family` weighted most; descriptor owned by [`04`](./04-runtime-and-harness.md), correlation estimation owned here). The diversity↔competence tradeoff (an exotic model may be more independent but less competent, lowering `p`) is bounded by the competence floor; live recomposition is a *slow control surface* in [`03`](./03-control-loop.md).

> **Measured diversity is an operational precondition, not an assumption (ROB-02).** A quorum is treated as *independent* — and therefore eligible for the CJT-derived tolerance posture (§2.4) — only when its **measured base-model / harness diversity clears a floor**: the participating jurors must span at least a minimum number of distinct `model_family` values (and not be dominated by any single family beyond a cap). If a round's participating set collapses below that diversity floor (e.g. only same-family jurors responded before the deadline), the quorum is **not** counted as independent: the decision is treated as low-assurance and routed per the blast-radius tiers (§9, §10) — held or escalated for high-blast-radius proposals rather than committed on a nominal supermajority that is really *one juror n times*.

> **Decorrelated red-team lane for high-blast-radius proposals (ROB-01).** Every **high-blast-radius / irreversible / constitutional** proposal must include **at least one red-team lane (`RoleLens::Adversary`) drawn from a deliberately *different model population*** than the rest of the council — a juror whose failure modes are engineered to be decorrelated from the majority. Its job is to *stress-test confident agreement from a decorrelated source*: a correlated, confidently-wrong council that all shares a basin will tend to agree, and the cross-population red-team lane is the in-protocol mechanism most likely to break that agreement. A high-blast-radius proposal that cannot be staffed with such a lane does not get the autonomous fast path; it holds or escalates (§9, §10). This couples to the **verification-coverage** signal owned by [`07`](./07-observability.md)/[`03`](./03-control-loop.md): low dispersion at low verification coverage *without* a dissenting red-team lane is a risk signal, not a green light (§2.2, §8.3).

### 5.2 Layer 3: The blind vote (decorrelate by procedure)

Each council member casts its `Vote` **in isolation**: it sees the proposal, the `VerificationReport`, and the world-model head — but **not** any peer's vote, confidence, or rationale. This is the **blind vote**, and it is the procedural heart of Lever 2.

```rust
/// (anchor canonical type)
struct Vote {
    proposal: Hash,
    verdict: Verdict,            // Approve | Reject | Abstain
    confidence: f32,             // self-estimated P(my verdict is correct), in [0,1]
    voter: AgentId,
    signature: Signature,        // signed; scheme in 08
}

/// A blind vote additionally commits to its content before reveal, to prevent
/// last-look / equivocation within the round (full handling in 08).
struct SealedVote {
    voter: AgentId,
    commitment: Hash,            // = H(Vote || nonce); revealed after all sealed votes collected
    round: u32,                  // 0 = blind round
}
```

Procedure for the blind round (`round = 0`):

1. **Fan-out.** The proposal + `VerificationReport` are dispatched to every council member independently and concurrently. No shared scratchpad, no chat.
2. **Seal.** Each member returns a `SealedVote` (commitment to its `Vote`) within the round deadline (§10).
3. **Reveal.** Once quorum of sealed votes is in (or the deadline fires), commitments are opened. A vote whose reveal doesn't match its commitment is discarded and flagged to [`08`](./08-trust-and-security.md) as equivocation.

The commit-then-reveal step matters even in the blind round: it prevents a slow or compromised member from waiting to see others and *tailoring* its vote, which would reintroduce correlation through the back door.

Each member also self-reports `confidence` — its own estimate of `P(my verdict is correct)`. Confidence is **not** taken at face value; in aggregation it is **discounted by the voter's scalar track-record weight** (§6, §8.1), so a member with a poor track record cannot buy posterior by reporting high confidence.

### 5.3 The cardinal sin: premature deliberation

> **Premature discussion is an anti-pattern: it *correlates* errors.** (anchor §6.3)

If jurors talk *before* voting, three well-documented LLM pathologies collapse independence:

- **Herding / information cascade.** The first articulate opinion anchors the rest; later jurors update toward it and stop sampling independently. The council's effective size collapses toward 1.
- **Sycophancy.** LLM agents are trained to be agreeable; exposed to a confident peer, they disproportionately *concur*, inflating apparent consensus while *destroying* the independence that made consensus meaningful.
- **Persuasion-by-fluency.** The most *fluent* argument wins attention regardless of correctness — selecting for rhetoric, not truth.

Each of these **raises inter-juror error correlation**, which — per CJT — *eliminates the `n →` benefit and can push the aggregate below the competence of the individuals.* The protocol therefore **forbids deliberation before the blind vote** and admits it only as a **bounded, structured, identity-blind** fallback on genuine splits (§7), where the cost of *not* sharing information (a true deadlock) finally outweighs the correlation it induces.

> **Mantra:** *Vote first, talk later, and only if you must — and even then, argue with the proposal, not with each other.*

---

## 6. Layer 4 — Track-record weighting (and mechanical off-protocol quarantine)

CJT in its weighted form says: **don't count jurors equally — weight each by its competence.** But Metatron votes with a **small, fixed council (5–7)**, scored against ground truth that **arrives late and often never** (§6.2), where the verification gate (G0) can only score the **machine-checkable subset** of a proposal — never the subjective residue the jurors actually voted on. That data budget cannot support an RL-grade estimator. Reputation here is therefore deliberately **modest**: a **scalar track-record weight in `[0,1]` that decays toward a class prior**, *not* an adaptive-control economy. There is **no** proper-scoring-rule training of a stateless LLM's confidence, **no** beta-Bayesian shrinkage as the mechanism, and **no** eligibility-trace credit assignment — those were over-fitted to a data regime this council does not have.

Two concerns earlier editions fused are kept **strictly separate**:

- **Track-record weighting** (§6.1–§6.4) — a *soft, statistical* nudge that lets a demonstrably-out-of-step voter's influence sag toward a floor. It never evicts, and on its own it never quarantines.
- **Mechanical off-protocol detection** (§6.5) — *hard, deterministic* catches (equivocation, schema violation, signature failure). These are **not** routed through the learned weight; they are detected mechanically and **quarantined via quorum / human escalation**.

> **Why separate them?** The learned weight is a slow, lagged, noisy estimate fit to scarce data; conflating it with off-protocol enforcement would mean a signature forgery or an equivocation waits on a statistical estimator to "notice." Hard misbehavior is mechanically decidable *now*, so it is handled *now* (§6.5), leaving the weight to do only the soft job it can actually support.

### 6.1 What the weight is

```rust
/// (anchor: Reputation(f32) in [0,1])
struct ReputationState {
    agent: AgentId,
    weight: f32,         // scalar track-record weight in [0,1]; 0 = no marginal influence
    samples: u32,        // machine-scorable decisions seen so far (few -> sits at the class prior)
    last_update: LogicalTime,
}
```

The weight is a **single scalar** — there is no separate `skill`/`calibration` pair and no trained confidence model. It is the voter's **observed agreement-with-ground-truth rate on the machine-measurable subset** of past decisions, blended with a population **class prior** and pulled back toward that prior over time (§6.3). A member that has been repeatedly out of step (against the part of ground truth we can actually measure) sags toward the floor until it is, in effect, a non-voter — without any explicit eviction event; a fresh or rarely-tested member sits near the prior, so influence is *earned* against evidence rather than assumed.

> **Claim narrowed to the measurable subset.** `weight` is a defensible estimate of *"how often this juror has matched ground truth **on the machine-checkable part**"* — it is **not** a calibrated `P(juror matches ground truth)` over subjective judgments, because that ground truth is mostly unavailable and lagged (§6.2). The weight is a soft prior on whom to trust on the residue, extrapolated from the measurable part; it is explicitly *not* a measurement of competence on the residue itself.

### 6.2 Ground truth (and its lag)

A vote can only be scored against *something*, and only the machine-measurable part can be scored cheaply and immediately. Metatron uses a **layered, increasingly-authoritative** notion of ground truth, accepting that the better signals **arrive late** (and that the weight in §6.1 is computed only over what these tiers can actually adjudicate):

| Tier | Signal | Latency | Authority |
|------|--------|---------|-----------|
| **G0 — Verification** | The `VerificationReport` verdict on the proposal. A juror who voted `Reject` on a later-`Refuted` proposal was *right*; one who voted `Approve` on it was *wrong*. | immediate | high but narrow (only covers the machine-checkable part) |
| **G1 — Execution outcome** | After commit, the Execution plane reconciles. Did the change actually achieve its diff's intent without trap storms / rollback / invariant breach observed downstream? (via [`04`](./04-runtime-and-harness.md), [`07`](./07-observability.md)) | minutes–hours | medium |
| **G2 — User feedback** | The user's eventual acceptance/rejection/correction via the mailbox ([`06`](./06-interaction-and-mailbox.md)). The ultimate setpoint. | hours–days, sometimes never | highest, sparsest |

The **lag** is fundamental: at vote time we do *not* know G2, and often not G1. Track-record updates are therefore **retroactive** — a `Decision` is recorded with its votes, and as ground-truth tiers arrive they are *joined back* to those votes to nudge the weight. A vote is scored on **whatever tier has arrived**; a **never-arriving G2** does not block scoring — the vote is scored on **G0/G1 only**. Credit is attributed back to the originating proposal along the causal trace-id chain ([`07`](./07-observability.md)) with a **simple decay** over intervening commits — *not* an eligibility-trace mechanism. (Only the empirical decay/discount constants remain open — §12b.)

### 6.3 Update dynamics (scalar, prior-reverting)

Two forces only, both acting on the single scalar:

```rust
fn update_weight(rep: &mut ReputationState, agreed_with_ground_truth: bool) {
    // 1) NUDGE: move `weight` a bounded step toward 1 if the vote matched the (machine-measurable)
    //    ground truth, toward 0 if it did not. Bounded step: no single decision swings the weight
    //    far (anti-whipsaw). With few `samples`, the weight stays near the class prior — a
    //    rarely-tested member is neither trusted nor distrusted.
    //    There is NO proper-scoring-rule term and NO confidence-calibration training here.
}

fn decay(rep: &mut ReputationState, now: LogicalTime) {
    // 2) DECAY toward the class prior over time / inactivity. Stale track record (good OR bad) is
    //    untrustworthy: without fresh evidence the weight regresses to the prior, so neither
    //    permanent coronation nor permanent exile is possible. Chronic non-responders / out-of-step
    //    members, never re-earning, sit at or below the prior and contribute ~0 marginal weight.
}
```

Note what is **absent** versus earlier editions: no asymmetric slashing of "confident + wrong" votes *inside the weight* (off-protocol slashing moved to §6.5, where it is mechanical), no beta-distribution posterior, no eligibility traces. The update is a bounded, prior-reverting move on a scalar — and is a **pure function of recorded inputs**, so the weight history is replayable from the Merkle DAG + ground-truth log (auditability; [`08`](./08-trust-and-security.md)). Track-record *acquisition* for a fresh agent is class-prior-with-decay (locked in [`08`](./08-trust-and-security.md)).

### 6.4 From track record to voting weight

```rust
fn voting_weight(rep: &ReputationState) -> f32 {
    // Monotone in the scalar track-record weight, shrunk toward the class prior by low sample count,
    // floored at 0, and normalized so the council's weights sum to a fixed budget.
    // A member at the prior contributes ~prior influence; a chronic drifter floors at 0.
    // A track record < 0.5 (worse than random on the measurable subset) is floored to 0, never
    // NEGATIVE-weighted, to avoid a compromised member gaining influence by being reliably inverted.
}
```

Thresholds (§9) are computed over **voting-weight-weighted** participation, not head-count. "⅔ of the council" means *⅔ of participating voting weight*.

### 6.5 Mechanical off-protocol detection and quarantine (separate from the weight)

Hard, **off-protocol** misbehavior is **not** left to the learned weight to discover. It is **mechanically detected** and **quarantined**, independently of track record:

| Off-protocol class | Detection (deterministic) | Response |
|--------------------|---------------------------|----------|
| **Equivocation** | reveal ≠ sealed commitment, or two signed conflicting votes (§5.2, §10.3) | discard the vote; quarantine the member from the round; emit a security event to [`08`](./08-trust-and-security.md) |
| **Schema violation** | a `Vote`/`SealedVote` that does not typecheck or violates the round protocol | discard mechanically; does not count toward quorum |
| **Signature failure** | a vote whose signature does not verify against the member's `AgentId` key | discard; non-repudiable; emit to [`08`](./08-trust-and-security.md) |

**Quarantine, not slashing-by-weight.** A quarantined member's votes are *excluded* from the round; whether it is *evicted* (a constitutional council change, §9.2) or its keys revoked is decided by **quorum / human escalation** in [`08`](./08-trust-and-security.md) — *not* by silently driving a learned reputation to zero. This keeps enforcement **deterministic and auditable** and keeps the soft weight doing only soft work. Off-protocol events are surfaced to [`07`](./07-observability.md) and feed the forensic response in [`08`](./08-trust-and-security.md); the consensus layer does not try to "out-vote" a cryptographic adversary (§10.3).

### 6.6 Burn-in / cold-start regime (ROB-03)

Because the weight **shrinks to the class prior with no samples**, at **genesis** and **after every council recomposition** the council runs as a **near-flat-headcount majority among uncalibrated jurors** — exactly when the decisions in flight (forming/reshaping the kernel) are most consequential and least reversible. A burn-in regime compensates for the window the weight cannot:

- **Until calibrated samples exist** (per-member `samples` below a floor, recorded as a `Configuration`-layer flag), the council is in **burn-in** and weights are treated as ~uniform.
- During burn-in, **autonomous commits are restricted to high-verification-coverage proposals** — those where G0 can carry the assurance the track record cannot. The **verification-coverage** fraction (owned by [`07`](./07-observability.md)) gates the autonomous path.
- **Low-coverage and/or high-blast-radius decisions during burn-in are routed to human escalation** (§7.4, §10), never auto-committed on a nominal supermajority of uncalibrated jurors.
- **Recomposition re-enters burn-in.** Every `WidenCouncil` / `Decorrelate` / recompose (§10.4) resets the affected members' `samples` and re-opens this window — so the burn-in gate and the break-glass recovery path (§10.4, ROB-04) are designed together.

---

## 7. Layer 5 — Bounded deliberation (split votes only)

If the reputation-weighted blind vote is **decisive**, the protocol stops: `rounds = 0`, go straight to §8. Deliberation is the *exception*, gated on a *genuine split*, because — per §5.3 — talking is how we *lose* independence. We pay that cost only when the alternative (an unresolved deadlock) is worse.

### 7.1 When is it a split?

```rust
fn is_split(tally: &WeightedTally, cfg: &ConsensusConfig) -> bool {
    // A split is when the posterior sits in the AMBIGUITY BAND around the threshold:
    //   |posterior - threshold| < cfg.split_margin
    // i.e. neither a clear pass nor a clear fail, AND dispersion is high (the weight is
    // genuinely divided, not just narrowly but confidently on one side).
    // A narrow-but-confident, low-dispersion result is DECISIVE, not a split.
}
```

Decisive-pass and decisive-fail both skip deliberation. Only the genuinely ambiguous band triggers it.

### 7.2 The round structure (identity-blind)

A round is a **structured propose→critique→revise→re-vote**, designed to share *information* while minimizing *herding*:

1. **Critique (on the text, not the agents).** Each member emits structured critiques **attached to the proposal text / the `TypedDiff`**, never to another agent's identity or vote. Critiques are *de-identified and shuffled* before redistribution.

   ```rust
   struct Critique {
       round: u32,
       target: DiffAnchor,      // points at a SPAN of the proposal/diff, NOT at an AgentId
       kind: CritiqueKind,      // Concern | Counterexample | Clarification | Suggestion
       body: Text,
       // NOTE: no `author` field is exposed to other jurors. Attribution is recorded
       // privately for reputation/audit but withheld during deliberation.
   }
   ```

   > **Why text-anchored + de-identified?** It severs the social signal that drives sycophancy and herding. A juror can engage the *strongest counterexample* without knowing whether it came from the highest-reputation peer or the lowest — so it updates on *content*, not *authority or popularity*. We share the *information* that blind voting withheld, while still starving the *correlation*.

2. **Revise (Guardian only).** Critiques are routed back to the **authoring Guardian** (proposer ≠ voter, anchor §3), who may emit a revised `Proposal` (a new typed diff). Genesis members do **not** rewrite the proposal — they judge. The revised proposal re-enters verification (§4.2): a revision can become `Refuted` or `Certified` and exit the loop.

3. **Re-vote (blind again).** Members cast a fresh **blind** `SealedVote` on the (possibly revised) proposal, now informed by the de-identified critiques. Same isolation discipline as §5.2 — *each deliberation round ends in another blind vote*, not a show of hands.

### 7.3 Bounding

```rust
struct ConsensusConfig {
    pass_threshold_ordinary: f32,        // default 2/3
    pass_threshold_constitutional: f32,  // default 3/4
    quorum_weight: f32,                  // min participating weight for validity (§10)
    split_margin: f32,                   // ambiguity band half-width (§7.1)
    max_rounds: u32,                     // default 3 (§11.8); HARD cap on deliberation rounds
    round_deadline: Duration,            // per-round wall-clock; non-responders excluded (§10)
    convergence_eps: f32,                // if dispersion stops shrinking by > eps, stop early
}
```

All `ConsensusConfig` fields are **tunable**; their committed defaults (council `n = 5–7` odd, `max_rounds = 3`, plus `split_margin`, `round_deadline`, `quorum_weight`, `convergence_eps`) are tabulated in §11.8, where the small-`n` coarseness of the ⅔/¾ thresholds is noted. Empirical values remain workload-dependent tuning (§12b).

Deliberation halts on the **first** of: (a) a round produces a *decisive* re-vote → commit/reject; (b) `max_rounds` reached; (c) **early stop** — dispersion failed to shrink by `convergence_eps` between rounds (talking is no longer helping; more rounds will only correlate). Cases (b) and (c) with a still-split result trigger **escalation** (§7.4).

### 7.4 Escalation

> A vote that stays split and unresolved after bounded deliberation is **escalated to the user**.

The protocol **does not** break ties by fiat, coin-flip, or chair's-casting-vote. A persistent split is *information*: it means the question is genuinely subjective or under-specified — exactly the case where, per §2.2 corollary 3, aggregation may be worse-than-random and the council should **not** pretend to decide.

The escalation response is **tiered by blast radius** (committed design, §11.6): **high-stakes** proposals escalate to the **user via the mailbox**, while **low-stakes** ones get a **controller-level** response (auto-simplify, Guardian re-decomposition, or widen the council) without burdening the user — see [`03`](./03-control-loop.md). For an escalated high-stakes split, the proposal, its `VerificationReport`, the vote history, the de-identified critiques, and the residual dispersion are packaged and handed to the **user via the mailbox** ([`06`](./06-interaction-and-mailbox.md)). The affected work **holds** for the user's resolution (anchor §5). The user's resolution is high-authority G2 ground truth and feeds the track record (§6.2). (Whether *persistent structural* splits need a still-higher controller response beyond this remains open — §12c.)

> **Bounded escalation, never "indefinitely" (UX-04, CONV-E).** No escalation may block forever. The hold is governed by the system-wide **uniform escalation-timeout** policy: a *bounded* wait for the user, and on expiry a **defined safe fallback** — **hold + degrade safely**, and **never silently proceed on an irreversible action**. For a held high-stakes split this means the proposal stays uncommitted and the affected sub-goal is parked in a safe, observable state; reversible neighbours may continue, irreversible ones do not auto-fire. The same bounded-wait → safe-fallback shape applies to the quorum-failure path (§10.2) and the deadlock path (§10.4), so every human-block path in this spec has a defined terminal behaviour rather than an open-ended stall.

```rust
enum Outcome {
    Committed(Hash),         // signed Commit written to the DAG (01)
    Rejected(RejectReason),  // Refuted | DecisiveReject | InadmissibleProposal
    Escalated(MailboxRef),   // persistent split -> user (06); work blocks
}
```

---

## 8. Layer 6 — Posterior + dispersion output

Acceptance is **not** a raw weight count; it is a **threshold on an aggregated posterior**, and the protocol simultaneously emits the **dispersion** as a first-class signal.

### 8.1 The posterior

We treat each member's `(verdict, confidence)` as **evidence** about the latent proposition *"this proposal is correct,"* and combine the evidence in a **Bayesian-style, reputation-weighted** aggregation:

```rust
struct WeightedTally {
    proposal: Hash,
    posterior: f32,      // P(proposal correct | all votes, reputations, verification)  in [0,1]
    dispersion: f32,     // spread of the weighted vote mass (see 8.2)                   in [0,1]
    participating_weight: f32,
    per_voter: Vec<(AgentId, Verdict, f32 /*confidence*/, f32 /*weight*/)>,
}

fn aggregate(votes: &[Vote], reps: &ReputationMap, vr: &VerificationReport) -> WeightedTally {
    // Start from a PRIOR informed by verification (a Certified-residue proposal starts higher
    // than one that merely scraped through Indeterminate checks).
    // For each vote, fold in evidence whose STRENGTH scales with the voter's voting_weight (§6.4)
    // AND its self-reported confidence, with that confidence DISCOUNTED by the voter's scalar
    // track-record weight (a low-track-record 0.9 moves the posterior less than a high-track-record
    // 0.9). Approve pushes the posterior up, Reject down, Abstain ~ no-op
    // (but counts against participation, §10).
    // The form is COMMITTED (§11.2): a reputation-weighted log-odds (naive-Bayes) pool
    // DISCOUNTED by an estimated correlation factor (from descriptor similarity; 04-OQ6) so
    // correlated votes don't over-sharpen the posterior, behind a swappable `Aggregator` trait.
    // The exact correlation-aware functional form remains open (§12a); properties below are normative.
}
```

Required properties of the aggregator (form-independent):

- **Monotone** in each Approve weight×confidence (more credible approval ⇒ higher posterior) and anti-monotone in Reject.
- **Track-record-discounted:** stated confidence is discounted by the voter's scalar track-record weight (§6), so a low-track-record voter's bluff doesn't buy posterior.
- **Weight-bounded:** a low-weight (drifter) vote can barely move the posterior — the CJT weighting (§6) is *a soft* defense against a single out-of-step member (it does **not** by itself defend against a *correlated* council — see §2.4, §5.1).
- **Verification-anchored:** the prior reflects the `VerificationReport`; the vote only adjudicates the *residue*.
- **Replayable & auditable:** `aggregate` is a pure function of recorded inputs; the `Decision` stores enough to recompute it.

### 8.2 Dispersion

```rust
fn dispersion(tally: &WeightedTally) -> f32 {
    // A measure of how DIVIDED the reputation-weighted vote mass was, independent of WHERE the
    // posterior landed. Low when the council was near-unanimous (in either direction); high when
    // weight was split. COMMITTED (§11.5): reputation-weighted NORMALIZED SHANNON ENTROPY of the
    // weighted vote mass, PLUS a bimodality flag; smooth and control-friendly, co-tuned with 03.
}
```

Dispersion is **orthogonal** to the posterior: you can pass with low dispersion (clean consensus) or, after deliberation, with *higher* dispersion (a contested pass). The two together describe the decision's *quality*, not just its outcome.

### 8.3 The acceptance test and the emitted `Decision`

```rust
/// (anchor canonical type)
struct Decision {
    proposal: Hash,
    posterior: f32,
    dispersion: f32,
    passed: bool,
    rounds: u32,                 // 0 if decided on the blind vote
    verification: VerificationReport,
}

fn decide(tally: &WeightedTally, kind: ProposalKind, cfg: &ConsensusConfig) -> Decision {
    let threshold = match kind {
        ProposalKind::Ordinary       => cfg.pass_threshold_ordinary,       // 2/3
        ProposalKind::Constitutional => cfg.pass_threshold_constitutional, // 3/4
    };
    let passed = tally.posterior >= threshold && tally.participating_weight >= cfg.quorum_weight;
    Decision { proposal: tally.proposal, posterior: tally.posterior,
               dispersion: tally.dispersion, passed, rounds: /*…*/, verification: /*…*/ }
}
```

- **`passed`** requires *both* the posterior clearing the threshold *and* quorum (§10). A high posterior from too little participating weight is **not** a pass.
- **`dispersion`** is emitted as the **`ErrorVector.divergence`** dimension consumed by the steering loop in [`03`](./03-control-loop.md). A chronically high-dispersion council is a *measured* control error — the controller may respond by recomposing the council, slowing the cadence, or escalating policy. *This is the one place the consensus protocol feeds the control loop directly.* **But low dispersion is not, by itself, a health signal (ROB-01):** a correlated, confidently-wrong council also reads low (§2.2). Dispersion must be consumed alongside the **verification-coverage** signal owned by [`07`](./07-observability.md): *low dispersion + low verification coverage + no dissenting red-team lane* (§5.1) is an **escalating risk composite**, not a green light — the controller in [`03`](./03-control-loop.md) must escalate, not relax, on it.
- A `passed` decision is handed to signing (§9.3) and becomes a `Commit`; a non-passed decisive decision is `Rejected`; a non-passed split decision is `Escalated`.

---

## 9. Thresholds, constitutional changes, and signing

The write path is **tiered by blast radius (CONV-C / UX-03)** — *full council consensus is not paid on every diff.* A `Proposal` is routed to exactly one of three tiers by its blast radius, and only the upper two convene the council:

| Tier | What it covers | Path |
|------|----------------|------|
| **Routine** | reversible, low-blast-radius advances: **Worker spawns, progress-layer updates, routine wiring** | **single Guardian + post-hoc audit**, optimistic concurrency on the head (§9.4) — **no council round** |
| **Ordinary** | consequential but non-constitutional changes (a team re-org, a sub-goal decomposition that re-shapes work, anything **irreversible** per the reversibility predicate) | full blind-vote council, **⅔** posterior (§9.1) |
| **Constitutional** | kernel-membership changes (add/remove a Genesis or Guardian) | full blind-vote council, **¾** posterior (§9.2) |

The reversibility predicate and the irreversible-default that route a proposal up out of the Routine tier are owned by [`01`](./01-state-model.md) / the reversibility classifier (`reversible` ≡ no external side effect through the `mcp-auth-proxy` **and** a revertible DAG diff; unknown ⇒ escalate). The remainder of §9 specifies the two council tiers; §9.4 specifies the Routine fast path.

### 9.1 Ordinary threshold — voting-weight-weighted ⅔

Ordinary proposals — **high-blast-radius or irreversible** non-constitutional changes (a team re-org, a sub-goal decomposition that re-shapes committed work, any diff the reversibility predicate flags irreversible) — pass when `posterior ≥ ⅔` over participating voting weight, with quorum met. (Routine reversible advances such as worker spawns and progress updates do **not** take this path; see §9.4.) This is the BFT supermajority posture, ported to weighted-posterior form: an adversary or drift cluster controlling `< ⅓` of *weight* cannot force a commit.

### 9.2 Constitutional threshold — reputation-weighted ¾

**Constitutional / kernel changes — adding or removing a Genesis or a Guardian** — pass only at `posterior ≥ ¾`. Rationale: kernel membership *is* the trust root; changing it changes who can ever decide anything again. The higher bar (a) makes capture harder (an attacker must corrupt ¾ of weight, not ⅔) and (b) reflects the irreversibility. Detection of `ProposalKind` is mechanical: any `TypedDiff` touching the kernel-membership region of the `Configuration` layer is `Constitutional`. As noted in §4.2, constitutional changes are **excluded from the verification fast path** — they always require the signed council vote even if `Certified`.

```rust
enum ProposalKind { Ordinary, Constitutional }

fn classify(diff: &TypedDiff) -> ProposalKind {
    // Constitutional iff the diff adds/removes/re-keys a Genesis or Guardian (kernel roles).
    // Everything else (Workers, Compilers, Sentinels, progress, wiring) is Ordinary.
}
```

### 9.3 Signing & commit

Both **votes** and the resulting **commit** are **cryptographically signed**; the scheme, key custody, rotation, and identity binding (`AgentId = Hash` of a public key) are specified in [`08-trust-and-security.md`](./08-trust-and-security.md) and only *referenced* here. On a `passed` decision:

1. The council members whose votes constitute the passing weight produce signatures over the `Commit` preimage.
2. A `Commit` (anchor canonical type) is assembled with `proposal`, `decision`, `author` (the Guardian), `state_root` (= `VerificationReport.state_after`), `parent` (the prior head), and the **quorum of Genesis `signatures`**.
3. The commit is appended at the **head**; consensus serializes the head, so concurrent proposals against the same base are resolved by rebase/stale-base admission errors (§4.1), keeping forks transient (anchor §8 "Head").

A `Commit` is only valid if it carries a quorum of valid signatures *and* embeds a `Decision` whose `passed == true` and whose recomputation from the recorded inputs reproduces `posterior`/`dispersion` — making the entire chain re-verifiable offline. (This validity rule applies to council-tier commits; Routine-tier commits carry a single Guardian signature and an audit marker instead — §9.4.)

### 9.4 Routine / reversible writes — single-Guardian fast path (CONV-C / UX-03)

The **high-churn common case** — worker spawns, progress-layer updates, routine wiring — is **reversible and low-blast-radius**, and paying a full blind-vote council round on it is the throughput bottleneck UX-03 identifies. Routine writes therefore **bypass full council consensus**:

- **Single-Guardian authority.** A Routine proposal is admitted (§4.1) and run through the **same deterministic verification** (§4.2) — a `Refuted` routine diff is still rejected mechanically — but it is then committed under the **authority of a single Guardian**, with **no blind-vote council round** and no posterior/dispersion aggregation.
- **Optimistic concurrency on the head.** Routine commits use cheap optimistic concurrency against the serialized head: a stale-base routine write is rejected with `StaleBase` (§4.1) and rebased/retried, rather than serialized through a council. This keeps the single-ordered-log property (the system-of-record) while removing the council from the hot path.
- **Post-hoc audit, not pre-hoc vote.** Routine commits are **sampled and audited after the fact** by the council / Sentinels ([`07`](./07-observability.md)): the audit is what catches a misrouted or misbehaving Guardian, and an audit miss can retroactively escalate a routine commit to a council review or a revert (the diff is reversible by construction). The Guardian's routine track record feeds §6 like any other ground-truth signal.
- **Tier is mechanical, not discretionary.** Whether a proposal qualifies as Routine is decided by the **reversibility predicate** (no external side effect through the `mcp-auth-proxy` **and** a revertible DAG diff; **unknown ⇒ not Routine ⇒ escalate**, owned by [`01`](./01-state-model.md)) and a blast-radius bound — *not* by the authoring Guardian's say-so. Anything irreversible, high-blast-radius, or constitutional is routed to the council tiers (§9.1/§9.2). A Guardian cannot self-classify a consequential change as Routine to dodge the council.

```rust
enum WriteTier { Routine, Ordinary, Constitutional }

fn write_tier(p: &Proposal, head: &WorldModel) -> WriteTier {
    // Constitutional iff the diff touches kernel membership (§9.2).
    // Else Routine iff reversible(p, head) AND within the routine blast-radius bound;
    //   reversible(...) is the 01-owned predicate; UNKNOWN reversibility ⇒ NOT Routine.
    // Else Ordinary.
}
```

This is the blast-radius tiering applied to the **actual write path**, not merely described: only Ordinary and Constitutional proposals convene the council; the cheap, reversible majority of writes never do.

**Budget reallocation (`10`).** Changing a `BudgetNode` is a typed diff tiered by blast radius like any other write. **Routine per-agent / per-class top-ups within the existing global pool** take this single-Guardian + post-hoc-audit fast path — reversible, low blast radius. **Raising the global ceiling or changing kernel (Guardian/Genesis) floors** is constitutional-adjacent: it takes the reputation-weighted ¾ threshold (§9.2), because it enlarges the system's total spending authority or touches the funding that keeps governance itself alive.

---

## 10. Liveness, quorum, and equivocation

### 10.1 Quorum vs. threshold (the safety/liveness knobs)

- **Pass threshold** (⅔ / ¾) is a **safety** knob: how much agreement is needed to *change* state.
- **Quorum** (`quorum_weight`) is a **liveness/safety floor**: how much council weight must *participate* for a decision to count at all. Without a quorum requirement, a handful of fast voters could commit while most of the council is offline — manufacturing false consensus.

A decision is **valid** only if `participating_weight ≥ quorum_weight`. Below quorum, the outcome is neither pass nor fail but **stalled** (a liveness event), handled per §10.2.

### 10.2 Slow / unavailable Genesis members

LLM-backed members are slow and sometimes unreachable. The protocol must make progress without waiting forever, *and* without letting absence forge consensus:

- **Per-round deadline (`round_deadline`).** Members who don't return a sealed vote by the deadline are **excluded from that round's tally** (their weight does not participate). They are *not* counted as Reject or Approve — silence is not a vote.
- **Abstention vs. silence.** An explicit `Abstain` participates (counts toward quorum, ~neutral on posterior); silence does not count toward quorum at all. This distinguishes "I considered it and have no strong view" from "I was unavailable."
- **Quorum miss → stall, then bounded escalate → safe fallback.** If, after the deadline, `participating_weight < quorum_weight`, the decision **stalls**. The protocol retries with backoff for a bounded number of attempts; persistent quorum failure is itself **escalated to the user** ([`06`](./06-interaction-and-mailbox.md)) and surfaced as a liveness alarm on the Observability plane ([`07`](./07-observability.md)). A council that cannot muster quorum is a *control failure*, not a silent stall. The escalation is **bounded, never indefinite (UX-04, CONV-E):** the user hold runs under the uniform escalation-timeout, and on expiry the protocol takes the **defined safe fallback** — **hold + degrade safely**, the proposal stays uncommitted, and **no irreversible action proceeds** without a human. A *constitutional* or *self-repair* proposal that cannot raise quorum (the council is too degraded to even participate) routes to the **break-glass recovery path in §10.4**, which does not depend on the broken quorum.

> **Diversity-floor miss is handled here too (ROB-02).** If quorum *is* met by weight but the participating set fails the measured base-model/harness **diversity floor** (§5.1) — e.g. only same-`model_family` jurors responded — the round is **not treated as an independent quorum**. It is handled like a quorum miss for high-blast-radius proposals: hold/escalate rather than commit a nominal supermajority that is really one juror many times.
- **Reputation feedback.** Chronic non-responders decay (§6.3 decay term + inactivity), reducing their `quorum_weight` contribution requirement over time and nudging the council toward recomposition via a (constitutional) proposal.

### 10.3 Equivocation (high level)

**Equivocation** = a member presenting *different* votes to different observers, or revealing a vote that doesn't match its sealed commitment. The blind round's **commit-then-reveal** (§5.2) makes equivocation *detectable*: a reveal/commitment mismatch is mechanically caught and the vote discarded. Because votes are **signed** (§9.3), an equivocating member produces *two signed conflicting votes* — non-repudiable cryptographic proof of misbehavior. Detection here is in-scope; the **forensic response** (eviction via constitutional amendment, key revocation) is the **full threat model in [`08`](./08-trust-and-security.md)**. From the consensus protocol's view, a detected equivocation: (a) discards the vote, (b) triggers **mechanical off-protocol quarantine** of the member (§6.5) — *not* a learned-weight penalty, (c) emits a security event to [`08`](./08-trust-and-security.md)/[`07`](./07-observability.md).

> **Note on the threat boundary.** Equivocation is the one place the *stochastic* failure model (§2) gives way to the *adversarial* one: an honest LLM does not produce two signed conflicting votes — that requires either a bug or a compromised key. The protocol detects it deterministically and hands it to security; it does not try to "out-vote" a cryptographic adversary within the consensus layer.

### 10.4 Council deadlock and break-glass recovery (ROB-04)

The council's own **self-repair actions** — `WidenCouncil`, `Decorrelate`, recompose — are themselves `Configuration`-layer changes, and a recompose that adds/removes a kernel member is **constitutional (¾)**. This creates a circular recovery dependency: *a genuinely split or degraded council cannot pass the very proposals that would fix it.* The "controller steers the council back to health" loop ([`03`](./03-control-loop.md)) would have **no working actuator** in the one situation it exists for. The protocol therefore specifies a recovery path that **does not route through the broken quorum**.

**Deadlock detection (what triggers recovery).** A council is declared **deadlocked** on a self-repair-relevant decision when *either*:

- a self-repair / constitutional proposal **persistently splits** — escalation fires (§7.4) across `max_rounds` and `≥ K` retried attempts without ever clearing threshold; *or*
- the council **cannot raise quorum** (§10.2) for such a proposal across the bounded retry budget; *or*
- a **measured structural split** is observed: chronically high `dispersion` (§8.2) on the kernel-shaping decisions together with a diversity/participation floor miss (§5.1), surfaced as a liveness alarm by [`07`](./07-observability.md).

These are mechanical, observable triggers — not a human's gut call — and crossing any of them arms the recovery path below.

**Recovery path (two specified, ordered escapes).**

1. **Human escalation is a first-class recovery, not a catch-all.** A detected council deadlock is **escalated to the user** ([`06`](./06-interaction-and-mailbox.md)) as an explicit *council-deadlock* escalation type (distinct from an ordinary split escalation), packaging the split history, the failed self-repair proposals, the dispersion/diversity evidence, and a proposed recomposition. This hold is **bounded** by the uniform escalation-timeout (§7.4, CONV-E): a bounded wait → **hold + degrade safely**; no irreversible council change fires silently.
2. **Founder-threshold break-glass recompose.** If the user authorizes (or the deadlock is on the recovery itself), recomposition may proceed via a **break-glass path that bypasses the deadlocked quorum entirely**, ratified by a **threshold of founders** rather than by the broken council:
   - **Authority & threshold.** Break-glass recompose is authorized by a **threshold-of-founders signature** consistent with the founder trust root in [`08`](./08-trust-and-security.md) (the same threshold-of-founders that anchors genesis). It is **not** ratifiable by the council it is repairing.
   - **Scope.** Break-glass may only `WidenCouncil` / `Decorrelate` / recompose kernel membership to restore a quorum-capable, diversity-floor-passing council (§5.1). It cannot be used to push ordinary work.
   - **Audit trail.** A break-glass recompose is recorded as a **distinguished signed `Commit`** on the DAG carrying the founder-threshold signatures, the triggering deadlock evidence, and the prior/after council composition — fully replayable and flagged to [`07`](./07-observability.md) for review. It is the most heavily audited commit type in the system.
   - **Re-enters burn-in.** A break-glass (or any) recompose resets the affected members' `samples` and re-opens the **burn-in window** (§6.6), so autonomy is re-restricted to high-verification-coverage proposals until the new council calibrates.

The break-glass path is the actuator that closes ROB-04: council repair has a route that does not require the broken council to consent to its own repair, while the dual gate (founder threshold + bounded human escalation + heavy audit) keeps it from becoming a governance backdoor.

---

## 11. Resolved decisions

A design review **resolved** most of this spec's earlier open questions. The decisions below are **normative committed design** — the protocol in §4–§10 is built to them, and the body sections carry forward-refs to here. What remains genuinely open (an exact formula, the empirical constants, one liveness pathology) is in §12.

### 11.1 Ground truth is a three-tier, staleness-discounted, trace-chained signal

Votes are scored against a **three-tier** ground-truth signal (§6.2):

- **G0** — the *immediate verification outcome*.
- **G1** — the *downstream consequence within a bounded horizon* (via [`04`](./04-runtime-and-harness.md), [`07`](./07-observability.md)).
- **G2** — *user feedback*; **optional and lagged**, sometimes never arriving (via [`06`](./06-interaction-and-mailbox.md)).

A vote is scored on **whatever tier has arrived**, applying a **staleness discount** as credit ages. A **never-arriving G2** does not block scoring — the vote is scored on **G0/G1 only, at lower weight**. **Credit assignment** back to the originating proposal follows the **causal trace-id chain** ([`07`](./07-observability.md)) with a **simple decay** over the commits that intervene between the proposal and the resolved outcome — *not* an eligibility-trace mechanism (OE-05). All scoring is over the **machine-measurable subset** of ground truth; the resulting scalar is the §6.1 track-record weight, nothing stronger.

### 11.2 Aggregation is a correlation-discounted, reputation-weighted log-odds pool

The posterior (§8.1) is a **reputation-weighted log-odds (naive-Bayes) pool**, **discounted by an estimated correlation factor** so that correlated votes do not over-sharpen the posterior. The correlation factor derives from juror **descriptor similarity** (descriptor owned by [`04`](./04-runtime-and-harness.md), OQ6; see §11.4). The aggregator is **swappable behind an `Aggregator` trait**.

### 11.3 Reputation is a scalar track-record weight decaying to a class prior (OE-05)

Reputation is fixed as a **single scalar track-record weight in `[0,1]`** (§6.1), updated by a **bounded prior-reverting nudge** toward/away from the class prior as machine-measurable ground truth arrives, and a **tunable decay half-life** regressing it toward the class prior without fresh evidence (§6.3). Track-record **acquisition** for a newly-instantiated agent is **class-prior-with-decay** (locked in [`08`](./08-trust-and-security.md)). Explicitly **dropped** as over-fitted to a 5–7-voter / lagged-ground-truth regime: proper-scoring-rule confidence training, beta-Bayesian shrinkage as the mechanism, eligibility-trace credit assignment, and weight-based slashing. **Hard off-protocol behavior is detected mechanically and quarantined via quorum / human escalation (§6.5), not through the learned weight**, and the weight's claim is narrowed to the **machine-measurable subset** of ground truth (§6.1).

### 11.4 Diversity is correlation-matrix-minimizing, competence-floored, slow control

The protocol maintains a running **agreement-beyond-chance correlation matrix** over jurors and composes councils to **minimize expected inter-juror correlation subject to a per-agent competence floor** (§5.1). Composition is a **slow control surface** owned by [`03`](./03-control-loop.md), not a per-decision choice. The **correlation prior** keys off the descriptor `{tool, version, model_family, scaffold, prompt_template_hash}`, with **`model_family` weighted most**. The descriptor is **owned by [`04`](./04-runtime-and-harness.md)** (OQ6); correlation **estimation is owned here**.

### 11.5 Dispersion is reputation-weighted normalized Shannon entropy + a bimodality flag

`dispersion` (§8.2) is **reputation-weighted normalized Shannon entropy** of the weighted vote mass, plus a **bimodality flag**. It is chosen to be smooth and control-friendly and is **co-tuned with [`03`](./03-control-loop.md)** to avoid saturation.

### 11.6 Deadlock response is tiered by blast radius

After `max_rounds` with a persistent split (§7.4): **high-stakes** proposals **escalate to the user** via the mailbox ([`06`](./06-interaction-and-mailbox.md)); **low-stakes** proposals get a **controller-level** response — auto-simplify, Guardian re-decomposition, or widen the council ([`03`](./03-control-loop.md)). Liveness is **tiered-by-blast-radius** (locked).

### 11.7 The verification suite is itself versioned state under consensus

The **verification suite (§4.2) is versioned state under consensus.** When the Compiler ([`05`](./05-agent-jit.md)) compiles a formerly-subjective judgment into a deterministic check, **promoting** that check into the suite is a **governed proposal** decided by this same protocol. The self-referential loop — consensus governing the checks that preempt consensus — is **explicit and governed**.

### 11.8 Constants ship as a tunable defaults table

The protocol ships the following **defaults table**; every entry is **tunable** (§7.3):

| Constant | Default |
|----------|---------|
| council size `n` | **5–7, odd** |
| `max_rounds` | **3** |
| `split_margin` | tunable |
| `round_deadline` | tunable |
| `quorum_weight` | tunable |
| `convergence_eps` | tunable |

The **small-`n` coarseness** is noted: at `n = 5–7`, the ⅔/¾ thresholds are coarse-grained. Empirical values remain workload-dependent tuning (§12b).

### 11.9 The write path is tiered by blast radius (UX-03)

Full council consensus is **reserved for high-blast-radius / irreversible / constitutional** proposals (§9.1, §9.2). **Routine, reversible advances** — worker spawns, progress-layer updates, routine wiring — proceed under **single-Guardian authority with post-hoc audit** and **optimistic concurrency on the head**, with **no blind-vote council round** (§9.4). Tier assignment is **mechanical**, driven by the reversibility predicate (owned by [`01`](./01-state-model.md); unknown ⇒ not Routine ⇒ escalate) and a blast-radius bound — not by the authoring Guardian's discretion.

### 11.10 Burn-in / cold-start gates autonomy on verification coverage (ROB-03)

At **genesis and after every council recomposition**, track-record weights shrink to the class prior, so the council is effectively a flat-headcount majority of uncalibrated jurors. During this **burn-in window**, **autonomous commits are restricted to high-verification-coverage proposals**, and **low-coverage / high-blast-radius decisions route to human escalation** (§6.6). Every recomposition (including break-glass, §10.4) re-enters burn-in.

### 11.11 Independence is measured, and council deadlock has a break-glass recovery (ROB-02, ROB-04)

A quorum is treated as **independent** only when its **measured base-model / harness diversity clears a floor** (§5.1, §10.2); a diversity-floor miss is handled like a quorum miss for high-blast-radius proposals. High-blast-radius proposals additionally require a **decorrelated red-team lane from a different model population** (§5.1, ROB-01). Council **self-repair** has a recovery path that does **not** route through the broken quorum (§10.4): **human escalation as a first-class recovery** plus a **founder-threshold break-glass recompose** with specified authority, threshold, trigger, and audit trail. The headline fault-tolerance posture is **mitigated, not guaranteed — correlated failure is the headline residual risk** (§2.4).

---

## 12. Open questions & ambiguities

Parked, not solved. After the §11 review, these are the *only* genuine research gaps that remain.

| # | Question | Why it's hard / parked |
|---|----------|------------------------|
| **(a) — Correlation-aware vote aggregation** | Given the committed correlation-discounted log-odds pool (§11.2), what is the *precise* functional form of the correlation discount in `aggregate` (§8.1)? *(This is the project README's "correlation-aware vote aggregation" open question, now tracked here per ROB-02 rather than only in the README.)* | Naive-Bayes is only *approximate*: Lever 2 reduces but never zeroes inter-juror correlation, so independence is imperfect and a naive pool still over-sharpens. The right discount depends on the §11.4 correlation estimates and is a research problem. **Correlated failure is the headline residual risk** (§2.4): at `n = 5–7` the council is far from CJT's asymptotic regime, and a *novel* correlated failure has no track record to down-weight against (§6) — the measured diversity floor (§5.1) and the cross-population red-team lane (ROB-01) mitigate but do not close this. |
| **(b) — Empirical reputation/consensus constants** | The concrete numeric values behind §11.3 and §11.8: the track-record class prior, the bounded nudge step size, the decay half-life, the burn-in `samples` floor and diversity floor (§5.1, §6.6), `split_margin`, `round_deadline`, `quorum_weight`, `convergence_eps`, council size. | All are "defaults, tunable"; their right values are **empirical and workload-dependent**, and some interact (small *n* makes ⅔ coarse-grained; too-large a nudge step whipsaws the weight, too-small lets drifters persist). |
| **(c) — Persistent structural splits beyond escalation** | The deadlock *response* is settled (tiered-by-blast-radius, §11.6), but if a class of proposals *reliably* escalates — the council is **structurally** split and the user keeps punting — does this need a **higher-level [`03`](./03-control-loop.md) controller response** beyond escalation? | Escalation is the safe default but is not a *resolution*; persistent structural escalation is a **liveness pathology** that likely needs a steering-loop-level response, not a consensus-level one — a research question co-owned with [`03`](./03-control-loop.md). |

---

## 13. Relationships to other specs

| Spec | Relationship |
|------|-------------|
| [`00-overview.md`](./00-overview.md) | **Anchor.** Source of all canonical types (`Proposal`, `Vote`, `Decision`, `Commit`, `WorldModel`, `ErrorVector`, `Reputation`, `AgentId`, `Signature`), the five planes, the agent taxonomy (proposer ≠ voter), the seven design principles, and the ⅔/¾ thresholds. This spec elaborates principles §6.1–6.4 into the layered protocol. |
| [`01-state-model.md`](./01-state-model.md) | **Reads & writes.** Consumes the `WorldModel` head and the `TypedDiff`/`Layer` schemas; the only writer of `Commit`s to the Merkle DAG. Verification (§4.2) checks invariants defined there; the constitutional classifier (§9.2) keys off the kernel-membership region of the `Configuration` layer. (Spec not yet authored; this doc relies on the anchor's `Commit`/`WorldModel` shapes meanwhile.) |
| [`03-control-loop.md`](./03-control-loop.md) | **Downstream consumer + upstream source.** Emits `Decision.dispersion` as `ErrorVector.divergence` (§8.3) — consumed *together with* verification coverage, since low dispersion alone is not health (ROB-01). Receives control-action-derived proposals (`Proposal.derived_from`). Owns council recomposition as a slow control surface (§11.4) and the low-stakes deadlock response (§11.6); co-designs the dispersion measure (§11.5); council-deadlock break-glass is co-owned (§10.4); the persistent-structural-split pathology is the open item §12c. |
| [`04-runtime-and-harness.md`](./04-runtime-and-harness.md) | **Ground-truth source (G1) + descriptor owner.** After a `Commit`, the `ExecutionBackend` reconciles toward the new desired state; execution outcomes feed reputation (§6.2 G1). Owns the juror descriptor `{tool, version, model_family, scaffold, prompt_template_hash}` (OQ6) that this spec's correlation estimation (§11.4) keys off. |
| [`05-agent-jit.md`](./05-agent-jit.md) | **Boundary co-evolution.** Compilers may promote formerly-subjective judgments into deterministic verification checks; such promotion is itself a governed proposal under this protocol (§11.7), moving the §4.2 line over time. |
| [`06-interaction-and-mailbox.md`](./06-interaction-and-mailbox.md) | **Author + escalation sink + ground-truth source (G2).** Guardians author proposals (§4.1); persistent splits and quorum failures escalate to the user via the mailbox (§7.4, §10.2); user feedback is the highest-authority ground truth (§6.2 G2). |
| [`07-observability.md`](./07-observability.md) | **Telemetry + verification-coverage owner.** Vote latencies, dispersion, posterior, track-record trajectories, quorum stalls, and equivocation events are emitted to the Observability plane. Owns the **verification-coverage** signal that gates burn-in autonomy (§6.6) and that must be read alongside dispersion (§8.3, ROB-01); audits Routine-tier commits (§9.4); Sentinels feed mechanical off-protocol events (§6.5). |
| [`08-trust-and-security.md`](./08-trust-and-security.md) | **Identity & threat model.** Owns the signing scheme, `AgentId`/key custody, equivocation forensics & eviction (§10.3), the **threshold-of-founders trust root** the break-glass recompose relies on (§10.4), and the adversarial-minority threat model that §2.4 defers to. This spec *references* it; it does not duplicate it. |
