# Metatron — The Steering Loop

> **Status:** Research architecture specification (v0.1)
> **Plane:** Governance.
> **Owns:** `ErrorVector`, the normalized measured-error signal, the per-dimension proportional **steering** controller, the control-action mapping.
> **Anchored to:** `00-overview.md` (canonical vocabulary and types). Where this spec names a type defined there — `ErrorVector`, `Proposal`, `Decision`, `WorldModel`, `Layer`, `AgentId` — it uses it verbatim. When this spec disagrees with `00-overview.md`, the overview wins.

---

## 1. Purpose

Principle 5 of the overview — *close the loop, measure the error* — is realized here. Metatron treats the running multi-agent system as a **plant** and **steers** it toward a user-defined **setpoint**. The load-bearing core is deliberately small: a **per-dimension proportional response to a normalized measured-error vector**, gated by **deadband + hysteresis + cooldown** and backed by a **persistently-stuck counter**, with every output routed through governance so the controller can **only advise**. This spec defines:

- the **setpoint** (the user's target state, from the Interaction plane, `06`) and the **measured state** (from estimators that fuse the Observability plane, `07`, with LLM judges and the consensus `Decision.dispersion` from `02`);
- the **error signal** as a genuine real vector — `ErrorVector` — with one component per controlled dimension (progress, cost, divergence, latency), extensible to more;
- the **control law**: a per-dimension **proportional** term over the normalized error, plus a **persistently-stuck counter** that escalates a dimension which stays out of tolerance across many samples — the load-bearing replacement for an integrator. The fuller PID apparatus (integral term, derivative term, anti-windup, Ziegler–Nichols tuning, and the MIMO `Γ` gain matrix) is **deferred until a measured oscillation demands it** (§3.10);
- the mapping from the controller's continuous **control vector** to discrete, **advisory control actions** (spawn/retire agents, rewire, re-plan, escalate, JIT/deopt, widen/narrow the council);
- the **governance boundary**: control actions are *never* applied directly. They are handed to Guardians (`06`), who author typed `Proposal`s (`02`) that remain subject to consensus. The controller advises; the council disposes.
- the **robustness engineering** that keeps a loop driven by noisy, LLM-derived measurements from thrashing the org-chart: deadband/hysteresis/cooldown, saturation, measurement low-pass filtering, and conservative proportional gains tuned without a plant model.

The controller is the **steering loop**: the deliberative governor wrapped around the Kubernetes-style **reconciliation loop** (overview §5). The two loops are **nested** and own different convergence problems. The **reconciliation loop** (the execution backend, `04`) owns convergence of *reality → committed desired-state*; the **steering loop** owns convergence of *desired-state → the user's target*. The steering loop decides **how desired state itself should move** in response to the measured gap; reconciliation then drives reality to whatever desired state consensus commits. Throughout this spec, "reconcile / reconciliation" refers **only** to that execution loop (owned by `04`); the governance-level loop is "steering."

### 1.1 Non-goals

- The controller does **not** execute actions, mutate the world-model, or write commits. It emits advisory `ControlAction`s only.
- The controller does **not** decide *whether* a proposal passes — that is consensus (`02`).
- The core is **not** a metaphor: "error", "gain", "deadband", and "setpoint" carry their literal meaning. The fuller control-theory vocabulary ("integral windup", "derivative kick") belongs to the **deferred** machinery of §3.10 and is not active in v1.

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
| Controller | This **steering** controller (proportional core) |
| Actuator | Guardians → `Proposal`s → consensus → reconciliation |
| Sensor | Estimators over Observability (`07`), LLM judges, and `Decision.dispersion` (`02`) |

The crucial structural difference from a classical loop: **the actuator path runs through deliberation**. Between the controller's output and any change to the plant sits the consensus protocol, which may reject, amend, or delay the action. The controller is therefore an *advisory* element in a loop whose final authority is the Genesis council. This is deliberate (overview principle: *govern, don't dictate*) and has real control consequences — most importantly a **variable, sometimes large actuation latency** and a **non-ideal actuator** (the council is not guaranteed to enact what the controller requests). §5 treats the robustness implications.

