# Metatron — The Agent-JIT (Execution Plane)

> **Status:** Research architecture specification (v0.1)
> **Plane:** Execution
> **Owning roles:** **Compiler** (does the JIT), **Sentinel** (monitors the JIT)
> **Depends on:** `00-overview.md` (canonical types, taxonomy, principles), `04-runtime-and-harness.md` (`AgentHarness`, `ExecutionBackend`, `TaskSpec`, `Context`, `HarnessResult`)
> **Referenced by:** `03-control-loop.md` (cost dimension drives compilation), `01-state-model.md` (tier is configuration-layer state), `07-observability.md` (trap/drift telemetry), `08-trust-and-security.md` (signing of synthesized policy)

This document specifies the **agent-JIT**: the mechanism by which Metatron **compiles a stabilized LLM agent from a live harness loop into faster, cheaper, deterministic execution**, guarded by **traps** that **deoptimize** back to the LLM the moment an assumption breaks. It is the concrete realization of Principle 7 — *"Compile the hot path, trap on surprise"* (`00-overview.md` §6) — and of the JIT commitment in the vision (`00-overview.md` §1).

The thesis is a one-to-one structural analogy: **a managed-language JIT compiler and Metatron are the same machine pointed at different substrates.** A JIT profiles an interpreter executing bytecode, finds hot stable paths, compiles them to native code behind guards, and deoptimizes on guard failure. Metatron profiles a **harness executing an LLM policy**, finds hot stable input→action paths, compiles them to a memoized or synthesized policy behind guards, and deoptimizes on guard failure. This spec makes that analogy *precise* rather than merely evocative — every JIT concept names a concrete Metatron mechanism, and the analogy is load-bearing for the design, not decoration.

---

## 1. Purpose

### 1.1 What problem this solves

A Tier-0 agent is a `Worker` whose every decision is a fresh `AgentHarness::run` invocation — an LLM session. Sessions are the single most expensive and slowest primitive in Metatron, and the **most nondeterministic**. Yet empirically, much agent work is *repetitive and stabilized*: a triage worker that has classified ten thousand near-identical tickets, a router that has dispatched the same shapes of request to the same downstream workers, a formatter that applies the same transform. Re-invoking a stochastic, costly, latency-heavy LLM to re-derive a decision the agent has already made the same way a thousand times is **pure waste** — the agentic equivalent of interpreting a hot loop bytecode-by-bytecode forever.

The agent-JIT exists to **collapse that waste to determinism wherever it is safe to do so**, and *only* where it is safe. It is the operational arm of Principle 2 (*Determinism-first*, `00-overview.md` §6): "collapse to determinism wherever you can" is not just a consensus rule, it is an execution-plane optimization with a compiler.

### 1.2 Goals

- **G1 — Cost & latency reduction on the hot path.** Replace repeated harness sessions with cached or synthesized decisions whose marginal cost is ~0 tokens and whose latency is sub-millisecond, where behavior has demonstrably stabilized.
- **G2 — Determinism on stabilized behavior.** A compiled decision is reproducible and auditable; it removes one source of probabilistic-Byzantine nondeterminism from the substrate.
- **G3 — Provable safety.** A compiled agent **must never silently diverge** from the Tier-0 behavior it claims to approximate. Divergence must be either *prevented* (guards trap conservatively) or *detected and corrected* (shadow execution + demotion), never *unobserved*.
- **G4 — Reversibility.** Every optimization is undoable. Deoptimization is a first-class, cheap operation, not an error path.
- **G5 — Separation of powers.** *Doing* the JIT (Compiler) and *policing* the JIT (Sentinel) are distinct roles with distinct authority, mirroring the proposer≠voter separation of the agent taxonomy (`00-overview.md` §3).
- **G6 — Auditability.** A tier change is a typed state update committed to the Merkle history, signed, replayable, and attributable.

### 1.3 Non-goals

- **Not** a general program synthesizer for arbitrary tasks. The JIT only compiles behavior an agent has *already exhibited stably*; it never invents capability.
- **Not** a replacement for the harness. Tier 0 is always present as the deopt floor. An agent that never stabilizes simply runs forever at Tier 0 — that is a correct outcome, not a failure.
- **Not** a correctness oracle for the underlying task. The JIT preserves *equivalence to Tier-0 behavior*, whatever that behavior is. If the Tier-0 agent is wrong, the compiled agent is faithfully, deterministically wrong — and that is the Sentinel/reputation system's problem (`08`), not the JIT's. The JIT's contract is **behavioral equivalence**, not **task correctness**.

---

## 2. Concepts

### 2.1 The master analogy

