# Metatron — The PID Control Loop

> **Status:** Research architecture specification (v0.1)
> **Plane:** Governance.
> **Owns:** `ErrorVector`, the measured error signal, the multi-variable PID controller, the control-action mapping.
> **Anchored to:** `00-overview.md` (canonical vocabulary and types). Where this spec names a type defined there — `ErrorVector`, `Proposal`, `Decision`, `WorldModel`, `Layer`, `AgentId` — it uses it verbatim. When this spec disagrees with `00-overview.md`, the overview wins.

---

## 1. Purpose

Principle 5 of the overview — *close the loop, measure the error* — is realized here. Metatron treats the running multi-agent system as a **plant** and steers it toward a user-defined **setpoint** with a **multi-variable PID controller**. This spec defines, with control-theoretic rigor:

- the **setpoint** (the user's target state, from the Interaction plane, `06`) and the **measured state** (from estimators that fuse the Observability plane, `07`, with LLM judges and the consensus `Decision.dispersion` from `02`);
- the **error signal** as a genuine real vector — `ErrorVector` — with one component per controlled dimension (progress, cost, divergence, latency), extensible to more;
- the **PID law**: per-dimension proportional, integral, and derivative terms, with per-dimension gains, in a discrete-time (sampled) formulation;
- the mapping from the controller's continuous **control vector** to discrete, **advisory control actions** (spawn/retire agents, rewire, re-plan, escalate, JIT/deopt, widen/narrow the council);
- the **governance boundary**: control actions are *never* applied directly. They are handed to Guardians (`06`), who author typed `Proposal`s (`02`) that remain subject to consensus. The controller advises; the council disposes.
- the **stability engineering** that keeps a loop driven by noisy, LLM-derived measurements from oscillating or thrashing the org-chart: anti-windup, saturation, deadband/hysteresis, measurement low-pass filtering, and a gain-tuning approach that respects the absence of a plant model.

The controller is the **governor** wrapped around Kubernetes-style reconciliation (overview §5). Reconciliation drives *actual* state toward *desired* state; the PID controller decides **how desired state itself should move** in response to the measured gap.

### 1.1 Non-goals

- The controller does **not** execute actions, mutate the world-model, or write commits. It emits advisory `ControlAction`s only.
- The controller does **not** decide *whether* a proposal passes — that is consensus (`02`).
- The controller is **not** a metaphor. "Error", "gain", "integral windup", and "setpoint" carry their literal control-theory meaning throughout.

---

## 2. Concepts

### 2.1 The plant, the setpoint, and the loop

In classical control a *controller* drives a *plant* to track a *reference* `r(t)` by acting on the error `e(t) = r(t) − y(t)`, where `y(t)` is the measured output. Metatron maps onto this as:

| Control theory | Metatron |
|----------------|----------|
| Plant | The running multi-agent system (org-chart + execution + progress) |
| Output `y(t)` | The **measured state**: estimator outputs per dimension |
| Reference / setpoint `r(t)` | The **user's target state** (`06`), projected per dimension |
| Error `e(t) = r − y` | The **`ErrorVector`** |
| Controller | This PID controller |
| Actuator | Guardians → `Proposal`s → consensus → reconciliation |
| Sensor | Estimators over Observability (`07`), LLM judges, and `Decision.dispersion` (`02`) |

The crucial structural difference from a classical loop: **the actuator path runs through deliberation**. Between the controller's output and any change to the plant sits the consensus protocol, which may reject, amend, or delay the action. The controller is therefore an *advisory* element in a loop whose final authority is the Genesis council. This is deliberate (overview principle: *govern, don't dictate*) and has real control consequences — most importantly a **variable, sometimes large actuation latency** and a **non-ideal actuator** (the council is not guaranteed to enact what the controller requests). §6 treats the stability implications.

```
              setpoint r          ErrorVector e            control vector u        ControlActions
 user goal ──► (target  ) ──(−)──► (progress,    ) ──PID──► (per-dim       ) ──map──► [spawn, rewire,
  (06)         (per dim )    ▲     ( cost,        )          ( signal       )           replan, widen,
                            │     ( divergence,  )                                     escalate, JIT…]
                            │     ( latency, …   )                                          │
                            │                                                              ▼
                            │                                                       Guardians (06)
                            │                                                        author Proposals
                            │                                                              │
                            │                                                       Consensus (02)
                            │                                                              │ accept
                            │                                                              ▼
                            │                                                    Reconcile (04) → plant
                  measured y │◄──── Estimators ◄──── Observability (07) · LLM judges · dispersion (02)
                            └──────────────────────────────────────────────────────────────┘
```

### 2.2 Why a *vector* error, and why PID

A single scalar "health" score throws away the structure the controller needs. The dimensions are **qualitatively different** (progress wants to be *driven up*, cost and latency want to be *held under budget*, divergence wants to be *kept low*), they have **different dynamics** (cost burn is fast and smooth; progress is slow and lumpy; divergence is spiky and noisy), and they call for **different actions** (low progress → spawn/re-plan; high divergence → widen council or escalate). The controller must reason per dimension, so the error is a genuine vector and the gains are per-dimension.