```
              setpoint r          ErrorVector e            control vector u        ControlActions
 user goal ──► (target  ) ──(−)──► (progress,    ) ──P────► (per-dim       ) ──map──► [spawn, rewire,
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

### 2.2 Why a *vector* error, and why proportional-first

A single scalar "health" score throws away the structure the controller needs. The dimensions are **qualitatively different** (progress wants to be *driven up*, cost and latency want to be *held under budget*, divergence wants to be *kept low*), they have **different dynamics** (cost burn is fast and smooth; progress is slow and lumpy; divergence is spiky and noisy), and they call for **different actions** (low progress → spawn/re-plan; high divergence → widen council or escalate). The controller must reason per dimension, so the error is a genuine vector and the gains are per-dimension.

**Proportional-first** — not the full PID apparatus — because the proportional term plus threshold logic is what actually carries the loop here:

- **Proportional (P):** react to the *current* gap. Big gap now → big push now. This is the active control law (§3.4).
- **Persistently-stuck counter:** the one genuinely *accumulative* failure — a goal *slightly* stuck for a long time, a budget *steadily* creeping over — is caught by a per-dimension counter that increments while the dimension sits out of tolerance and trips an escalation when it crosses a threshold. This is a deliberately simple, interpretable stand-in for an integrator: it delivers "act on persistent error" without the windup, tuning, and stability burden a real integral term adds over a vetoing, lagging actuator.
- **Deferred — integral (I) and derivative (D):** a true integral (to drive steady-state error to zero) and a derivative (to act on *trend* and damp oscillation) are documented but **not active**. In this loop the integral over "stuck for a while" reduces to the counter above, and the derivative over noisy LLM-derived sensors filters down to near-zero; both are reintroduced only if a *measured* oscillation in the proportional version demonstrably requires them (§3.10).

### 2.3 Estimators and the measured signal

Each dimension's measured value `y_d` is produced by a dedicated **estimator** that fuses:

1. **Hard metrics** from the Observability plane (`07`) — token spend, wall-clock, task-node closure counts, retry/trap rates. Deterministic, cheap, low-noise. *Preferred* (overview principle 2: determinism-first).
2. **LLM judges** — only where the quantity is irreducibly subjective (e.g. "how much real progress does this artifact represent toward the goal?"). A judge emits a **scalar in `[0,1]`**. Higher-variance; treated as a noisy sensor and filtered accordingly (§6.4).
3. **Consensus dispersion** — the divergence dimension is fed *directly* by `Decision.dispersion` from `02`. The council's measured disagreement *is* the divergence sensor; no separate judge is needed.

**Dispersion measures disagreement, not wrongness (ROB-01).** The `divergence` sensor reads how much the council *disagrees*, which is not the same as how *wrong* it is. The most dangerous real failure — a **correlated, confidently-wrong council** sharing a base model and agreeing on a bad answer — emits **low** dispersion, so a naive reading would call it "healthy" and relax. The controller must therefore **never infer a healthy reading from low dispersion alone**. It treats the composite signal **"low dispersion + low verification coverage + high subjective residue"** as an *escalating* risk signal, not a calm one (§3.7). The verification-coverage metric — the fraction of a decision that was machine-checkable — is **owned and surfaced by Observability (`07`)**; the controller reads it, it does not compute it.

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

This uniform `e = r − y` convention (rather than per-dimension ad-hoc signs) keeps the control law identical across dimensions; the *interpretation* of the sign differs but the *math* does not.

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

**`divergence` (dimension 2).** Fed *directly* by consensus dispersion (overview §7 note: "Dispersion … feeds steering-loop divergence"). Over a sampling window, aggregate the `dispersion` field of recent `Decision`s, optionally blended with a Sentinel-derived off-protocol rate (`05`/`08`).

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

**General estimator contract.** Every estimator implements `Estimator` (§4). Estimators that call judges declare a per-call **noise estimate** `sigma_d` used to set filter strength (§6.4). Per-judge **bias** is calibrated against ground truth and subtracted upstream of this contract (§7.5). Estimators are sampled, side-effect-free reads; they never write state.

### 3.3 Normalization

The dimensions are heterogeneous (a token count, a wall-clock duration, a unitless dispersion, a node ratio). The control law combines them only through **per-dimension gains**, so dimensions never need to be *mutually* comparable — but each must be on a **stable, bounded scale** so its gains mean something fixed over time. We normalize every measurement to `[0,1]`:

- **Ratio-to-ceiling** (`cost`, `latency`): divide by a user/Guardian-supplied ceiling, clamp to `[0,1]`. The setpoint is then simply the ceiling-fraction we tolerate (e.g. `r_cost = 0.8`: act once 80% of budget is consumed).
- **Already-bounded** (`progress`, `divergence`): structural ratios and dispersion are natively `[0,1]`; judges emit `[0,1]` by contract.

Normalization is a **modeling choice with consequences** (whether heterogeneous scales are truly comparable is settled in §7.4: per-dimension scales, with a common utility applied *only* at action selection). The deliberate decision here is to **decouple** the dimensions (§3.6) so cross-scale comparability is *not required* for correctness — only per-dimension scale stability is.

### 3.4 Discrete-time formulation

The controller is **sampled**, not continuous. It runs once per **control period** `T_s` (the *sampling period*). Default `T_s = 30 s`, lower-bounded by estimator cost (judges are not free) and upper-bounded by responsiveness needs; it is itself adaptable (§6.6). Sample index `k`; wall-time `t = k · T_s`.

**Multi-rate structure (§7.6).** Not every sensor produces independent information at `T_s`, and high-quality judges are too expensive to run that often. The loop is therefore **multi-rate**:

- **Fast loop** — hard-metric dimensions (`cost`, `latency`, structural `progress`, and `dispersion`-fed `divergence`) sample every `T_s = 30 s`.
- **Slow loop** — LLM-judged quantities (the semantic component of `progress`, and any judge-backed dimension) sample every `T_slow = m · T_s` with `m ∈ [5, 10]`, and **hold last value** between judge samples: `y_d(k) = y_d(k_last)` until a fresh judge sample lands.

A held measurement is **piecewise-constant** between judge samples, so the proportional term and the persistently-stuck counter keep acting on the held error while a fresh judge sample is awaited (and the deferred derivative term, §3.10, would contribute exactly zero during the hold — `ŷ_d(k) − ŷ_d(k−1) = 0`, no synthetic velocity). The control law below runs every fast step `k`; slow-loop dimensions simply re-use their most recent measurement, which keeps judge cost tractable without destabilizing the fast dimensions.

For each dimension `d`, with error `e_d(k) = r_d(k) − y_d(k)` (using the held `y_d` on the slow loop):

**Proportional term (the active control law)**

```
P_d(k) = Kp_d · e_d(k)
u_d(k) = sat_d( P_d(k) )                          // sat_d = actuator saturation, §5.2
```

The full **control vector** is `u(k) = [u_0(k), …, u_{D−1}(k)]`. Each `u_d ∈ [−1, 1]` after saturation: sign = direction of needed correction, magnitude = urgency. This is the whole control law in v1 — one proportional gain per dimension, saturated, then gated (§3.7). The integral, derivative, and `Γ` machinery is **deferred** (§3.10).

**Persistently-stuck counter (the integrator stand-in)**

```
stuck_d(k) = stuck_d(k−1) + 1   if |e_d(k)| ≥ θ_d   // out of tolerance
stuck_d(k) = 0                  otherwise           // back in tolerance resets it
```

When `stuck_d(k)` crosses a per-dimension threshold `N_d`, the dimension is **persistently stuck** and action selection escalates it (e.g. `EscalateToUser{StuckGoal}`, §3.7) regardless of whether the instantaneous proportional signal is alarming. This is the load-bearing replacement for an integral term: it catches the slow-creep / long-stuck failures a proportional-only controller would otherwise miss, without integrating sensor noise or judge bias into a standing error, and without the windup a real integrator would create over a vetoing actuator.

### 3.5 Per-dimension gains (baseline)

Gains encode each dimension's dynamics and the asymmetry of the cost of acting. These are **starting points** for the tuning procedure of §5.6, *not* claimed-optimal constants. **Only the `Kp` column is active in v1**; the `Ki`/`Kd` columns are recorded for the **deferred** integral/derivative terms (§3.10) and are not used by the proportional core. The committed tuning policy is §7.2 (offline/shadow first, then conservative online gain-scheduling); whether that ultimately suffices for the nonstationary plant remains open (§8b).

| `d` | Dim | `Kp` (active) | `Ki` (deferred) | `Kd` (deferred) | Rationale |
|-----|-----|------|------|------|-----------|
| 0 | progress | 0.6 | 0.05 | 0.3 | Moderate P; small I so a *persistently* stuck goal eventually forces action; meaningful D to catch a velocity collapse early. |
| 1 | cost | 0.8 | 0.15 | 0.4 | High P and I — budget overrun is cumulative and unforgiving; strong D to catch burn-rate spikes (runaway loops). |
| 2 | divergence | 0.4 | 0.02 | 0.2 | **Low** gains — the divergence sensor is the noisiest (LLM/dispersion-derived); high gains here are the most dangerous (§6.7). Heavy reliance on filtering. |
| 3 | latency | 0.5 | 0.05 | 0.3 | Balanced; D matters because latency trends predict SLA breaches before they happen. |

Units note (for the deferred terms): because measurements are dimensionless `[0,1]` and `T_s` is in seconds, `Ki_d` carries units of `s⁻¹` and `Kd_d` units of `s`; the table values assume `T_s = 30 s` and are re-derived if `T_s` changes (§3.4). The active `Kp_d` is dimensionless.

### 3.6 Decoupled per-dimension control (with a coupling escape hatch)

The baseline is **`D` independent SISO loops**, one per dimension — each a proportional loop in v1, with a slot for the deferred I/D terms (§3.10) — *not* a full MIMO controller. Rationale:

- It is **tunable without a plant model**: each loop has one active, interpretable proportional gain (and up to three gain slots if the deferred terms are ever enabled) tuned in isolation (§5.6). A MIMO design needs a coupling/interaction model we do not have.
- It is **interpretable and auditable**: every control action traces to one dimension's error, which matters because actions become governance proposals that humans and the council review.
- It is **robust to a missing/failed sensor**: one estimator going dark disables one loop, not the controller.

The dimensions *are* coupled in reality (spawning workers to fix `progress` raises `cost` and may raise `divergence`; JIT-compiling to fix `latency` lowers `cost`). The decoupled design handles this **at the action layer, not the control law**: the action-selection stage (§3.7) is aware of cross-dimension side-effects and the council sees the *net* of all proposals in a cycle. A static **decoupling/interaction matrix** `Γ ∈ R^{D×D}` is **deferred until a measured oscillation demands it** (§3.10): it is reserved as an optional pre-compensation step (`u' = Γ · u`) for future MIMO work, and at baseline `Γ = I`. This is settled in §7.3: **decoupled SISO with identity `Γ` ships in v1**, and a non-trivial `Γ` is a documented **upgrade path**, adopted only if cross-coupling is shown to measurably mis-steer the loop.

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
| divergence | (any) | **low dispersion + low verification coverage + high subjective residue** (`07`) | `EscalateToUser{reason: ConfidentCollectiveError}` + decorrelated red-team lane (`02`) — *escalate, not relax* |
| latency | `−` (too slow) | parallelizable | `SpawnAgents{parallel}` |
| latency | `−` (too slow) | hot deterministic path | `TriggerJit{target: hot_path}` |
| latency | `−` (too slow) | council is the bottleneck | `NarrowCouncil` |
| (any) | — | a Tier-2 path keeps trapping | `Deopt{agent}` (`05`) |