| Real JIT (e.g. V8 / HotSpot / PyPy) | Metatron agent-JIT | Notes |
|---|---|---|
| Interpreter executing bytecode | **`AgentHarness::run`** — a live LLM session executing the agent's policy | The slow, fully-general, always-correct baseline. Tier 0. |
| Bytecode / source being interpreted | The agent's **role + goal + system prompt + tools** (its policy spec) | What is being "executed" each invocation. |
| A call site / hot loop | A **decision site**: a recurring `(role, goal, input-shape)` at which the agent repeatedly invokes the harness | The unit of compilation. |
| Profiling / hotness counters | **Invocation-frequency + cost accounting** per decision site (G1, fed by `07`) | Hotness = how much this site costs the controller. |
| Type feedback / observed types | Observed **input→action** samples: `(canonicalized input, harness action, confidence)` traces | The empirical behavior record. |
| Inline cache (monomorphic) | **Tier-1 memoized policy**: cache keyed by canonicalized input → action | "We've seen this exact shape; reuse the answer." |
| Polymorphic inline cache (PIC) | Tier-1 cache with **k>1 input clusters**, each with its own cached action + guard | Few stable behaviors over an input partition. |
| Megamorphic call site → give up, stay in interpreter | Decision site that **never clusters** (high entropy) → stays Tier 0 permanently | Inherently context-dependent agents (see Open Q). |
| Baseline JIT (quick, cheap compile) | **Tier 1** (memoize observed behavior; no synthesis) | Cheap to build, broad coverage, conservative. |
| Optimizing JIT (slow, aggressive compile) | **Tier 2** (synthesize deterministic code where behavior is provably/empirically regular) | Expensive to build, narrow, maximal payoff. |
| Guard (type check before fast path) | **Trap / deopt guard**: a predicate that must hold for the compiled path to be valid | If it fails, fall to a lower tier. |
| Deoptimization (bail to interpreter) | **Deopt**: fall back from Tier 2→1, 2→0, or 1→0 and re-run the harness | First-class, cheap, logged. |
| On-stack replacement (OSR) | **Mid-task tier swap**: switch tiers between decision steps within one running task | Tier is per-decision, not pinned for a task's lifetime. |
| Uncommon trap / never-taken branch | **Novelty / OOD trap**: input outside the observed distribution conservatively deopts | Sound-by-default (G3). |
| The JIT compiler thread | The **Compiler** agent class | Runs off the hot path, asynchronously. |
| Tiered-compilation policy / recompilation heuristics | The **Sentinel** agent class + the (re)compilation policy (§5) | Decides promote/demote. |
| Code cache | **Compiled-policy store**, content-addressed, tier recorded in configuration layer (`01`) | Part of system state. |
| Deopt metadata / guard map | **Guard set + provenance** attached to each compiled policy | Enables sound, attributable bailout. |

> **The compiler's-eye-view summary:** *Compiling an agent = compiling away repeated, stabilized harness invocations.* Everything below is bookkeeping in service of that one sentence.

### 2.2 The three tiers

The tier enum is canonical (`00-overview.md` §7):

```rust
enum Tier {
    Tier0Interpreter,   // pure LLM harness          — the interpreter
    Tier1Memoized,      // learned input->action map  — the inline cache
    Tier2Compiled,      // synthesized deterministic  — the optimizing JIT
}
```

| Tier | Mechanism | Marginal cost | Latency | Determinism | When valid |
|---|---|---|---|---|---|
| **Tier 0 — Interpreter** | `AgentHarness::run` — a full LLM session | High (tokens, $$) | Seconds | Stochastic | Always. The universal fallback. |
| **Tier 1 — Memoized** | (Possibly polymorphic) inline cache: canonical input → cached action, learned from observed *stable* behavior | ~0 tokens; cache lookup + guard eval | Sub-ms on hit; deopts to Tier 0 on miss | Deterministic per cache entry | Input has been seen and behavior was stable across observations |
| **Tier 2 — Compiled** | Synthesized deterministic artifact (decision tree / rule set / typed transform / small program) executing the regularity directly | ~0 tokens; native execution | Microseconds | Deterministic by construction | Behavior is *provably or empirically regular* over an input region, validated by equivalence checking |

The tiers form a **total fallback order**: `Tier2 ⊐ Tier1 ⊐ Tier0`. A deopt always moves *down* this order; a promotion always moves *up*. Tier 0 is the floor and can never deopt (there is nothing below the interpreter).

> **Tier 1 vs Tier 2, sharpened.** Tier 1 *remembers* what the agent did (lookup over a finite observed table; novel input = guaranteed miss = deopt). Tier 2 *generalizes* what the agent does (a synthesized function with a domain; novel-but-in-domain input can be answered without ever having been seen, which is exactly why Tier 2 needs stronger correctness machinery — §6). This is the inline-cache vs optimizing-compiler distinction.

### 2.3 Decision sites and canonicalization

The unit of compilation is the **decision site**, not the agent. An agent may be Tier 2 at one decision site (the formatting step it does identically every time) and Tier 0 at another (the genuinely novel judgment) within the same task. This mirrors how a JIT compiles individual hot methods/loops, not whole programs.

A decision site is identified by a **canonicalization function** that maps a raw `(TaskSpec, Context)` to a stable key by stripping irrelevant variation (timestamps, ids, ordering, whitespace) and bucketing semantically-equivalent inputs. Canonicalization is the analogue of a JIT's *type feedback shape*: it defines what "the same situation" means, and therefore what the cache key and the guard domain are. **Canonicalization soundness is a load-bearing assumption** — a canonicalizer that collapses two inputs the agent would treat differently introduces silent divergence. (Parked in Open Questions: how canonicalizers themselves are validated.)