PID specifically — rather than pure proportional control — because each dimension exhibits the three pathologies PID is designed for:

- **Proportional (P):** react to the *current* gap. Big gap now → big push now.
- **Integral (I):** react to *persistent, accumulated* error. A goal that has been *slightly* stuck for a long time, a budget *steadily* creeping over, slow divergence drift — none of these trip a proportional-only controller, because no single sample is alarming. The integral term accumulates them and eventually acts. This is exactly the "drift / stuck goals / budget overrun building up" class of failure.
- **Derivative (D):** react to the *rate of change*. Progress velocity collapsing, cost burn-rate spiking, divergence rising fast — the derivative term lets the controller act on the *trend* before the level becomes critical, and damps oscillation.

### 2.3 Estimators and the measured signal

Each dimension's measured value `y_d` is produced by a dedicated **estimator** that fuses:

1. **Hard metrics** from the Observability plane (`07`) — token spend, wall-clock, task-node closure counts, retry/trap rates. Deterministic, cheap, low-noise. *Preferred* (overview principle 2: determinism-first).
2. **LLM judges** — only where the quantity is irreducibly subjective (e.g. "how much real progress does this artifact represent toward the goal?"). A judge emits a **scalar in `[0,1]`**. Higher-variance; treated as a noisy sensor and filtered accordingly (§6.4).
3. **Consensus dispersion** — the divergence dimension is fed *directly* by `Decision.dispersion` from `02`. The council's measured disagreement *is* the divergence sensor; no separate judge is needed.

Estimators are the **sensor layer**. Their outputs are *measurements*, never ground truth; the entire stability discussion in §6 follows from taking sensor noise seriously.

### 2.4 Advisory control actions and the governance boundary

The controller's output is a continuous **control vector** `u ∈ R^D`. An **action-selection** stage maps `u` (with hysteresis and saturation) to a set of discrete `ControlAction`s. These are **advisory**: each is handed to a Guardian, who decides whether and how to translate it into a typed `Proposal`. The proposal then runs the full consensus protocol. Three consequences, all intentional:

- The controller **cannot** change the system by itself. It has *no write path* to the world-model.
- A control action can be **vetoed** by the council (rejected proposal) or **reshaped** by a Guardian (the action is advice, not a command).
- Every enacted control action is therefore traceable as `ControlAction → Proposal → Decision → Commit`, fully recorded in the Merkle history (overview principle 6). `Proposal.derived_from` carries the originating `ControlAction` hash.

This is the single most important boundary in this spec: **the controller advises; governance disposes.**

---

## 3. Detailed design

### 3.1 The controlled dimensions

The baseline controlled vector has **four** dimensions. The set is an ordered, extensible registry (§3.9); `D` denotes its cardinality (`D = 4` at baseline).

| `d` | Dimension | Setpoint semantics | Drives which actions |
|-----|-----------|--------------------|--------------------|
| 0 | `progress` | track a target completion trajectory (→ 1.0) | spawn/retire workers, re-plan, escalate on stall |
| 1 | `cost` | stay under a budget ceiling | retire workers, narrow council, prefer JIT (cheaper tiers), escalate on overrun |
| 2 | `divergence` | stay below a disagreement ceiling | widen council, decorrelate, re-plan, escalate |
| 3 | `latency` | stay under a responsiveness ceiling | spawn parallel workers, JIT a hot path, narrow council |

**Sign convention.** All measurements are **normalized to `[0,1]`** (§3.3) where **higher = more of the named quantity**. Error is always `e_d = r_d − y_d` (setpoint minus measured), so:

- `progress`: we *want* `y` high; `r_progress` is the target completion fraction at this time; **positive error = behind schedule** → act to accelerate.
- `cost`, `divergence`, `latency`: we *want* `y` low; `r` is the normalized ceiling; **negative error = over budget / too divergent / too slow** → act to relieve pressure.

This uniform `e = r − y` convention (rather than per-dimension ad-hoc signs) keeps the PID law identical across dimensions; the *interpretation* of the sign differs but the *math* does not.

### 3.2 The estimators, concretely

Each estimator produces `y_d(k)` at sample `k`. Notation: `metric()` reads a hard metric from `07`; `judge()` invokes an LLM judge returning `[0,1]`; `clamp01` clamps to `[0,1]`; `norm_*` are the normalizers of §3.3.

**`progress` (dimension 0).** Fuse structural completion (hard) with semantic completion (judged), because "fraction of task nodes closed" overcounts (closed-but-shallow) and undercounts (one node = a breakthrough).

```
y_progress(k) = w_s · (closed_task_nodes / total_task_nodes)          // structural, from 07
              + w_j · judge("fraction of the user goal genuinely met", artifacts)   // semantic, [0,1]
              ,  w_s + w_j = 1     // default w_s = 0.6, w_j = 0.4
```

**`cost` (dimension 1).** Pure hard metric; no judge needed. Budget pressure = spend so far against the user's budget.

```
y_cost(k) = clamp01( cumulative_spend(k) / budget_ceiling )           // from 07 + 06 budget
            // spend in a common unit (tokens × price + wallclock × rate); see 07
```