**Conflict resolution.** When firing dimensions select antagonistic actions (e.g. `cost` says `RetireAgents`, `progress` says `SpawnAgents`), the selector emits **both** as advisory actions tagged with their driving error magnitudes and lets the **actuator path arbitrate**: Guardians may merge them into a single net proposal, and consensus weighs the trade-off. Where the trade-off is numerically comparable, antagonistic actions are scored on a common *expected goal-completion-per-cost* utility **at this layer only** (§7.4); genuinely incomparable, value-laden trade-offs are escalated to the council, not resolved by the controller. The controller does not pre-resolve value trade-offs that the council exists to make. (This is the practical payoff of routing actuation through governance.)

**Confident collective error — escalate, not relax (ROB-01).** Because dispersion measures *disagreement, not wrongness* (§2.3), a *low* divergence reading is not by itself evidence of health. When Observability (`07`) reports the composite **low dispersion + low verification coverage + high subjective residue**, the controller treats it as a high-priority **escalation** trigger — advising a decorrelated red-team lane (`02`) and `EscalateToUser{ConfidentCollectiveError}` — rather than standing down because the divergence error is small. The "healthy" branch (no divergence action) fires only when low dispersion is accompanied by *adequate verification coverage*; low dispersion alone never closes the loop.

**Council-repair actions need an actuator that survives a broken council (ROB-04).** The council-repair actions — `WidenCouncil`, `Decorrelate`, and recompose — are the controller's response to a split or degraded council. But if they are emitted as ordinary proposals they must pass the very quorum that is broken, so a genuinely deadlocked or split council cannot ratify its own repair. The controller therefore **detects deadlock/split** — e.g. `divergence` pinned high with no passing `Decision` across a bounded number of samples, or a tripped persistently-stuck `divergence` counter — and in that degraded case routes repair through the **founder-threshold break-glass / human-escalation recovery path** defined in `02` and `08`, which bypasses the deadlocked quorum, instead of relying on the broken quorum to pass the fix. This guarantees the steering loop has a **working actuator in exactly the situation it exists to handle**.

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