```rust
/// Reduces raw harness inputs to a stable decision-site key + a feature vector
/// used for clustering, guards, and OOD detection.
trait Canonicalizer {
    fn site(&self, task: &TaskSpec, ctx: &Context) -> DecisionSiteId;
    fn key(&self, task: &TaskSpec, ctx: &Context) -> CanonKey;     // exact-match cache key
    fn features(&self, task: &TaskSpec, ctx: &Context) -> Features; // for clustering / OOD
}

type DecisionSiteId = Hash;   // (role, goal-region, input-shape) identity
type CanonKey = Hash;         // content address of the canonicalized input
type Features = Vec<f32>;     // embedding / structured features for distribution modeling
```

### 2.4 Traps (deoptimization guards)

A **trap** is a guard predicate evaluated *before* (and sometimes during) a compiled fast path. If the predicate does not hold, the trap **fires**, the engine **deoptimizes** to the next lower tier, and the event is logged for the Sentinel. Traps are how a compiled agent stays honest: the compiled path is only ever taken when its preconditions provably hold.

The cardinal rule (G3, soundness) — **conservative trapping**:

> A guard MUST fire ("trap when unsure") whenever it cannot *positively establish* that the compiled path is valid for the current input. Absence of evidence of validity is treated as evidence of invalidity. False traps (unnecessary deopts) cost performance; missed traps (silent divergence) cost correctness — and the JIT is tuned to **never** trade correctness for performance.

Guard taxonomy:

| Guard type | Fires when | Analogy | Deopts to |
|---|---|---|---|
| **`ConfidenceGuard`** | The compiled path's (or originating observation's) confidence < threshold | Speculative-type check on a weakly-typed feedback | Tier 0 |
| **`NoveltyGuard` (OOD)** | Input falls outside the observed distribution / cluster domain (`features` exceed a learned boundary) | Uncommon trap / never-taken branch | Tier 0 |
| **`InvariantGuard`** | A declared pre/postcondition or type invariant on input or output is violated | Assertion / safepoint check | Tier 1 or 0 |
| **`PreconditionGuard`** | A Tier-2 synthesized rule's explicit precondition does not hold for this input | Guard before an inlined fast path | Tier 1 |
| **`StalenessGuard`** | The world-model context the policy was compiled against has changed materially (e.g. tool set, downstream worker wiring, goal revision) | Code-cache invalidation on class redefinition | Tier 0 + recompile request |
| **`DivergenceGuard`** | Shadow/canary execution (§6) detected Tier-2 ≠ Tier-0 on a recent sample beyond tolerance | Self-modifying-code consistency check | Tier 0 + demote |

Guards compose: a compiled policy carries a **guard set**, and the fast path is taken iff *all* guards pass (logical AND — any single failure traps). This is exactly a JIT's guard sequence at the top of an optimized stub.

### 2.5 The two roles, sharply separated

Per `00-overview.md` §3, **doing** and **watching** are different powers held by different agent classes. The JIT preserves this:

- **Compiler** (`Optimize`): the JIT compiler thread. *Observes* stable behavior at a decision site, *synthesizes* a Tier-1 or Tier-2 policy, *installs* guards, and *proposes* the promotion. Runs **off the hot path**, asynchronously, exactly like a background compiler thread. The Compiler **builds** but does not unilaterally **decide** (see §5.4 authority).
- **Sentinel** (`Watch`): the recompilation-policy brain + the safety monitor. *Monitors* trap rates, deopt rates, drift, and shadow-equivalence; *decides* when behavior is hot+stable enough to *request* compilation and when a tier has gone stale and must be *demoted*. Sentinels also feed the PID `divergence` signal and reputation (`08`).

> The Compiler is the *muscle*; the Sentinel is the *governor*. A Compiler that could also decide when to compile and never be second-guessed would be a JIT with no deopt policy — the failure mode this separation prevents. Conversely a Sentinel never synthesizes code; it only watches and signals.

---

## 3. Detailed design

### 3.1 Lifecycle of a compiled decision site

```
        ┌──────────────────────── Tier 0 (interpreter) ───────────────────────┐
        │  every decision = AgentHarness::run ; Sentinel profiles hotness+cost │
        └───────────────┬──────────────────────────────────────────────────────┘
                        │ hot (high freq · cost pressure) AND behavior stable
                        ▼  (Sentinel emits CompileRequest)
        ┌──────────────────────── Compiler (async, off hot path) ──────────────┐
        │  1. gather observation window of (canon input → action, confidence)  │
        │  2. cluster inputs (monomorphic? polymorphic? megamorphic→abort)     │
        │  3. synthesize Tier-1 cache  (and/or attempt Tier-2 synthesis)       │
        │  4. install guard set (confidence, novelty/OOD, invariant, precond)  │
        │  5. equivalence/regression check vs Tier 0 on held-out replay        │
        └───────────────┬──────────────────────────────────────────────────────┘
                        │ proposes TierChange (authority per §5.4)
                        ▼
        ┌──────────────────────── Shadow / canary phase ──────────────────────┐
        │  serve Tier 0 (authoritative) ; run Tier-1/2 in shadow on a sample ; │
        │  measure equivalence rate ; promote only if within tolerance        │
        └───────────────┬──────────────────────────────────────────────────────┘
                        │ commit TierChange to Merkle history (config layer, 01)
                        ▼
        ┌──────────── Tier 1 / Tier 2 active ; guards live ; Sentinel watches ─┐
        │  hit  → cheap deterministic answer (~0 tokens, µs/ms)                 │
        │  trap → DEOPT down one tier, log DeoptEvent, re-derive               │
        │  rising trap/drift → Sentinel emits DemoteRequest                    │
        └──────────────────────────────────────────────────────────────────────┘
```