**`divergence` (dimension 2).** Fed *directly* by consensus dispersion (overview §7 note: "Dispersion … feeds the PID divergence signal"). Over a sampling window, aggregate the `dispersion` field of recent `Decision`s, optionally blended with a Sentinel-derived off-protocol rate (`05`/`08`).

```
y_divergence(k) = w_c · ewma( Decision.dispersion over decisions in window )   // from 02, the council's disagreement
                + w_p · sentinel_offprotocol_rate(k)                            // from 05/08, optional, default w_p = 0
                ,  w_c + w_p = 1     // default w_c = 1.0 (dispersion alone)
```

The council's disagreement is a *measured signal*, not a metaphor: when Genesis is split, the system is uncertain about its own direction, and the controller should act (widen the council, decorrelate, or escalate).

**`latency` (dimension 3).** Hard metric: responsiveness against a target. Use the staleness of the head and the age of the oldest open task / unanswered mailbox question.

```
y_latency(k) = clamp01( max( head_staleness, oldest_open_task_age, mailbox_wait )
                        / latency_ceiling )                            // all from 07 + 06
```

**General estimator contract.** Every estimator implements `Estimator` (§4). Estimators that call judges declare a per-call **noise estimate** `sigma_d` used to set filter strength (§6.4). Estimators are sampled, side-effect-free reads; they never write state.

### 3.3 Normalization

The dimensions are heterogeneous (a token count, a wall-clock duration, a unitless dispersion, a node ratio). The PID law combines them only through **per-dimension gains**, so dimensions never need to be *mutually* comparable — but each must be on a **stable, bounded scale** so its gains mean something fixed over time. We normalize every measurement to `[0,1]`:

- **Ratio-to-ceiling** (`cost`, `latency`): divide by a user/Guardian-supplied ceiling, clamp to `[0,1]`. The setpoint is then simply the ceiling-fraction we tolerate (e.g. `r_cost = 0.8`: act once 80% of budget is consumed).
- **Already-bounded** (`progress`, `divergence`): structural ratios and dispersion are natively `[0,1]`; judges emit `[0,1]` by contract.

Normalization is a **modeling choice with consequences** (whether heterogeneous scales are truly comparable is parked in §7). The deliberate decision here is to **decouple** the dimensions (§3.6) so cross-scale comparability is *not required* for correctness — only per-dimension scale stability is.

### 3.4 Discrete-time formulation

The controller is **sampled**, not continuous. It runs once per **control period** `T_s` (the *sampling period*). Default `T_s = 30 s`, lower-bounded by estimator cost (judges are not free) and upper-bounded by responsiveness needs; it is itself adaptable (§6.6). Sample index `k`; wall-time `t = k · T_s`.

For each dimension `d`, with error `e_d(k) = r_d(k) − y_d(k)`:

**Proportional term**

```
P_d(k) = Kp_d · e_d(k)
```

**Integral term** (accumulated error; backward-rectangular discretization)

```
I_d(k) = I_d(k−1) + Ki_d · e_d(k) · T_s          // running sum of error × period
```

with **clamping anti-windup** (§6.1) applied to `I_d` every step.

**Derivative term** (rate of change). To avoid amplifying sensor noise, the derivative acts on the **filtered measurement**, not on the error, and not on the raw signal — this is *derivative-on-measurement* with a low-pass, the standard defense against derivative kick and noise (§6.4):

```
D_d(k) = −Kd_d · ( ŷ_d(k) − ŷ_d(k−1) ) / T_s     // ŷ = low-pass-filtered measurement
```

(The minus sign and use of `ŷ` instead of `e` make this derivative-on-measurement: with a constant setpoint, `d e/dt = −d y/dt`, so the sign is preserved while a setpoint step no longer produces an impulsive "kick".)

**Control law (per dimension)**

```
u_d(k) = sat_d( P_d(k) + I_d(k) + D_d(k) )       // sat_d = actuator saturation, §6.2
```

The full **control vector** is `u(k) = [u_0(k), …, u_{D−1}(k)]`. Each `u_d ∈ [−1, 1]` after saturation: sign = direction of needed correction, magnitude = urgency.

### 3.5 Per-dimension gains (baseline)

Gains encode each dimension's dynamics and the asymmetry of the cost of acting. These are **starting points** for the tuning procedure of §6.5, *not* claimed-optimal constants (the absence of a plant model is parked in §7).

| `d` | Dim | `Kp` | `Ki` | `Kd` | Rationale |
|-----|-----|------|------|------|-----------|
| 0 | progress | 0.6 | 0.05 | 0.3 | Moderate P; small I so a *persistently* stuck goal eventually forces action; meaningful D to catch a velocity collapse early. |
| 1 | cost | 0.8 | 0.15 | 0.4 | High P and I — budget overrun is cumulative and unforgiving; strong D to catch burn-rate spikes (runaway loops). |
| 2 | divergence | 0.4 | 0.02 | 0.2 | **Low** gains — the divergence sensor is the noisiest (LLM/dispersion-derived); high gains here are the most dangerous (§6.7). Heavy reliance on filtering. |
| 3 | latency | 0.5 | 0.05 | 0.3 | Balanced; D matters because latency trends predict SLA breaches before they happen. |