### 3.10 Deferred until a measured oscillation demands them

The following classical-control machinery is **documented as a future upgrade path, not active in v1**. The preconditions PID needs — a plant model, a stationary plant, a prompt and faithful actuator, low-noise sensors — do **not** hold here (a vetoing/lagging council actuator, noisy LLM-judge sensors, a non-stationary agent ensemble), and the load-bearing anti-thrash behavior is already delivered by the proportional term plus deadband/hysteresis/cooldown (§5.3) and the persistently-stuck counter (§3.4). Each item below is reintroduced **only if a measured oscillation or steady-state error in the proportional version demonstrably requires it** — and any such reintroduction is itself a governed `Proposal`, not a silent tuning change.

**Integral term (I).** A true integrator `I_d(k) = I_d(k−1) + Ki_d · e_d(k) · T_s` (backward-rectangular), to drive steady-state error to zero, added back into the control law as `u_d(k) = sat_d( P_d + I_d + D_d )`. Deferred because, over a vetoing actuator, it winds up (see anti-windup below), and over a biased judge it integrates the bias into a standing error; the persistently-stuck counter (§3.4) covers the one accumulative failure that matters without these hazards.

**Derivative term (D).** A derivative-on-measurement term `D_d(k) = −Kd_d · ( ŷ_d(k) − ŷ_d(k−1) ) / T_s`, acting on the low-pass-filtered measurement `ŷ` (never raw `y`, never the error `e`) to avoid derivative kick — with a constant setpoint `d e/dt = −d y/dt`, so the minus sign preserves direction while a setpoint step produces no impulsive "kick". Deferred because over LLM-derived sensors the filtered velocity is near-zero (a held slow-loop measurement contributes exactly zero), so it earns little while adding noise-amplification risk.