### 3.2 Tier-0 execution + profiling (the interpreter)

Tier 0 is unchanged `AgentHarness::run` (`04`). The only addition is **profiling instrumentation** in the execution-plane dispatcher: for every decision it records, via the observability plane (`07`):

- the `DecisionSiteId` (from the `Canonicalizer`),
- the `CanonKey` and `Features`,
- the resulting action and the harness's self-reported `confidence`,
- the measured cost (tokens, $, wall-clock).

These are the **hotness counters + type feedback** of the analogy. They accumulate into a per-site **ObservationRecord** that the Sentinel reads to decide hotness and stability, and that the Compiler reads to synthesize.

```rust
struct ObservationRecord {
    site: DecisionSiteId,
    samples: Vec<Observation>,        // rolling window
    invocation_rate: f32,             // hotness (per unit logical time)
    cost_per_invocation: CostStats,   // feeds G1 / PID cost link (§5.2)
    stability: StabilityStats,        // see §3.3
}

struct Observation {
    key: CanonKey,
    features: Features,
    action: ActionDigest,             // content address of the harness action/output
    confidence: f32,                  // self-reported, in [0,1]
    cost: Cost,
    at: LogicalTime,
}
```

### 3.3 Stability detection (when is a site compilable?)

"Stable" = *the same canonical input has reliably produced the same action.* Concretely, per cluster:

- **Consistency** `= P(same action | same CanonKey)` over the window — high consistency ⇒ memoizable (Tier 1 candidate).
- **Confidence** — mean self-reported confidence is high and well-calibrated against ground truth (calibration borrowed from the reputation machinery, `08`).
- **Coverage** — the observed input distribution covers the cluster's domain densely enough that an OOD boundary can be drawn (so the `NoveltyGuard` is meaningful).
- **Entropy / arity** — the number of distinct stable behaviors at the site. Monomorphic (1) → simple inline cache. Polymorphic (small k) → PIC. Megamorphic (no convergence, high entropy) → **abort compilation, remain Tier 0** (the analogue of a JIT giving up on a megamorphic call site).

```rust
struct StabilityStats {
    consistency: f32,        // in [0,1]; P(same action | same key)
    mean_confidence: f32,    // calibrated
    coverage: f32,           // distribution coverage of the cluster domain
    arity: u32,              // distinct stable behaviors (mono=1, poly=small, mega=large)
    drift: f32,              // recent change in the input→action mapping (§5.3)
}
```

A site is a **Tier-1 candidate** when `consistency ≥ τ_c1`, `mean_confidence ≥ τ_conf`, and `arity ≤ k_max`. It is additionally a **Tier-2 candidate** when the stable behavior is *regular enough to synthesize and equivalence-check* — i.e. the input→action map admits a compact, total-over-its-guarded-domain functional form that survives held-out replay (§6.3). These thresholds are tunable and are themselves a control surface (Open Q: who owns them).

### 3.4 Tier-1 synthesis (the inline cache / PIC)

The Compiler builds a guarded cache from the observation window:

```rust
struct Tier1Policy {
    site: DecisionSiteId,
    clusters: Vec<InlineCacheEntry>,   // 1 = monomorphic, >1 = polymorphic (PIC)
    guards: GuardSet,                  // novelty/OOD + confidence + staleness, at minimum
    provenance: Provenance,            // observation window, Compiler id, source commits
}

struct InlineCacheEntry {
    domain: ClusterBoundary,           // OOD boundary in feature space
    key_index: Map<CanonKey, ActionDigest>, // exact-match memo table
    cached_action: ActionDigest,       // representative action for the cluster
    support: u32,                      // #observations backing this entry
    local_confidence: f32,
}
```

Execution at Tier 1: canonicalize → if `key` is in `key_index` **and** all guards pass → return the cached action (a **hit**, ~0 tokens). Otherwise **trap** (a **miss**: novel key, OOD features, low confidence, or stale context) → **deopt to Tier 0**, run the harness, and feed the fresh observation back so the cache can grow. This is precisely inline-cache fill-on-miss.

A PIC (k>1) just dispatches over clusters: pick the cluster whose `domain` contains `features`; if none contains it → `NoveltyGuard` fires → deopt. Megamorphic sites are never built (§3.3).

### 3.5 Tier-2 synthesis (the optimizing compiler)

Where the stable behavior is *regular* — not merely repetitive — the Compiler attempts to synthesize a deterministic artifact that *generalizes* the behavior over a guarded domain, rather than merely tabulating it:

```rust
enum CompiledArtifact {
    DecisionTree(/* feature splits → action */),
    RuleSet(/* guarded if-then rules with explicit preconditions */),
    TypedTransform(/* schema-to-schema structured mapping */),
    Program(/* small sandboxed deterministic program; executed in the harness sandbox, 08 */),
}

struct Tier2Policy {
    site: DecisionSiteId,
    artifact: CompiledArtifact,
    domain: DomainSpec,                // total over this guarded region; OOD outside
    guards: GuardSet,                  // precondition + invariant + novelty + divergence
    equivalence: EquivalenceCertificate, // §6.3 — required before promotion
    provenance: Provenance,
}
```