Units note: because measurements are dimensionless `[0,1]` and `T_s` is in seconds, `Ki_d` carries units of `s⁻¹` and `Kd_d` units of `s`; the table values assume `T_s = 30 s` and are re-derived if `T_s` changes (§6.6).

### 3.6 Decoupled per-dimension PID (with a coupling escape hatch)

The baseline is **`D` independent SISO PID loops**, one per dimension — *not* a full MIMO controller. Rationale:

- It is **tunable without a plant model**: each loop has 3 interpretable gains tuned in isolation (§6.5). A MIMO design needs a coupling/interaction model we do not have.
- It is **interpretable and auditable**: every control action traces to one dimension's error, which matters because actions become governance proposals that humans and the council review.
- It is **robust to a missing/failed sensor**: one estimator going dark disables one loop, not the controller.

The dimensions *are* coupled in reality (spawning workers to fix `progress` raises `cost` and may raise `divergence`; JIT-compiling to fix `latency` lowers `cost`). The decoupled design handles this **at the action layer, not the control law**: the action-selection stage (§3.7) is aware of cross-dimension side-effects and the council sees the *net* of all proposals in a cycle. A static **decoupling/interaction matrix** `Γ ∈ R^{D×D}` is reserved as an optional pre-compensation step (`u' = Γ · u`) for future MIMO work; at baseline `Γ = I`. Whether decoupled SISO is sufficient or a true MIMO controller is warranted is parked in §7.

### 3.7 Action selection: from control vector to `ControlAction`s

The control vector `u(k)` is continuous; the plant accepts **discrete** interventions. Action selection maps `u` to a (possibly empty) set of `ControlAction`s. Two stages:

**Stage 1 — gating (per dimension).** A dimension only "fires" if its control signal clears a **deadband** `δ_d` *and* its sign indicates the direction the action library can address, with **hysteresis** so a dimension hovering at threshold does not flap (§6.3):

```
fires(d, k) = |u_d(k)| ≥ δ_on_d        (to start acting)
fires(d, k) = |u_d(k)| ≥ δ_off_d       (to keep acting; δ_off_d < δ_on_d)
```

**Stage 2 — mapping.** For each firing dimension, select an action from that dimension's library, with **magnitude → intensity** and **sign → direction**:

| Dim | Sign of `e_d` (= `r−y`) | Condition | Candidate `ControlAction` |
|-----|--------------------------|-----------|---------------------------|
| progress | `+` (behind) | velocity ok, just slow | `Replan` (decompose differently) |
| progress | `+` (behind) | velocity ≈ 0 (D small, level stuck) | `SpawnAgents{role: Worker, n ∝ |u|}` |
| progress | `+` (behind) | integral saturated (long-stuck) | `EscalateToUser{reason: StuckGoal}` |
| progress | `−` (ahead) | over-provisioned | `RetireAgents{n ∝ |u|}` |
| cost | `−` (over budget) | burn spiking (D large) | `RetireAgents` + `NarrowCouncil` |
| cost | `−` (over budget) | steady overrun (I large) | `TriggerJit{target: hot_path}` (cheaper tier) ; `EscalateToUser{reason: BudgetOverrun}` |
| divergence | `−` (too split) | persistent disagreement | `WidenCouncil{Δ ∝ |u|}` ; `Decorrelate{swap harnesses}` |
| divergence | `−` (too split) | irreducible / value-laden | `EscalateToUser{reason: Disagreement}` |
| latency | `−` (too slow) | parallelizable | `SpawnAgents{parallel}` |
| latency | `−` (too slow) | hot deterministic path | `TriggerJit{target: hot_path}` |
| latency | `−` (too slow) | council is the bottleneck | `NarrowCouncil` |
| (any) | — | a Tier-2 path keeps trapping | `Deopt{agent}` (`05`) |

**Conflict resolution.** When firing dimensions select antagonistic actions (e.g. `cost` says `RetireAgents`, `progress` says `SpawnAgents`), the selector emits **both** as advisory actions tagged with their driving error magnitudes and lets the **actuator path arbitrate**: Guardians may merge them into a single net proposal, and consensus weighs the trade-off. The controller does not pre-resolve value trade-offs that the council exists to make. (This is the practical payoff of routing actuation through governance.)

The output is a `ControlBatch` (§4): the set of advisory actions for sample `k`, each carrying provenance.

### 3.8 The governance hand-off (actuator path)

```
ControlBatch ─► Guardian (06): for each ControlAction
                  ├─ accept → author Proposal{ derived_from = action.hash, diff = … }
                  ├─ reshape → author a different/merged Proposal
                  └─ drop → record "advice declined" (still logged to 07)
                         │
                 Proposal ─► Consensus (02): verify → blind vote → deliberate → Decision
                         │
                 Decision.passed ? ─► Commit (01) ─► Reconcile (04) ─► plant
                         │
                 (Decision.dispersion feeds back into the divergence estimator next sample)
```

The controller **never** appears downstream of the Guardian. Its sole outputs are `ControlBatch`es and its sole inputs are estimator readings. This is what makes the loop *governed* rather than *dictated*.

### 3.9 Extensibility: adding a dimension