**Anti-windup.** With no integrator there is nothing to wind up. The combined **clamping** (`I_d ∈ [i_min, i_max]`) + **conditional** integration (freeze integration whenever the output is saturated *or* the council declined the dimension's previous advice) anti-windup scheme is deferred *with* the integral term, since it exists only to tame it. The rejected-advice-aware freeze is the Metatron-specific twist: the integrator must not punish the controller for the council's vetoes.

**Gain tuning beyond conservative defaults (Ziegler–Nichols).** A per-loop **relay / step experiment** in simulation to find each loop's ultimate gain `Ku` and period `Pu`, then a Ziegler–Nichols-style (heavily backed-off) gain assignment. Deferred: v1 uses the conservative `Kp` defaults of §3.5 tuned offline / in shadow (§5.6); the relay experiment is only worth running once an oscillation in the proportional loop is observed and needs damping.

**MIMO decoupling matrix `Γ`.** A non-trivial `Γ ∈ R^{D×D}` pre-compensation step `u' = Γ · u` (§3.6). At baseline `Γ = I` and cross-coupling is handled at the action layer and by council arbitration; a non-trivial `Γ` is adopted only if cross-coupling is *measured* to mis-steer the loop.

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
struct Gains { kp: f32, ki: f32, kd: f32 }   // only kp is active in v1; ki/kd are for the deferred I/D terms (§3.10)

struct Saturation { lo: f32, hi: f32 }    // actuator limits on u_d (default [-1, 1], §6.2)

struct Deadband { on: f32, off: f32 }     // hysteresis thresholds, off < on (§6.3)

struct Filter {                           // measurement low-pass (§6.4)
    alpha_base: f32,                      // EWMA base smoothing in (0,1]
    noise_adaptive: bool,                 // shrink alpha when sigma is high
}

struct AntiWindup {                       // DEFERRED with the integral term (§3.10); unused in v1
    i_min: f32, i_max: f32,               // integral clamp
    conditional: bool,                    // also stop integrating while saturated or while advice was declined
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
    stuck_threshold:  u32,                // N_d for the persistently-stuck counter (§3.4)
    cooldown_samples: u32,                // min samples between structural actions on d (§5.3)
    anti_windup: AntiWindup,              // DEFERRED with the integral term (§3.10)
    higher_is_better: bool,               // progress=true; cost/divergence/latency=false (for action mapping only)
}

/// Where the per-dimension setpoint r_d comes from. Resolved against the user target state in 06.
/// Resolution priority (§7.1): explicit user override (06) → guardrailed learned refinement → safe default.
enum SetpointSource {
    Trajectory(/* target completion vs. logical time */),   // progress
    Ceiling(f32),                                            // cost/divergence/latency (normalized cap)
    Fixed(f32),
}

// ===== Controller state (per dimension) =====
struct PidState {
    stuck:      u32,      // persistently-stuck counter (§3.4), the active integrator stand-in
    filt:       f32,      // ŷ_d(k), low-pass-filtered measurement
    last_u:     f32,      // for hysteresis / deadband
    firing:     bool,     // hysteresis latch
    cooldown:   u32,      // samples remaining before another structural action on d (§5.3)
    integral:   f32,      // I_d(k) — DEFERRED (§3.10); unused in v1
    last_filt:  f32,      // ŷ_d(k−1) for the deferred derivative (§3.10); unused in v1
}

// ===== Controller =====
struct Controller {
    registry: Vec<DimensionSpec>,         // the D dimensions, ordered
    t_s:      Duration,                   // sampling period T_s (§3.4)
    state:    Vec<PidState>,
    gamma:    Option<Matrix>,             // DEFERRED decoupling matrix Γ (§3.6, §3.10); None ⇒ identity (v1)
}

impl Controller {
    /// One control step. Pure w.r.t. the world-model: emits advice, writes nothing.
    fn step(&mut self, obs: &ObservabilityView, gov: &GovernanceView, k: u64)
        -> ControlBatch
    {
        // 1. measure → 2. filter → 3. error → 4. proportional term + persistently-stuck
        //    counter (§3.4) → 5. saturate → 6. deadband/hysteresis/cooldown gating
        //    → 7. action mapping (§3.7), incl. confident-collective-error escalation
        //    (ROB-01) and council-repair break-glass detection (ROB-04).
        //    Returns advisory actions only. (Integral/derivative/Γ are deferred — §3.10 —
        //    and not computed in v1.)
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

enum EscalationReason { StuckGoal, BudgetOverrun, Disagreement, ConfidentCollectiveError, LatencyBreach, Other }

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

## 5. Robustness engineering

> The proportional core is small; what makes it *safe* on a noisy, LLM-derived, deliberation-gated loop is the threshold and filtering machinery below. These mechanisms — deadband, hysteresis, cooldown, saturation, measurement filtering, and conservative gains — are the load-bearing robustness story and are mandatory, not optional. (The integral/derivative machinery a classical PID would lean on, and the anti-windup that tames it, is **deferred** — §3.10.) We make **no formal stability claim** for the real plant; the honest open item is §8a.

### 5.1 Integral anti-windup (deferred with the integral term)

Anti-windup exists only to tame an integrator, and the integral term is **deferred** (§3.10), so there is nothing to wind up in v1. The proportional core has no accumulating state; the persistently-stuck counter (§3.4) bounds itself — it resets the instant a dimension returns to tolerance, so it cannot over-correct on release. The rejected-advice-aware anti-windup scheme (clamp `I_d ∈ [i_min, i_max]`; freeze integration while the output is saturated *or* the council declined the dimension's previous advice) is documented in §3.10 and activates only if the integrator is reintroduced — the integrator must not punish the controller for the council's vetoes.

### 5.2 Actuator saturation

`u_d` is saturated to `[lo, hi]` (default `[−1, 1]`) because the *physical* action library is bounded: you can only spawn so many workers, widen the council so far, escalate once. Saturation is modeled explicitly (`sat_d`) so the proportional output cannot demand an action intensity the library cannot deliver (and, if the deferred integral is ever added, so it can be anti-windup-protected against it — §3.10). Action **intensity** (e.g. `n` workers) is a saturating function of `|u_d|`, with per-action hard caps enforced downstream by Guardians/consensus regardless of what the controller requests.

### 5.3 Deadband & hysteresis — don't thrash the org-chart

Reorganizing the team is **expensive and disruptive**: spawning/retiring agents, rewiring, re-planning all cost tokens, latency, and continuity. A controller that reacts to every tiny error will **flap** the org-chart (spawn-retire-spawn). Defenses:

- **Deadband `δ`:** no action unless `|u_d| ≥ δ_on_d`. Small errors are tolerated, not acted on.
- **Hysteresis:** once firing, keep acting until `|u_d|` falls below `δ_off_d < δ_on_d`. The on/off gap prevents chattering at the threshold.
- **Action cooldown:** a minimum number of samples between *structural* actions on the same dimension (a rate limiter on top of hysteresis), so even sustained borderline signals cannot churn the team faster than it can stabilize.

Deadband trades **tracking precision for stability** — exactly the right trade when the actuator is costly and the sensor is noisy.

### 5.4 Measurement filtering — surviving noisy LLM sensors

LLM judges and dispersion are **noisy sensors**: the same artifact judged twice can return different scalars. Feeding raw noise into the proportional term jitters the control vector across the deadband (and into the deferred derivative it would be amplified outright — the derivative of noise is enormous, which is part of why D is deferred, §3.10). Defenses:

- **Low-pass / EWMA smoothing:** `ŷ_d(k) = α_d · y_d(k) + (1−α_d) · ŷ_d(k−1)`. The proportional term and the stuck counter act on the filtered `ŷ`, never raw `y` (§3.4) — the standard noise defense.
- **Noise-adaptive `α`:** shrink `α_d` (trust the new sample less) when the estimator's self-reported `sigma` is high — judge-heavy dimensions get heavier filtering than metric-only ones. `cost`/`latency` (hard metrics) can run near `α ≈ 1`; `divergence`/judged-`progress` need small `α`.
- **Sampling-rate matching:** don't sample faster than the sensor produces *independent* information. Re-judging the same unchanged artifact every 30 s yields correlated noise, not signal; gate judge calls on actual artifact change.
- **Median-of-N judges:** for high-stakes dimensions, take several judge samples and use the median (a cheap robust estimator) — the same decorrelation logic the council uses (overview principle 3), applied to sensing.

Filtering trades **responsiveness for stability**: a smoothed sensor lags. Combined with conservative gains (§5.5), this is the correct bias for a system where an over-eager reorganization is worse than a slightly delayed one.

### 5.5 Why naive high gains are dangerous here

High gains give fast tracking in a clean loop. In Metatron they are **especially dangerous**:

1. **Loop delay is large and variable.** Actuation runs through deliberation (round-trips, possible blocking on the mailbox) and reconciliation. High gain + significant transport delay is the textbook recipe for **instability** (the correction arrives after the situation has already changed, so it pushes the wrong way → oscillation).
2. **The actuator is discrete, costly, and irreversible-ish.** Spawning then retiring a worker is not a free, smooth nudge; it burns budget and disrupts in-flight work. High gain converts sensor noise directly into **org-chart thrash**.
3. **The sensor is noisy and sometimes biased.** A noisy or biased judge corrupts even a proportional response; the deferred derivative would amplify the noise and the deferred integral would accumulate the bias into a standing error — among the reasons both are deferred (§3.10).
4. **The plant is non-stationary.** The "plant" (an LLM-agent ensemble) changes as agents are added, JIT-compiled, and as reputation shifts — its gain is not constant. A controller tuned hot for one regime is unstable in another.

The design therefore **biases low**: conservative proportional gains, heavy filtering on noisy dimensions, deadband, cooldowns. **Under-correcting is recoverable** (the error persists and the persistently-stuck counter eventually escalates it); **over-correcting** thrashes the org-chart and wastes budget. When in doubt, escalate to the user (a `ControlAction` in its own right) rather than crank the gain.

### 5.6 Tuning approach (no plant model)

There is no transfer function for "a council of LLM agents," so classic model-based tuning (pole placement, etc.) does not apply directly. The committed policy (§7.2) is **offline/shadow tuning first, then conservative online gain-scheduling keyed to regime — no MRAC in v1**; the pragmatic procedure that implements it:

1. **Dimensional bootstrap:** start from §3.5's conservative `Kp` defaults (deliberately low).
2. **Per-loop relay/step experiments (deferred, §3.10):** the Ziegler–Nichols-style *relay* experiment that drives a simulated plant to find each loop's ultimate gain `Ku` and period `Pu` is **deferred** — it is only worth running once a measured oscillation in the proportional loop needs damping (and would back off well below the ZN recommendation). v1 does not run it.
3. **Shadow mode:** run the controller live but **advisory-only with Guardians auto-declining** — log what it *would* have proposed, compare to what operators/council actually did, and tune to reduce false-positive actions (thrash) before false-negatives (missed corrections).
4. **Bandit/Bayesian gain search:** treat the gain vector as hyperparameters; optimize against an offline reward (goal completion per unit cost, penalized by org-chart churn) over recorded episodes.
5. **Conservatism gate:** never auto-raise gains in production; gain changes are themselves `Proposal`s subject to consensus (the controller's own tuning is governed).

### 5.7 Robustness summary (block view)

```
                  ┌─────────────── per-dimension SISO loop d (v1) ──────────────┐
  r_d ──►(−)──► e_d ─► [ Kp ]──────────────► [ sat ] ─► u_d ─► deadband/
          ▲      │                                             hysteresis/
          │      └─► [ stuck counter ≥ N_d ]────────────────► cooldown ─► action
          │                                                       ▲
          │     · · · DEFERRED (§3.10): [ Ki·Ts·Σ ] + anti-windup,│
          │     · · ·                   [ −Kd·Δ/Ts ] on ŷ, Γ ≠ I ·┘
          │
          └── ŷ_d ◄── [ low-pass α(σ) ] ◄── y_d ◄── Estimator ◄── (07 / judges / 02 dispersion)

   coupling across d handled at the action layer + council arbitration (Γ = I at baseline)
```

---

## 6. Worked micro-example (one sample)

Illustrative, `T_s = 30 s`, baseline gains. Suppose at sample `k`:

- `progress`: `r = 0.50` (target half-done by now), `ŷ = 0.30` → `e = +0.20` (behind). `progress` has been out of tolerance for many samples, so `stuck_progress` is near its threshold `N_progress`.
  `P = Kp·e = 0.6·0.20 = 0.12` → `u_progress` clears the deadband (positive = behind). Proportional push + a near-tripped stuck counter ⇒ **`SpawnAgents` and/or `EscalateToUser{StuckGoal}`**.
- `cost`: `r = 0.80`, `ŷ = 0.55` → `e = +0.25` (headroom, under budget). `u_cost > 0` but sign means "ahead of budget"; no relief action; possibly `RetireAgents` if strongly over-provisioned. Below deadband → **no action**.
- `divergence`: `r = 0.30`, raw dispersion samples `{0.55, 0.20, 0.50}`, `ŷ = 0.45` (heavy filtering, §5.4) → `e = −0.15` (too split). `|u| ≥ δ_on` → **`WidenCouncil` / `Decorrelate`** — and, because these are council-repair actions, the controller checks for deadlock and is ready to route them through break-glass if a split council cannot ratify them (§3.7, ROB-04). Heavy filtering keeps the spiky sensor from dominating the proportional term. *(A low `divergence` reading would not, by itself, be "healthy" — see the confident-collective-error check, §2.3 / §3.7.)*
- `latency`: `r = 0.70`, `ŷ = 0.40` → `e = +0.30` (responsive, fine). No action.

`ControlBatch{k, error = {progress:+0.20, cost:+0.25, divergence:−0.15, latency:+0.30}, actions: [SpawnAgents|Escalate(progress), WidenCouncil(divergence)], conflicts: []}` → handed to Guardians → typed `Proposal`s → consensus.

---

## 7. Resolved decisions

> A design review settled the following prior open questions. Each is now **committed, normative design** — not a metaphor and not a TODO — and constrains the section it names. The few items that remain genuinely open are in §8.

1. **Setpoints — safe defaults + override + learn** *(was Open Q5; locked).* The controller **ships conservative default setpoints** per dimension (a default budget ceiling, latency cap, divergence tolerance, and progress trajectory) so the system is usable when the user supplies nothing. The user **may override any setpoint explicitly** via the Interaction plane (`06`). Beyond that, the controller **refines setpoints from revealed preference** over time — observed accept / reject / escalation behavior — with **guardrails that bound how far a learned setpoint may move from its safe default**. `SetpointSource` (§4) resolves in strict priority order: **explicit user override → guardrailed learned refinement → safe default**. (The guardrail specification itself remains open: §8c.)

2. **Tuning — offline/shadow first, then conservative online gain-scheduling** *(was Open Q1).* The active `Kp` gains are tuned **offline / in shadow mode on recorded traces** (§5.6) before any online use. In production the controller uses **gain-scheduling keyed to regime** — *exploration* vs. *convergence* — with **slow, bounded adaptation** only. **No MRAC in v1.** The Ziegler–Nichols relay experiment is **deferred** (§3.10) until a measured oscillation needs damping. Whether offline + gain-scheduling is ultimately sufficient, or genuine adaptive control is eventually required, remains a research question (§8b).

3. **SISO + action-layer coupling for v1; `Γ` is a deferred upgrade path** *(was Open Q2).* v1 ships **`D` decoupled SISO loops with identity decoupling matrix `Γ = I`** and handles cross-coupling at the action layer (§3.6) — chosen for interpretability and auditability. A **non-trivial decoupling matrix `Γ`** is **deferred** (§3.10) — a documented upgrade path adopted only if cross-coupling is *measured* to mis-steer the loop.

4. **Normalization — per-dimension `[0,1]` + per-dimension gains; common utility only at action selection** *(was Open Q3).* Each dimension stays on its own `[0,1]` scale with its own gains (§3.3); dimensions are never made mutually comparable in the control law. They are mapped onto a common **"expected impact on goal-completion-per-cost"** utility **only at the action-selection layer** (§3.7), where antagonistic actions must be weighed. Genuinely **incomparable trade-offs remain a council value judgment** and are **escalated**, not resolved numerically.

5. **Judge bias — calibrate, subtract** *(was Open Q4).* LLM judges are **calibrated against ground truth** using the shared reputation machinery (`08`). Each judge's **bias is estimated from its ground-truth residuals and subtracted** from its raw output (§3.2). Because the integral term is **deferred** (§3.10), the v1 proportional core never integrates residual bias into a standing steady-state error in the first place; the integral-clamp defense returns *with* the integral if it is ever reintroduced. **Sentinels (`07`)** watch for judge drift. (Filtering, §5.4, handles *variance*; this decision handles *bias*.)

6. **Multi-rate sampling** *(was Open Q7).* The loop is **multi-rate** (§3.4): a **fast loop** samples hard metrics at `T_s = 30 s`; a **slow loop** samples LLM-judged dimensions at **5–10× `T_s`**, with **hold-last-value** between judge samples. The control law reflects this structure (during a hold the proportional term and the persistently-stuck counter keep acting on the held error; the deferred derivative would contribute exactly zero).

7. **Reputation / control time-scale separation** *(was Open Q9).* The reputation loop (`08`) **adapts slowly** — low learning rate — relative to control `T_s`, and is treated as **quasi-static within a control horizon**. This enforced **time-scale separation** is what keeps the nested reputation → `Decision.dispersion` → `divergence` loop from resonating with the control loop.

8. **Refusing actuator — decay influence + distinct disagreement notification** *(was Open Q6).* When the controller is **systematically overruled** by consensus, it (a) **decays its own influence** and (b) raises a **distinct "controller-vs-council disagreement" notification** to the user via `06` (separate from ordinary escalations). This is part of the **tiered-liveness response** to a refusing actuator, and complements the council-repair break-glass path of §3.7 (and, if the deferred integral is ever reintroduced, its rejected-advice-aware anti-windup, §3.10).

9. **Disagreement ≠ wrongness; escalate on confident collective error** *(ROB-01).* The `divergence` sensor measures council *disagreement*, not *correctness*; a correlated, confidently-wrong council emits *low* dispersion. The controller therefore **never reads health from low dispersion alone** and **escalates** (decorrelated red-team lane + `EscalateToUser{ConfidentCollectiveError}`) on the composite **low dispersion + low verification coverage + high subjective residue**, where the verification-coverage metric is owned and surfaced by `07` (§2.3, §3.7).

10. **Council-repair has a break-glass actuator** *(ROB-04).* Council-repair actions (`WidenCouncil`, `Decorrelate`, recompose) cannot depend on the broken quorum to ratify them. The controller **detects deadlock/split** and routes repair through the **founder-threshold break-glass / human-escalation path** defined in `02`/`08`, so the steering loop has a working actuator in the degraded case (§3.7).

---

## 8. Open questions & ambiguities

> Parked per overview §9. The design review (§7) closed most prior items; these three are genuinely unresolved.

a. **No formal stability proof for the real plant** *(research).* We make **no formal stability claim**. The proportional core leans on conservative gains + filtering + deadband/hysteresis/cooldown + time-scale separation for *practical* well-behavedness, and the strongest argument we can currently make is a **heuristic small-gain / passivity argument over a *simplified surrogate* plant**. Open: whether any **tractable formal stability proof for the real, nonstationary plant** — an LLM-agent ensemble whose gain shifts as agents are added, JIT-compiled, and re-weighted (§5.5.4) — is achievable at all, rather than only for the surrogate.

b. **Is offline + gain-scheduling tuning sufficient?** *(research).* §7.2 commits to offline/shadow tuning plus conservative online gain-scheduling and rules out MRAC for v1. Open: whether that is **ultimately sufficient**, or whether **genuine adaptive control** is eventually required for the nonstationary plant — and, if so, how to keep *adaptation itself* stable.

c. **Guardrails on learned setpoints** *(design).* §7.1 commits to refining setpoints from revealed preference within bounds. Open: the concrete **guardrails** that keep revealed-preference learning from **drifting setpoints into unsafe targets** — e.g. a learned budget ceiling creeping unboundedly upward, or a divergence tolerance learned so high the council's disagreement stops registering at all.

---

## 9. Relationships to other specs

| Spec | Relationship |
|------|-------------|
| `00-overview.md` | Canonical anchor. `ErrorVector`, `Proposal`, `Decision`, `WorldModel`, `Layer`, `AgentId`, the closed-loop diagram (§5), and principle 5 are defined there and reused verbatim. |
| `01-state-model.md` | The controller never writes state; enacted control actions become `Commit`s here via the actuator path. `Proposal.derived_from` links a commit back to the `ControlAction` that advised it. Logical time / sampling alignment is defined there. |
| `02-consensus.md` | **Bidirectional.** *Input:* `Decision.dispersion` is the `divergence` sensor (§3.2) — the council's disagreement *is* a measured signal, but it measures *disagreement, not wrongness* (ROB-01, §2.3). *Output:* every control action becomes a `Proposal` that runs the consensus protocol; consensus may veto or reshape it (§3.8). The controller advises; consensus disposes. *Degraded case:* council-repair actions cannot pass a broken quorum, so the controller detects deadlock/split and triggers the **founder break-glass / human-escalation** recovery path defined here and in `08` (ROB-04, §3.7). |
| `04-runtime-and-harness.md` | The plant, and the home of the **reconciliation (execution) loop**. The steering loop (this spec) is **nested around** it: the reconciliation loop owns convergence of *reality → committed desired-state*; steering owns convergence of *desired-state → user target* (§1). "Reconcile/reconciliation" is reserved for `04`. `SpawnAgents`/`RetireAgents`/`Rewire` actions ultimately become reconcile plans here. |
| `05-agent-jit.md` | `TriggerJit` and `Deopt` are control actions (cost/latency relief; trap-rate response). Sentinel-measured trap rates can feed the `divergence`/cost estimators. |
| `06-interaction-and-mailbox.md` | **Source of the setpoint.** The user's target state defines `r_d` per dimension via `SetpointSource`. Guardians are the actuator: they receive the `ControlBatch` and author proposals. `EscalateToUser` actions surface through the mailbox and may *block* affected work (overview §5). |
| `07-observability.md` | **The sensor substrate.** Hard metrics for every estimator (spend, wall-clock, task-node closure, trap/retry rates, staleness). `07` also **owns the verification-coverage metric** and the **low-dispersion/low-coverage composite** the controller escalates on (ROB-01, §2.3/§3.7) — the controller reads it, it does not compute it. The controller logs its `ErrorVector` and `ControlBatch` back to `07` for auditability. |
| `08-trust-and-security.md` | Reputation calibrates the LLM judges and the council whose dispersion feeds `divergence`; Sentinel off-protocol rates optionally feed the `divergence` estimator (§3.2). Judge-bias calibration — **calibrate, subtract** (§7.5) — ties in here, as does reputation/control time-scale separation (§7.7). The **founder-threshold break-glass** recovery path for a deadlocked council (ROB-04, §3.7) is rooted in the threshold-of-founders trust root defined here. |
```