Synthesis strategies (Compiler-internal; pluggable) range from program-by-example / decision-tree induction over the observation window, to LLM-assisted code generation *whose output is then equivalence-checked against Tier-0 behavior before it is ever trusted*. **The synthesis method is untrusted; the equivalence check is the trust boundary.** A Tier-2 artifact that cannot produce an `EquivalenceCertificate` (§6.3) is rejected and the site stays Tier 1. This is the optimizing JIT's discipline: speculate aggressively, but guard every speculation.

Tier-2 artifacts execute inside the same sandbox the harness uses (`08`), so a synthesized program has no more authority than the agent it replaces.

### 3.6 The deopt mechanism (precise)

Deoptimization is the single most safety-critical operation. It is defined to be **cheap, total, and lossless**:

1. **Detect.** During (or before) a compiled decision, a guard fires, or a runtime fault/timeout occurs in a Tier-2 artifact.
2. **Bail.** Discard the compiled partial result. Reconstruct the *original* `(TaskSpec, Context)` for the decision site (the engine always retains enough to reconstruct it — the analogue of a JIT's deopt metadata / frame reconstruction).
3. **Re-enter the lower tier.** Invoke the next tier down in the fallback order (`Tier2→Tier1→Tier0`, skipping a tier if that tier also lacks a valid entry) and obtain the authoritative answer.
4. **Log.** Emit a `DeoptEvent` to observability (`07`) for the Sentinel: which guard, which input, which tiers.
5. **Feed back.** The freshly observed Tier-0 (or Tier-1) behavior re-enters the `ObservationRecord`, both to *fill* caches and to *update* drift/stability — the deopt is also a profiling sample.

```rust
struct DeoptEvent {
    site: DecisionSiteId,
    from_tier: Tier,
    to_tier: Tier,
    guard: GuardKind,         // which trap fired
    input: CanonKey,
    at: LogicalTime,
}
```

Because deopt always lands on a tier that is *at least as general and correct* as the one it left (ultimately Tier 0, which is always correct-by-definition since it *is* the agent), **a deopt can never make the answer worse** — it can only cost more. This is the formal sense in which the JIT is *safe by construction*: the worst case of every optimization is "we paid Tier-0 cost anyway," never "we returned a wrong answer."

### 3.7 On-stack replacement (mid-task tier swap)

Tier is resolved **per decision**, not pinned per task. Within one running task, consecutive decisions at the same or different sites may execute at different tiers, and a long-running task can be promoted/demoted mid-flight as the Sentinel commits tier changes. There is no "recompile the whole task and restart" — the next decision simply dispatches against the current tier in the configuration layer. This is OSR: optimize a running computation without unwinding it.

---

## 4. Interfaces & schemas

### 4.1 The JIT engine surface

```rust
/// The execution-plane dispatcher that resolves each decision to a tier and executes it.
/// Wraps AgentHarness (04); transparent to callers — same TaskSpec→HarnessResult contract.
trait JitExecutor {
    /// Resolve the current tier for a decision site and execute, trapping/deopting as needed.
    fn execute(&self, task: TaskSpec, ctx: Context) -> HarnessResult;

    /// Current tier of a decision site (read from configuration layer, 01).
    fn tier_of(&self, site: DecisionSiteId) -> Tier;

    /// Profiling hook: every decision (any tier) records an Observation (07).
    fn observe(&self, obs: Observation);
}
```

### 4.2 Compiler interface

```rust
/// The Compiler agent class — "the JIT compiler thread." Runs off the hot path.
trait Compiler {
    /// Build a Tier-1 policy from a stable observation window. Cheap (baseline JIT).
    fn synthesize_tier1(&self, rec: &ObservationRecord) -> Result<Tier1Policy, CompileError>;

    /// Attempt Tier-2 synthesis. Expensive; must return an EquivalenceCertificate or fail.
    fn synthesize_tier2(&self, rec: &ObservationRecord) -> Result<Tier2Policy, CompileError>;

    /// Equivalence / regression check of a candidate policy against Tier-0 replay (§6.3).
    fn check_equivalence(&self, candidate: &CompiledPolicy, holdout: &[Observation])
        -> EquivalenceReport;

    /// Emit the tier-change proposal (authority resolved per §5.4).
    fn propose_tier_change(&self, change: TierChange) -> ProposalRef;
}
```

### 4.3 Sentinel interface

```rust
/// The Sentinel agent class — "the JIT policy + safety monitor." Watches, never synthesizes.
trait Sentinel {
    /// Hotness + stability assessment → should we ask the Compiler to compile this site?
    fn assess_compile(&self, rec: &ObservationRecord, cost: &ErrorVector) -> Option<CompileRequest>;

    /// Monitor live trap/deopt rates and drift for an active tier.
    fn monitor(&self, site: DecisionSiteId) -> TierHealth;

    /// Decide demotion when trap rate / drift / shadow-divergence exceed tolerance.
    fn assess_demote(&self, health: &TierHealth) -> Option<DemoteRequest>;

    /// Continuous shadow/canary equivalence sampling on active Tier-1/2 sites (§6.2).
    fn shadow_sample(&self, site: DecisionSiteId, rate: f32) -> ShadowReport;
}

struct TierHealth {
    site: DecisionSiteId,
    tier: Tier,
    trap_rate: f32,          // deopts / invocations
    drift: f32,              // §5.3
    shadow_divergence: f32,  // §6.2: 1 - equivalence_rate on canary sample
    cost_saved: Cost,        // realized G1 benefit (feeds PID cost dimension)
}
```

### 4.4 Tier as state — the typed diff

A tier change is **not** an in-memory toggle; it is a **typed state update to the configuration layer** (`00-overview.md` §4, `01-state-model.md`), committed to the Merkle history, signed by a Genesis quorum exactly like any other config change. This is what makes the JIT auditable and replayable (G6).

```rust
/// A TypedDiff variant (see Proposal.diff in 00-overview §7) targeting the configuration layer.
struct TierChange {
    site: DecisionSiteId,
    agent: AgentId,
    from: Tier,
    to: Tier,
    policy: Option<Hash>,            // content address of the Tier1/Tier2 policy artifact
    equivalence: Option<Hash>,       // content address of the EquivalenceCertificate (promotions)
    reason: TierChangeReason,        // Promote{hotness,cost} | Demote{trap_rate,drift,divergence}
    proposer: AgentId,               // Compiler (promote) or Sentinel (demote)
}
```

The compiled-policy artifacts themselves are content-addressed and stored in the code cache; a `TierChange` references them by `Hash`. Replaying the Merkle history reproduces not only *which* agents existed but *at what tier each ran and why* — the JIT's decisions are part of the verifiable record.

---

## 5. (Re)compilation policy

### 5.1 Promotion — when to compile up

Promote a decision site **up** a tier when all of:

- **Hot** — high `invocation_rate` at the site (it is worth optimizing at all),
- **Stable** — `StabilityStats` clears the tier's thresholds (§3.3),
- **Under cost pressure** — the controller's cost signal is pushing (next subsection),
- and, for Tier 2 specifically, a passing `EquivalenceCertificate` exists (§6.3).

Hotness alone is insufficient (a hot but unstable site stays Tier 0); stability alone is insufficient (a stable but cold site is not worth a compile); the *product*, weighted by cost pressure, is the promotion signal. This is tiered compilation: cheap Tier 1 triggers readily and broadly; expensive Tier 2 triggers rarely and only where the equivalence bar is met.

### 5.2 The economic link to the PID cost dimension (explicit)

This is the load-bearing motivation. Per `00-overview.md` §7 and `03-control-loop.md`, the controller steers on an `ErrorVector` whose `cost` component is *budget pressure*. **Harness sessions are the dominant cost.** Therefore:

> When the PID controller's `cost` error rises, it raises **cost pressure**, which **lowers the Sentinel's promotion thresholds** — making the JIT compile hot, stable paths more aggressively to drive the marginal cost of those decisions toward zero. Compilation is the execution plane's *primary actuator for the cost dimension.* The Sentinel turns "we are over budget" into "compile the hot paths."

Conversely, when cost pressure is low and the system is idle, there is little reason to risk a compile — the thresholds rise, and the JIT stays conservative. The realized savings (`TierHealth.cost_saved`) flow back through observability into the PID `cost` estimate, **closing the loop** (Principle 5): the controller can *see* the JIT working and ease cost pressure accordingly. This makes the agent-JIT a genuine control actuator, not a side optimization — it is *how* the governance plane spends less.

```
PID cost error ↑ ──▶ cost pressure ↑ ──▶ Sentinel thresholds ↓ ──▶ more promotions
        ▲                                                              │
        └──────────────  cost_saved (realized G1 benefit) ◀───────────┘
```

### 5.3 Demotion / deopt — when to compile down

Demote a site **down** a tier (a *deliberate* tier change, distinct from a single runtime deopt) when the Sentinel observes:

- **Rising trap rate** — `trap_rate` exceeds tolerance: the compiled path is missing too often, so it is no longer paying for itself (a hot inline cache that mostly misses is worse than no cache). Demote and let the site re-stabilize at Tier 0.
- **Drift** — the input→action mapping itself has changed over time (`StabilityStats.drift` high): the agent's *correct* behavior moved, so the compiled snapshot is stale. This is concept drift; the snapshot must be invalidated.
- **Distribution shift** — the input distribution moved outside the compiled domain (sustained `NoveltyGuard` firing), so coverage collapsed and the OOD boundary no longer reflects reality.
- **Shadow divergence** — canary sampling (§6.2) shows Tier-2 ≠ Tier-0 beyond tolerance: an actual equivalence failure. This is the most serious signal and triggers **immediate** demotion to Tier 0 + invalidation of the artifact.

Demotion is to the *adjacent* lower tier by default (Tier2→Tier1) unless the trigger is a correctness/equivalence failure, in which case it goes straight to **Tier 0** (the only tier guaranteed correct). Demotion, like promotion, is a committed `TierChange` (§4.4) — except *emergency* demotions on shadow-divergence may take effect immediately and be ratified retroactively (Open Q: emergency-demote authority).

### 5.4 Who authorizes a tier change?

A tier change mutates the configuration layer, and the taxonomy forbids an agent from both authoring and deciding a change (`00-overview.md` §3, separation of powers). The design honors this by routing **promotions** as ordinary typed proposals:

- The **Sentinel** detects hot+stable+cost-pressured and emits a `CompileRequest`.
- The **Compiler** synthesizes the policy, runs equivalence/shadow checks, and authors a `TierChange` proposal (it *proposes*, like a Guardian).
- **Genesis** disposes — the consensus protocol (`02`) accepts/rejects, and on acceptance the change is committed and signed.

This keeps *propose ≠ dispose* intact even inside the JIT. **Demotions for safety** are the deliberate exception: a `DivergenceGuard`/shadow-divergence demotion is a *fail-safe* and may execute autonomously and immediately (deopt to Tier 0 always being safe-by-construction, §3.6), with a ratifying commit recorded after the fact. The precise authority gradient — which tier changes are autonomous Compiler/Sentinel actions vs. which require a consensus proposal, and the threshold for each — is parked in Open Questions (§6 of `00-overview` sets ⅔ ordinary / ¾ constitutional as the defaults a policy would draw on).

---

## 6. Correctness & safety (critical)

> **Invariant (the prime directive of the agent-JIT):** *A compiled agent MUST NEVER silently diverge from its Tier-0 behavior.* Every mechanism in this section exists to make that invariant true in practice, not just on paper.

### 6.1 Guard soundness

Guards are **conservative** (§2.4): they fire whenever validity cannot be positively established. Formally, for a compiled policy `P` with guard set `G` over domain `D`, soundness requires:

> For every input `x`: if `G(x)` passes (fast path taken), then `x ∈ D` and `P(x)` is within tolerance of the Tier-0 action on `x`.

Equivalently, the guard set must **over-approximate** the unsafe region: it may trap unnecessarily (cost), but must never *fail to trap* on an input where the compiled answer could diverge (correctness). The `NoveltyGuard` is the backstop: anything the compiler did not observe densely enough is OOD by default and traps to Tier 0. **Unknown ⇒ trap.**

### 6.2 Shadow / canary execution

Before *and during* promotion, the system runs the compiled policy **alongside** Tier 0 to empirically verify equivalence:

- **Shadow (pre-promotion):** Tier 0 remains authoritative; the candidate Tier-1/2 policy runs in shadow on live (or replayed held-out) traffic. Its answers are *compared, not served*. Promote only if the equivalence rate over the shadow window clears tolerance.
- **Canary (post-promotion):** even after promotion, the Sentinel keeps sampling a fraction `rate` of live decisions, running Tier 0 in parallel and comparing. Any sustained divergence beyond tolerance trips the `DivergenceGuard` → immediate demotion (§5.3). This is the continuous analogue of a JIT validating that its speculative assumptions still hold.

```rust
struct ShadowReport {
    site: DecisionSiteId,
    samples: u32,
    equivalence_rate: f32,   // fraction where compiled action ≈ Tier-0 action
    divergences: Vec<DivergenceCase>, // logged to 07 for audit + Compiler refinement
}
```

Canary sampling means the JIT *pays a little Tier-0 cost forever* to keep the equivalence guarantee empirical and live — a deliberate, tunable correctness tax (its rate is itself a cost/safety tradeoff the controller can steer).

### 6.3 Equivalence / regression checking before promotion

No promotion to Tier 2 (and, at higher thresholds, Tier 1) without an **`EquivalenceCertificate`**: a record that the candidate matched Tier-0 behavior on a **held-out replay set** disjoint from the observation window used to synthesize it (no train/test leakage — the analogue of validating a compiled stub against the interpreter on inputs it wasn't tuned to).

```rust
struct EquivalenceCertificate {
    policy: Hash,                 // the compiled artifact
    holdout: Hash,                // content address of the held-out replay set
    equivalence_rate: f32,        // must clear τ_equiv
    metric: EquivalenceMetric,    // exact | semantic-distance | task-outcome equivalence
    tolerance: f32,
    canonicalizer: Hash,          // the canonicalizer in force (its soundness is assumed)
    checked_by: AgentId,          // Compiler
    at: LogicalTime,
}
```

The certificate is content-addressed and referenced by the `TierChange` (§4.4), so the basis for every promotion is itself in the Merkle history and re-checkable. *What "equivalence" of an LLM action and synthesized code even means* — exact match? semantic distance? identical downstream task outcome? — is genuinely open and parked below.

### 6.4 Audit trail in the Merkle history

Because tier is configuration-layer state (§4.4):

- Every promotion/demotion is a **signed `Commit`** (`00-overview.md` §7) with its `TierChange` diff, the policy artifact hash, the equivalence certificate hash, the proposer, and the consensus decision.
- The history is **replayable**: one can reconstruct, for any past logical time, which sites were at which tier, under which policy, justified by which evidence.
- This satisfies Principle 6 (*Record everything immutably*) for the execution plane and gives the Sentinel/reputation systems (`08`) a tamper-evident basis for attributing good/bad compilations to specific Compilers (a Compiler that ships diverging Tier-2 artifacts loses reputation, decaying its influence — Principle 4).

### 6.5 The safety net, summarized

| Threat | Mechanism | Tier of defense |
|---|---|---|
| Compiled answer diverges on a *novel* input | `NoveltyGuard` (OOD), conservative-by-default | Prevention |
| Compiled answer diverges on an *in-domain* input | Equivalence certificate (pre) + canary (post) → `DivergenceGuard` | Detection → demote |
| Agent's correct behavior *drifts* over time | Drift detection → Sentinel `DemoteRequest` | Detection → demote |
| Context the policy assumed has *changed* | `StalenessGuard` | Prevention |
| Synthesized Tier-2 code is buggy | Equivalence check is the trust boundary; sandbox execution (`08`) | Prevention + containment |
| Bad compile slips through | Merkle audit trail + reputation decay of the Compiler | Accountability |
| Worst case of any of the above | Deopt to Tier 0 is safe-by-construction (§3.6) | Floor |

---

## 7. Open questions & ambiguities

1. **Proving behavioral equivalence of an LLM agent and synthesized code.** What does "equivalent" *mean* for a stochastic policy and a deterministic function — exact action match, semantic/embedding distance under a threshold, or identical *downstream task outcome*? Each gives a different `EquivalenceMetric` and a different safety story. Tier-0 itself is nondeterministic, so the target is a *distribution*, not a point; is the right contract "the compiled answer lies in the high-probability support of Tier-0's action distribution"? Unresolved.
2. **How much observation is "enough" to compile safely?** The window size / coverage / consistency thresholds (§3.3) trade premature compilation (unsafe) against missed savings (wasteful). Is there a principled stopping rule (e.g. PAC-style sample-complexity bound on the OOD boundary, or a sequential test) rather than hand-tuned `τ`'s? Who owns these thresholds — are they constants, Sentinel-learned, or a control surface the PID itself tunes?
3. **Agents whose correct behavior is inherently context-dependent and never stabilizes.** Some Workers *should* stay megamorphic forever (genuinely novel judgment every time). The design says "stay Tier 0," but detecting "will never stabilize" vs. "has not stabilized yet" is itself a hard inference. Is there a cost to repeatedly *attempting* and aborting compilation on such sites?
4. **Who authorizes a tier change — consensus proposal vs. autonomous Compiler/Sentinel action?** §5.4 routes promotions through Genesis consensus and lets safety demotions be autonomous-and-ratified. But is a Tier-1 inline-cache fill low-stakes enough to be fully autonomous (like a JIT just doing its job), while Tier-2 synthesis is high-stakes enough to require a vote? Where exactly is the authority line, and should it scale with the blast radius of the compiled site?
5. **Canonicalizer soundness.** Everything rests on canonicalization correctly defining "the same situation" (§2.3). A canonicalizer that over-collapses inputs is a *silent* source of divergence that guards may not catch (because the two inputs look identical to the guard). How is a canonicalizer itself validated/synthesized, and is it subject to the same equivalence discipline?
6. **Confidence calibration provenance.** Guards lean on harness self-reported `confidence`, which is itself an unreliable LLM output. How much can the JIT trust it before calibration against ground truth (`08`) is established? Should `ConfidenceGuard` thresholds be reputation-weighted per harness?
7. **Emergency-demote authority and rollback semantics.** Autonomous shadow-divergence demotion executes before consensus ratifies it (§5.3). What if ratification later *rejects* the demotion? Can a tier change be "rolled back" given the history is append-only, and does a contested emergency action affect the Compiler's/Sentinel's reputation?
8. **Polymorphic explosion.** When does a growing PIC (rising `arity`) tip from "worth maintaining k clusters" to "effectively megamorphic, demote to Tier 0"? The threshold `k_max` is currently hand-set.
9. **Cross-agent / cross-site sharing of compiled policies.** Two Workers with the same role+goal may converge on the same stable behavior. Can a compiled policy be *shared* (content-addressed, so deduplication is natural) or is behavior identity-bound? Sharing multiplies savings but couples agents.

---

## 8. Relationships to other specs

| Spec | Relationship |
|---|---|
| **`00-overview.md`** | Canonical anchor. Reuses `Tier`, `AgentHarness`, `Hash`, `Commit`, `AgentId`, `ErrorVector`, the Compiler/Sentinel roles, and Principles 2 & 7 verbatim. This spec is the elaboration of the JIT commitment in §1 and Principle 7. |
| **`04-runtime-and-harness.md`** | Direct substrate. `JitExecutor` wraps `AgentHarness::run` (Tier 0) and is transparent at the `TaskSpec → HarnessResult` boundary. `TaskSpec`, `Context`, `HarnessResult`, `CapabilitySet` are defined there. Tier-2 artifacts execute within the harness sandbox. |
| **`03-control-loop.md`** | The economic engine. The PID `cost` dimension drives compilation pressure (§5.2); realized `cost_saved` feeds back into the cost estimate. The agent-JIT is the execution plane's **primary actuator for the cost dimension**. |
| **`01-state-model.md`** | Tier is configuration-layer state. Every `TierChange` is a `TypedDiff` committed to the Merkle DAG; compiled-policy artifacts and equivalence certificates are content-addressed nodes. The audit trail (§6.4) lives here. |
| **`02-consensus.md`** | Promotions are routed as typed `Proposal`s and disposed by Genesis consensus (propose ≠ dispose preserved inside the JIT, §5.4). |
| **`07-observability.md`** | Supplies all profiling, trap/deopt telemetry, drift signals, and shadow/canary comparisons the Compiler and Sentinel consume. `DeoptEvent`, `ObservationRecord`, `ShadowReport`, `TierHealth` are emitted here. |
| **`08-trust-and-security.md`** | Signs `TierChange` commits and policy artifacts; sandboxes Tier-2 execution; supplies confidence calibration; decays the reputation of Compilers that ship diverging artifacts (Principle 4). |