A new controlled dimension (e.g. `quality`, `risk`, `user_satisfaction`) is added by registering a `DimensionSpec` (§4): a name, an `Estimator`, a default setpoint source (`06`), default gains, deadband, and saturation limits. `ErrorVector` is the canonical baseline shape (overview §7) but the controller operates over the **dimension registry**, so adding a dimension does not change the control law — only `D`. The overview's `ErrorVector` struct carries the baseline four named fields plus an open `extra: Map<DimId, f32>` for registered extensions (§4), preserving the canonical type while remaining extensible.

---

## 4. Interfaces & schemas

Rust-flavored pseudotypes. Types named in `00-overview.md` are reused verbatim and only *referenced* here.

```rust
// ===== Identifiers =====
type DimId = u16;                         // index into the dimension registry
type Hash  = [u8; 32];                    // from 00 (Merkle content address)

// ===== The error signal (canonical type from 00-overview §7, shown with the extension hook) =====
struct ErrorVector {
    progress:   f32,                      // setpoint − measured, per dimension
    cost:       f32,
    divergence: f32,
    latency:    f32,
    extra: std::collections::BTreeMap<DimId, f32>,   // registered extension dimensions (§3.9)
}

// ===== Sensor layer =====
/// One measurement of one dimension at sample k.
struct Measurement {
    dim:   DimId,
    value: f32,          // normalized to [0,1] (§3.3)
    sigma: f32,          // estimator's self-reported noise stddev (drives filtering, §6.4)
    k:     u64,          // sample index
}

/// A dimension's sensor. Side-effect-free; reads 07 / invokes judges / reads 02 dispersion.
trait Estimator {
    fn dim(&self) -> DimId;
    /// Sampled read. `obs` exposes Observability (07); `gov` exposes recent Decisions (02).
    fn measure(&self, obs: &ObservabilityView, gov: &GovernanceView, k: u64) -> Measurement;
}

// ===== Per-dimension configuration =====
struct Gains { kp: f32, ki: f32, kd: f32 }

struct Saturation { lo: f32, hi: f32 }    // actuator limits on u_d (default [-1, 1], §6.2)

struct Deadband { on: f32, off: f32 }     // hysteresis thresholds, off < on (§6.3)

struct Filter {                           // measurement low-pass (§6.4)
    alpha_base: f32,                      // EWMA base smoothing in (0,1]
    noise_adaptive: bool,                 // shrink alpha when sigma is high
}

struct AntiWindup {
    i_min: f32, i_max: f32,               // integral clamp (§6.1)
    conditional: bool,                    // also stop integrating while saturated (§6.1)
}

struct DimensionSpec {
    dim:        DimId,
    name:       &'static str,             // "progress" | "cost" | "divergence" | "latency" | …
    estimator:  Box<dyn Estimator>,
    setpoint:   SetpointSource,           // pulls r_d from the user target (06)
    gains:      Gains,
    saturation: Saturation,
    deadband:   Deadband,
    filter:     Filter,
    anti_windup: AntiWindup,
    higher_is_better: bool,               // progress=true; cost/divergence/latency=false (for action mapping only)
}

/// Where the per-dimension setpoint r_d comes from. Resolved against the user target state in 06.
enum SetpointSource {
    Trajectory(/* target completion vs. logical time */),   // progress
    Ceiling(f32),                                            // cost/divergence/latency (normalized cap)
    Fixed(f32),
}

// ===== Controller state (per dimension) =====
struct PidState {
    integral:   f32,      // I_d(k)
    last_filt:  f32,      // ŷ_d(k−1), for the derivative
    filt:       f32,      // ŷ_d(k)
    last_u:     f32,      // for hysteresis / deadband
    firing:     bool,     // hysteresis latch
}

// ===== Controller =====
struct Controller {
    registry: Vec<DimensionSpec>,         // the D dimensions, ordered
    t_s:      Duration,                   // sampling period T_s (§3.4)
    state:    Vec<PidState>,
    gamma:    Option<Matrix>,             // optional decoupling matrix Γ (§3.6); None ⇒ identity
}

impl Controller {
    /// One control step. Pure w.r.t. the world-model: emits advice, writes nothing.
    fn step(&mut self, obs: &ObservabilityView, gov: &GovernanceView, k: u64)
        -> ControlBatch
    {
        // 1. measure → 2. filter → 3. error → 4. P,I,D (with anti-windup) → 5. saturate
        //    → 6. (optional Γ pre-compensation) → 7. deadband/hysteresis gating
        //    → 8. action mapping (§3.7). Returns advisory actions only.
        unimplemented!()
    }

    fn error_vector(&self) -> ErrorVector;   // current e(k), for logging to 07 and the Merkle record
}

// ===== Control output (advisory) =====
enum ControlAction {
    SpawnAgents   { role: Role, n: u32, parallel: bool },
    RetireAgents  { n: u32 },
    Rewire        { /* edits to the configuration layer wiring */ },
    Replan        { scope: TaskScope },
    WidenCouncil  { delta: u32 },
    NarrowCouncil { delta: u32 },
    Decorrelate   { /* swap harnesses / reseed (overview principle 3) */ },
    TriggerJit    { target: HotPathRef },     // 05
    Deopt         { agent: AgentId },          // 05
    EscalateToUser{ reason: EscalationReason },// 06 mailbox
}

enum EscalationReason { StuckGoal, BudgetOverrun, Disagreement, LatencyBreach, Other }

/// One advisory action plus the provenance that lets a Proposal cite it (Proposal.derived_from).
struct AdvisedAction {
    action:        ControlAction,
    driven_by:     DimId,           // which dimension's error produced it
    error:         f32,             // e_d(k) at emission
    control:       f32,             // u_d(k) at emission
    urgency:       f32,             // |u_d| normalized; advisory priority for the Guardian
    rationale:     Text,            // advisory only (overview: rationale is non-binding)
}

/// The full set of advice for sample k. Handed to Guardians (06); never applied directly.
struct ControlBatch {
    k:        u64,
    error:    ErrorVector,          // logged to 07 + recorded in history
    actions:  Vec<AdvisedAction>,
    conflicts: Vec<(usize, usize)>, // indices of antagonistic action pairs for Guardian/council arbitration (§3.7)
}
```

**Hand-off contract.** `Controller::step` returns a `ControlBatch`. The runtime delivers it to the Guardian pool (`06`). A Guardian that accepts an `AdvisedAction` authors a `Proposal` with `derived_from = hash(advised_action)`. The controller observes the *outcome* only indirectly, through the next sample's estimator readings (including `Decision.dispersion`). There is no synchronous return path from consensus into the controller — the loop closes through *measurement*, as a control loop should.

---

## 5. Stability & robustness engineering

> This section is the control-theoretic core. A naive PID over LLM-derived measurements will oscillate, wind up, and thrash the org-chart. The mechanisms below are mandatory, not optional.

### 5.1 Integral anti-windup

The integral term accumulates error. If the actuator is saturated or the council keeps **rejecting** the controller's advice, error persists, `I_d` grows without bound, and when the situation finally clears the controller massively over-corrects (classic *integral windup*). Because Metatron's actuator is a *deliberative body that can refuse*, windup risk is **higher** here than in a normal control loop. Two combined defenses:

- **Clamping:** hard-limit `I_d ∈ [i_min, i_max]` every step.
- **Conditional integration:** freeze integration (`I_d(k) = I_d(k−1)`) whenever the output is saturated *or* the previous batch's advice for this dimension was declined/rejected — i.e. stop accumulating error the controller is **not currently able to act on**.

Rejected-advice-aware anti-windup is the Metatron-specific twist: the integrator must not punish the controller for the council's vetoes.

### 5.2 Actuator saturation

`u_d` is saturated to `[lo, hi]` (default `[−1, 1]`) because the *physical* action library is bounded: you can only spawn so many workers, widen the council so far, escalate once. Saturation is modeled explicitly (`sat_d`) so the integral can be anti-windup-protected against it (§5.1). Action **intensity** (e.g. `n` workers) is a saturating function of `|u_d|`, with per-action hard caps enforced downstream by Guardians/consensus regardless of what the controller requests.

### 5.3 Deadband & hysteresis — don't thrash the org-chart

Reorganizing the team is **expensive and disruptive**: spawning/retiring agents, rewiring, re-planning all cost tokens, latency, and continuity. A controller that reacts to every tiny error will **flap** the org-chart (spawn-retire-spawn). Defenses:

- **Deadband `δ`:** no action unless `|u_d| ≥ δ_on_d`. Small errors are tolerated, not acted on.
- **Hysteresis:** once firing, keep acting until `|u_d|` falls below `δ_off_d < δ_on_d`. The on/off gap prevents chattering at the threshold.
- **Action cooldown:** a minimum number of samples between *structural* actions on the same dimension (a rate limiter on top of hysteresis), so even sustained borderline signals cannot churn the team faster than it can stabilize.

Deadband trades **tracking precision for stability** — exactly the right trade when the actuator is costly and the sensor is noisy.

### 5.4 Measurement filtering — surviving noisy LLM sensors

LLM judges and dispersion are **noisy sensors**: the same artifact judged twice can return different scalars. Feeding raw noise into P (jitter) and especially D (noise amplification — the derivative of noise is enormous) destabilizes the loop. Defenses:

- **Low-pass / EWMA smoothing:** `ŷ_d(k) = α_d · y_d(k) + (1−α_d) · ŷ_d(k−1)`. The derivative term uses `ŷ`, never raw `y` (§3.4), the standard noise defense.
- **Noise-adaptive `α`:** shrink `α_d` (trust the new sample less) when the estimator's self-reported `sigma` is high — judge-heavy dimensions get heavier filtering than metric-only ones. `cost`/`latency` (hard metrics) can run near `α ≈ 1`; `divergence`/judged-`progress` need small `α`.
- **Sampling-rate matching:** don't sample faster than the sensor produces *independent* information. Re-judging the same unchanged artifact every 30 s yields correlated noise, not signal; gate judge calls on actual artifact change.
- **Median-of-N judges:** for high-stakes dimensions, take several judge samples and use the median (a cheap robust estimator) — the same decorrelation logic the council uses (overview principle 3), applied to sensing.

Filtering trades **responsiveness for stability**: a smoothed sensor lags. Combined with conservative gains (§5.5), this is the correct bias for a system where an over-eager reorganization is worse than a slightly delayed one.

### 5.5 Why naive high gains are dangerous here

High gains give fast tracking in a clean loop. In Metatron they are **especially dangerous**:

1. **Loop delay is large and variable.** Actuation runs through deliberation (round-trips, possible blocking on the mailbox) and reconciliation. High gain + significant transport delay is the textbook recipe for **instability** (the correction arrives after the situation has already changed, so it pushes the wrong way → oscillation).
2. **The actuator is discrete, costly, and irreversible-ish.** Spawning then retiring a worker is not a free, smooth nudge; it burns budget and disrupts in-flight work. High gain converts sensor noise directly into **org-chart thrash**.
3. **The sensor is noisy and sometimes biased.** High `Kd` over a noisy judge amplifies noise; high `Ki` over a biased judge integrates the bias into a large standing error.
4. **The plant is non-stationary.** The "plant" (an LLM-agent ensemble) changes as agents are added, JIT-compiled, and as reputation shifts — its gain is not constant. A controller tuned hot for one regime is unstable in another.

The design therefore **biases low**: conservative gains, heavy filtering on noisy dimensions, deadband, cooldowns. **Under-correcting is recoverable** (the error persists and the integral eventually acts); **over-correcting** thrashes the org-chart and wastes budget. When in doubt, escalate to the user (a `ControlAction` in its own right) rather than crank the gain.

### 5.6 Tuning approach (no plant model)

There is no transfer function for "a council of LLM agents," so classic model-based tuning (pole placement, etc.) does not apply directly. The pragmatic approach:

1. **Dimensional bootstrap:** start from §3.5's conservative gains (deliberately low).
2. **Per-loop relay/step experiments in simulation:** drive a simulated plant (recorded traces / a cheap surrogate) with step changes and a Ziegler–Nichols-style *relay* experiment to find each loop's ultimate gain `Ku` and period `Pu`, then back off well below the ZN recommendation (these loops want damping, not aggressiveness).
3. **Shadow mode:** run the controller live but **advisory-only with Guardians auto-declining** — log what it *would* have proposed, compare to what operators/council actually did, and tune to reduce false-positive actions (thrash) before false-negatives (missed corrections).
4. **Bandit/Bayesian gain search:** treat the gain vector as hyperparameters; optimize against an offline reward (goal completion per unit cost, penalized by org-chart churn) over recorded episodes.
5. **Conservatism gate:** never auto-raise gains in production; gain changes are themselves `Proposal`s subject to consensus (the controller's own tuning is governed).

### 5.7 Stability summary (block view)

```
                  ┌─────────────── per-dimension SISO loop d ───────────────┐
  r_d ──►(−)──► e_d ─► [ Kp ]──────────────┐
          ▲                                ├─►(+)─► [ sat ] ─► u_d ─► deadband/
          │          ┌─► [ Ki·Ts·Σ ]──────►┤            │        hysteresis ─► action
          │          │     ▲ anti-windup    │            │
          │          │     └── freeze if saturated/declined
          │      ┌── ŷ_d ──► [ −Kd·Δ/Ts ]──►┘            │
          │      │                                       │
          └──ŷ_d─┴── [ low-pass α(σ) ] ◄── y_d ◄── Estimator ◄── (07 / judges / 02 dispersion)
                                                          │
                  └───────────────────────────────────────┘
   coupling across d handled at the action layer + council arbitration (Γ = I at baseline)
```

---

## 6. Worked micro-example (one sample)

Illustrative, `T_s = 30 s`, baseline gains. Suppose at sample `k`:

- `progress`: `r = 0.50` (target half-done by now), `ŷ = 0.30` → `e = +0.20` (behind). Filtered velocity `Δŷ ≈ +0.001/s` (crawling). `I_progress` has been accumulating for many samples and is near its clamp.
  `P = 0.6·0.20 = 0.12`; `D = −0.3·0.001·30/30 ≈ −0.009` (tiny, slow); `I` large → `u_progress` saturates positive. Integral near clamp + near-zero velocity ⇒ **`SpawnAgents` and/or `EscalateToUser{StuckGoal}`**.
- `cost`: `r = 0.80`, `ŷ = 0.55` → `e = +0.25` (headroom, under budget). `u_cost > 0` but sign means "ahead of budget"; no relief action; possibly `RetireAgents` if strongly over-provisioned. Below deadband → **no action**.
- `divergence`: `r = 0.30`, raw dispersion samples `{0.55, 0.20, 0.50}`, `ŷ = 0.45` (heavy filtering) → `e = −0.15` (too split). `|u| ≥ δ_on` → **`WidenCouncil` / `Decorrelate`**. Low `Kd` keeps the spiky sensor from dominating.
- `latency`: `r = 0.70`, `ŷ = 0.40` → `e = +0.30` (responsive, fine). No action.

`ControlBatch{k, error = {progress:+0.20, cost:+0.25, divergence:−0.15, latency:+0.30}, actions: [SpawnAgents|Escalate(progress), WidenCouncil(divergence)], conflicts: []}` → handed to Guardians → typed `Proposal`s → consensus.

---

## 7. Open questions & ambiguities

> Parked per overview §9. Each is a genuine unresolved design question, not a TODO.

1. **Tuning without a plant model.** §5.6 is a *procedure*, not a guarantee. We have no validated transfer function for an LLM-agent ensemble, and the plant is non-stationary (§5.5.4). Open: is offline/shadow tuning sufficient, or do we need online adaptive control (gain-scheduling, MRAC), and if so how do we keep *adaptation itself* stable?
2. **Decoupled SISO vs. true MIMO.** §3.6 chooses `D` independent loops with action-layer coupling and an identity `Γ`. The dimensions are genuinely coupled (spawn ↑progress but ↑cost,↑divergence). Open: when does decoupled control measurably mis-steer, and is a proper MIMO controller (or at least a non-trivial decoupling matrix `Γ`) worth its modeling cost and loss of interpretability?
3. **Normalizing heterogeneous dimensions.** §3.3 normalizes each dimension to `[0,1]` independently and relies on per-dimension gains so cross-scale comparability is never *required*. But conflict arbitration (§3.7) and any future MIMO design *do* compare across dimensions. Open: is there a principled common scale (e.g. everything mapped to "expected impact on goal-completion-per-cost"), or is cross-dimension comparison inherently a value judgment that *should* stay with the council?
4. **LLM-judge measurement noise & bias.** Filtering (§5.4) handles *variance*; it does not handle *bias* (a judge systematically optimistic about progress integrates into a persistent steady-state error via the I term). Open: how do we calibrate judges against ground truth (tie-in to reputation, `08`), detect judge drift, and bound integral error under biased sensing?
5. **Setpoint specification burden.** Per-dimension setpoints (budget ceiling, latency cap, progress trajectory, divergence tolerance) must come from the user via `06`. Most users won't supply a divergence tolerance or a progress trajectory. Open: what are safe defaults, and can the controller *learn* setpoints from revealed preference without the user stating them?
6. **Actuation through a refusing actuator.** Consensus can persistently reject the controller's advice. Anti-windup (§5.1) prevents windup, but a controller whose every action is vetoed is *effectively open-loop*. Open: how should the controller behave when systematically overruled — escalate the *disagreement between controller and council* to the user? Decay its own influence? This is a novel failure mode with no classical analogue.
7. **Sampling period vs. judge cost.** `T_s = 30 s` assumes estimator reads (including judges) are cheap enough to run that often. High-quality judges are not. Open: per-dimension multi-rate sampling (fast for hard metrics, slow for judged dimensions) and its effect on the unified discrete-time law.
8. **Stability proof.** We assert stability heuristically (conservative gains + filtering + deadband). Open: is there *any* tractable formal stability argument (e.g. passivity, small-gain with a bounded-delay actuator model, or a Lyapunov argument over a simplified surrogate plant), even for the decoupled single-loop case?
9. **Interaction with reputation dynamics.** Reputation (`08`) re-weights votes, which changes `Decision.dispersion`, which is the `divergence` sensor — a slow inner loop nested inside the control loop. Open: can the reputation loop and the control loop resonate, and do they need to be designed with separated time-scales?

---

## 8. Relationships to other specs

| Spec | Relationship |
|------|-------------|
| `00-overview.md` | Canonical anchor. `ErrorVector`, `Proposal`, `Decision`, `WorldModel`, `Layer`, `AgentId`, the closed-loop diagram (§5), and principle 5 are defined there and reused verbatim. |
| `01-state-model.md` | The controller never writes state; enacted control actions become `Commit`s here via the actuator path. `Proposal.derived_from` links a commit back to the `ControlAction` that advised it. Logical time / sampling alignment is defined there. |
| `02-consensus.md` | **Bidirectional.** *Input:* `Decision.dispersion` is the `divergence` sensor (§3.2) — the council's disagreement *is* a measured signal. *Output:* every control action becomes a `Proposal` that runs the consensus protocol; consensus may veto or reshape it (§3.8). The controller advises; consensus disposes. |
| `04-runtime-and-harness.md` | The plant. Reconciliation drives actual→desired; the controller decides how desired *moves*. `SpawnAgents`/`RetireAgents`/`Rewire` actions ultimately become reconcile plans here. |
| `05-agent-jit.md` | `TriggerJit` and `Deopt` are control actions (cost/latency relief; trap-rate response). Sentinel-measured trap rates can feed the `divergence`/cost estimators. |
| `06-interaction-and-mailbox.md` | **Source of the setpoint.** The user's target state defines `r_d` per dimension via `SetpointSource`. Guardians are the actuator: they receive the `ControlBatch` and author proposals. `EscalateToUser` actions surface through the mailbox and may *block* affected work (overview §5). |
| `07-observability.md` | **The sensor substrate.** Hard metrics for every estimator (spend, wall-clock, task-node closure, trap/retry rates, staleness). The controller logs its `ErrorVector` and `ControlBatch` back to `07` for auditability. |
| `08-trust-and-security.md` | Reputation calibrates the LLM judges and the council whose dispersion feeds `divergence`; Sentinel off-protocol rates optionally feed the `divergence` estimator (§3.2). Judge-bias calibration (open question 4) ties in here. |
```
