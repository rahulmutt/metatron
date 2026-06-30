# Metatron — Runtime & Harness (the Execution plane)

> **Status:** Research architecture specification (v0.1)
> **Audience:** Implementers of the Execution plane.
> **Scope:** This document specifies the **Execution plane** of Metatron — the layer that turns *desired agents* (the configuration layer of the world-model, from `01-state-model.md`) into *actual running agents*, and runs each agent's work through an **agentic harness** behind a uniform contract. It owns the `AgentHarness` and `ExecutionBackend` contracts named in `00-overview.md §7`, their two reference backends (Rust actors, Kubernetes CRDs), the **reconcile loop**, agent lifecycle and supervision, and the least-privilege hooks that scope a harness's permissions.
> **Excludes:** JIT tiering (Tier 0/1/2, traps, deopt, the Compiler agent) is specified in `05-agent-jit.md`. This spec defines only Tier-0 execution and the seams the JIT plugs into. The full threat model is `08-trust-and-security.md`; this spec defines only the *hooks* it consumes.
> **Anchor:** Where this spec and `00-overview.md` disagree on vocabulary or a shared type, the overview wins. All canonical types (`WorldModel`, `AgentHarness`, `ExecutionBackend`, `Tier`, `AgentId`, `Hash`, …) are imported from `00-overview.md §7`, not redefined.

---

## 1. Purpose

The Execution plane answers one question: **given that the Genesis council has decided some set of agents should exist and be wired a certain way, how do those agents actually run, and how does their work get done?**

Metatron's central and deliberately unusual commitment is this:

> **The execution unit is an agentic *harness*, not a raw model call.**

A raw orchestrator treats the LLM as the primitive — it owns the prompt, the tool-call loop, the file edits, the planning, the retries. Metatron does **not**. The primitive Metatron schedules is a **complete agentic tool** — Claude Code, Codex CLI, Cursor, Aider, and their successors — *each of which already is a full agentic loop*: its own model, its own tool use, its own file editing, its own planning, its own intra-session retry. Those tools are mature, independently evolving, and individually competent. Reimplementing their inner loop would be both wasteful and fragile.

Metatron is therefore the **orchestrator *above* harnesses**. It does not reach inside a harness's loop, does not re-prompt mid-session, does not own its tool calls. It hands a harness a well-specified job, lets the harness run its own loop to completion (or to a checkpoint/abort), and consumes a **structured result**. This is the same architectural move Kubernetes makes with container runtimes: K8s does not implement a container; it defines the **CRI** seam and schedules opaque runtimes behind it. `AgentHarness` is Metatron's analogue of the CRI, and `ExecutionBackend` is its analogue of the kubelet+runtime substrate.

Concretely, the Execution plane must:

1. **Define what an "agent" is at runtime.** An agent in Metatron is **`role + goal + policy` bound to an `AgentHarness` adapter** (overview §1, §3). The role/goal/policy come from the configuration layer of the world-model; the harness adapter is how that agent *acts*.
2. **Make heterogeneous harnesses interchangeable** behind one contract, via **capability negotiation**: a guaranteed *minimum* every adapter satisfies, plus *optional* richer telemetry that callers must treat as best-effort.
3. **Make *where* agents run pluggable** behind `ExecutionBackend`, with two contrasting reference implementations — in-process Rust actors, and Kubernetes CRDs — so the same orchestration logic runs on a laptop or a cluster.
4. **Reconcile** actual running agents toward the desired configuration, Kubernetes-style: spawn, retire, rewire, restart on failure.
5. **Supervise** agent lifecycle and failure, and **scope** each agent's permissions to least privilege derived from its role.

What this plane is **not** responsible for: deciding *which* agents should exist (that is consensus, `02`), deciding *what good looks like* (that is the control loop, `03`), or *recording* the decision (that is the state plane, `01`). The Execution plane is a faithful, observable **actuator**. It is the "plant" in the control-theoretic framing of overview §1.3 / §5.

---

## 2. Concepts

### 2.1 Harness vs. model vs. agent

Three terms that are easy to conflate; this spec keeps them strictly separate.

| Term | What it is | Who owns its loop |
|------|------------|-------------------|
| **Model** | A weights endpoint that maps tokens→tokens. | Nobody in Metatron — it lives *inside* a harness. |
| **Harness** | A complete agentic tool (Claude Code, Codex CLI, Cursor, Aider). Wraps a model with tool use, file editing, planning, intra-session retry. A black box to Metatron. | The harness vendor. |
| **Agent** | A Metatron-level construct: `role + goal + policy` bound to one `AgentHarness` adapter, with an identity (`AgentId`), a reputation, a permission scope, and a JIT `Tier`. | Metatron (the orchestrator above the harness). |

> **The boundary is load-bearing.** Metatron drives a harness as a black box: in, a job; out, a result. It never injects a turn mid-session. This is what lets harnesses be **decorrelated, heterogeneous voters/executors** (overview principle §6.3): if every Worker ran the *same* re-implemented loop, their failures would correlate. Different harnesses with different models, prompts, and scaffolds fail *independently*, which is precisely the property the rest of Metatron's nondeterminism-taming protocol exploits.

### 2.2 The execution unit and its identity

An agent's **runtime identity** is its `AgentId` (a public-key-derived `Hash`, from overview §7 / `08`). The *same* logical role may, over its life, be served by different harness processes (a crash, a restart, a backend migration) — but the `AgentId` is stable, because it is derived from the configuration-layer node that declared the agent, not from the process. The backend's job (the reconcile loop, §4) is to keep *some* live actor/pod faithfully embodying each desired `AgentId`.

### 2.3 Capability negotiation

Harnesses differ in what they expose. Claude Code can emit a structured stream of tool invocations, file diffs, and token accounting; a thin wrapper around some CLI may expose only a final unified diff and an exit code. Metatron must run **both** without the orchestration logic special-casing either.

The resolution is a **capability set** (`CapabilitySet`) that every adapter declares via `AgentHarness::capabilities()`:

- A **mandatory minimum** (§3.3) every adapter MUST satisfy, or it is not a valid harness.
- **Optional capabilities** (structured tool logs, per-step diffs, token/cost accounting, mid-run progress, cooperative checkpoint/preempt) that, if present, the Observability plane (`07`) and the JIT plane (`05`) consume opportunistically.

The contract is: **callers program against the minimum and *feature-detect* the rest.** The Observability plane MUST degrade gracefully (overview's "monitoring is first-class" principle is honored as *best-effort, never blocking*): a harness that exposes only a final diff still produces a valid `HarnessResult`; it simply yields a coarser trace. Telemetry richness is a property of the harness, not a precondition for running it.

### 2.4 Execution backend

Where agents *run* is abstracted behind `ExecutionBackend`. Two reference styles, intentionally chosen to be near-opposite points in the design space so the extension seam is proven against both (§4.4):

- **`RustActorBackend`** — agents are **actors** in an in-process (or single-node) Rust actor system: mailboxes, message passing, supervision trees, fault isolation. Low latency, no external dependency, ideal for local/dev and tightly-coupled teams.
- **`KubernetesCrdBackend`** — agents are **Custom Resources**; a controller/operator reconciles them; the cluster handles scheduling, restarts, scaling, multi-node. Heavier, but inherits the entire Kubernetes operational ecosystem.

Both implement the *same* reconcile contract. The orchestration plane above never knows which is mounted.

### 2.5 Reconciliation

The Execution plane is **declarative**. The configuration layer of the world-model is the **desired** set of agents and wiring (overview §3: "the taxonomy *is* state"). The backend continuously drives **actual** running agents toward desired, exactly like a Kubernetes controller drives Pods toward a Deployment spec. The diff between desired and actual becomes a **`ReconcilePlan`** of lifecycle actions (spawn / retire / rewire / restart). This is the same reconciliation pattern the whole system uses (overview §5), here applied to *processes* rather than *proposals*.

### 2.6 Sessions, tasks, and the work

A **TaskSpec** is the unit of work handed to a harness for one **session**. An agent (a long-lived role) may run *many* sessions over its life — each session is one invocation of its bound harness's agentic loop on one `TaskSpec`. Sessions are where reconciliation and "the work" meet the hardest open problems: a session, once started, runs a vendor loop that may not be cleanly preemptible (§9).

---

## 3. Detailed design — the harness contract

### 3.1 The `AgentHarness` trait

Importing the canonical shape from overview §7 and elaborating:

```rust
/// Uniform contract over agentic harnesses (Claude Code, Codex CLI, Cursor, Aider, ...).
/// An adapter is the thin shim that makes a specific tool satisfy this contract.
trait AgentHarness: Send + Sync {
    /// Static-ish description of what this harness can expose. Negotiated once at
    /// adapter registration and refreshable. Telemetry capabilities are best-effort.
    fn capabilities(&self) -> CapabilitySet;

    /// Identity/version of the underlying tool, for reputation attribution and
    /// decorrelation accounting (which model/scaffold produced this result).
    fn descriptor(&self) -> HarnessDescriptor;

    /// Run ONE agentic session: hand the tool a job + workspace + permitted tools +
    /// context, let its own loop run to completion/checkpoint/abort, return results.
    /// Metatron does NOT re-enter the loop; it awaits this future and consumes the result.
    fn run(&self, task: TaskSpec, ctx: Context) -> BoxFuture<'_, HarnessResult>;

    /// OPTIONAL cooperative control. Default impls return `Unsupported`.
    /// Whether these do anything is gated by CapabilitySet (see §9 on preemption).
    fn checkpoint(&self, _session: SessionId) -> BoxFuture<'_, Result<CheckpointRef, CtlErr>> {
        ready(Err(CtlErr::Unsupported)).boxed()
    }
    fn cancel(&self, _session: SessionId, _mode: CancelMode) -> BoxFuture<'_, Result<(), CtlErr>> {
        ready(Err(CtlErr::Unsupported)).boxed()
    }

    /// OPTIONAL live telemetry. If `CapabilitySet::streams_progress`, the harness
    /// pushes events here during the run; otherwise this is never called and the
    /// Observability plane relies solely on the final HarnessResult.
    fn subscribe(&self, _session: SessionId, _sink: TelemetrySink) -> Result<(), CtlErr> {
        Err(CtlErr::Unsupported)
    }
}
```

Design notes:

- **`run` is the whole loop.** It returns *once*, with everything the orchestrator needs. There is no `step()`; Metatron never single-steps a harness. This is the architectural firewall between Metatron's loop and the harness's loop.
- **Everything past `run` + `capabilities` is optional** and default-`Unsupported`. A valid adapter can be ~30 lines: shell out to a CLI, parse its final diff, fill a `HarnessResult`. Richness is additive.
- **`descriptor()` feeds decorrelation and reputation.** Knowing *which* harness/model produced a result lets `02`/`08` attribute reputation and lets the council avoid stacking correlated voters (overview §6.3).

### 3.2 `TaskSpec`, `Context`, `HarnessResult`

```rust
/// The job handed to a harness for one session. Fully specified up front because
/// Metatron will not interact mid-loop.
struct TaskSpec {
    session_id: SessionId,
    agent: AgentId,              // which Metatron agent this session embodies
    role: RoleRef,              // role from the configuration layer (scopes permissions)
    goal: GoalSpec,             // the sub-goal assigned by consensus (progress layer ref)
    instructions: Text,         // natural-language brief for the harness's own planner
    inputs: Vec<ArtifactRef>,   // content-addressed inputs (prior diffs, docs, specs)
    permitted_tools: ToolGrant, // capability-scoped allow-list (see §6); least privilege
    workspace: WorkspaceSpec,   // the filesystem/repo sandbox the session runs in (§6.3)
    budget: Budget,             // wall-clock, token, and cost ceilings (best-effort enforced)
    acceptance: Vec<Check>,     // machine-checkable success criteria, determinism-first (§3.5)
    deadline: Option<LogicalTime>,
}

/// Ambient context the harness may use but does not own.
struct Context {
    world_view: WorldView,      // read-only projection of relevant world-model slices (01)
    memory: Option<MemoryRef>,  // optional retrieval handle (cross-session memory; see OQ-7)
    correlation: TraceContext,  // ties this session into the observability trace tree (07)
    peers: Vec<AgentId>,        // wired collaborators (from the configuration layer wiring)
    tier_hint: Tier,            // current JIT tier of this agent (05); Tier0 here, others in 05
}

/// What a session returns. The UNIFORM result type all harnesses normalize into.
struct HarnessResult {
    session_id: SessionId,
    outcome: Outcome,           // Completed | Blocked | Failed | Aborted | TimedOut
    // --- mandatory minimum (every adapter fills these) ---
    diff: Option<UnifiedDiff>,  // the change to the workspace, if any (None for read-only work)
    artifacts: Vec<ArtifactRef>,// content-addressed outputs produced
    report: StructuredReport,   // typed, schema-validated summary (NOT free text into SoR)
    check_results: Vec<CheckOutcome>, // results of running `acceptance` checks (det.-first)
    // --- optional / best-effort (presence implied by CapabilitySet) ---
    telemetry: Telemetry,       // may be Telemetry::Sparse (final-diff-only) .. ::Rich
    usage: Option<Usage>,       // tokens, cost, tool-call counts — None if harness can't report
    checkpoint: Option<CheckpointRef>, // resumable state, if the harness supports it
}

enum Outcome {
    Completed,                  // harness finished; see check_results for success/failure
    Blocked { question: Text }, // needs a human/ambiguity answer -> Guardian/mailbox (06)
    Failed { error: Text },     // harness errored internally
    Aborted,                    // cancelled by reconcile/supervisor
    TimedOut,                   // exceeded budget/deadline
}
```

Key invariants:

- **`report` is typed.** Per overview principle §6.1 ("constrain the output space"), a harness's free-text musings never enter the system of record. The adapter is responsible for projecting whatever the tool emits into a schema-valid `StructuredReport`. Free text survives only as advisory `rationale`/log payloads in the Observability plane.
- **`Outcome::Blocked` is the bridge to the Interaction plane.** When a harness determines it genuinely cannot proceed without an answer, the agent surfaces a `Blocked` outcome; the orchestration above routes it to a Guardian, which may open a mailbox question (`06`), and *the affected work blocks until answered* (overview §5). The Execution plane does not invent answers.
- **`check_results` are determinism-first.** Acceptance checks (tests, compiles, lints, schema validation) are run by Metatron *around* the harness, not trusted from the harness's own say-so. "Did it pass" is *checked, not voted on* (overview §6.2).

### 3.3 `CapabilitySet` — the negotiated minimum

```rust
struct CapabilitySet {
    // ---- MANDATORY MINIMUM: every valid adapter MUST guarantee all of these ----
    // (capabilities() returning a set that omits any mandatory bit is a registration error)
    minimum: MinimumGuarantees,

    // ---- OPTIONAL: feature-detected; consumers degrade gracefully if absent ----
    structured_tool_log: bool,  // emits per-tool-call records, not just a final diff
    per_step_diffs: bool,       // intermediate diffs, not just the cumulative one
    usage_accounting: bool,     // can report tokens / cost / tool counts
    streams_progress: bool,     // pushes live events to subscribe()
    cooperative_checkpoint: bool, // checkpoint() actually persists resumable state
    cooperative_cancel: bool,   // cancel(Graceful) actually unwinds cleanly
    deterministic_replay: bool, // same TaskSpec+seed -> same result (rare; aids JIT, 05)
}

/// The floor. If a tool cannot meet this, it cannot be a Metatron harness.
struct MinimumGuarantees {
    // 1. Accepts a TaskSpec and runs to a terminal Outcome (no infinite ambiguity).
    // 2. Runs confined to the provided WorkspaceSpec and ToolGrant (sandbox-respecting).
    // 3. Returns a final workspace state expressible as an UnifiedDiff (possibly empty).
    // 4. Returns a schema-valid StructuredReport (typed, not free text).
    // 5. Honors hard cancel: cancel(Forceful) terminates the session bounded-time.
    // 6. Surfaces "I am blocked / I need input" rather than fabricating, as Outcome::Blocked.
    _marker: (),
}
```

The split is the heart of the design decision on capability negotiation:

> **Program against `minimum`; feature-detect the rest.** No orchestration code may *require* an optional capability. Anything that wants `structured_tool_log` must have a graceful fallback for harnesses that only give a final diff.

#### Graceful degradation table (Observability plane, `07`)

| If harness lacks… | …Observability degrades to… |
|-------------------|------------------------------|
| `structured_tool_log` | reconstruct a coarse step trace from the final diff + report; mark trace `fidelity = Coarse`. |
| `per_step_diffs` | single cumulative diff node; no intra-session timeline. |
| `usage_accounting` | cost/token metrics are `Unknown`; cost-control (PID `cost` dim, `03`) falls back to *wall-clock × tier price model* estimates (see OQ-4). |
| `streams_progress` | no live progress; status is inferred from session liveness + final result only. |
| `cooperative_checkpoint`/`cancel` | reconciliation must treat the session as **non-preemptible**; uses forceful cancel + idempotent retry (§9, OQ-3). |

Telemetry being best-effort is **explicit and load-bearing**, not an oversight: it is what lets Metatron orchestrate *tomorrow's* harnesses, which we cannot specify today.

### 3.4 Mapping heterogeneous harnesses into the uniform result

The adapter is where the impedance mismatch is absorbed. Reference mappings:

| Harness | `diff` | `report` | `telemetry` | `usage` |
|---------|--------|----------|-------------|---------|
| **Claude Code** (rich) | from its file-edit stream | projected from its structured turn log | `Rich` (tool calls, files, steps) | full token/cost |
| **Codex CLI** | from git working tree at session end | projected from final summary | `Medium` | tokens if exposed |
| **Aider** | from its commit/diff output | parsed from its edit-block log | `Medium` | model usage if logged |
| **Generic CLI wrapper** | `git diff` of workspace before/after | minimal: outcome + check_results only | `Sparse` | `None` |

The **generic CLI wrapper** is the existence proof of the minimum: *any* tool that edits a workspace and exits can be wrapped by diffing the workspace and synthesizing a `StructuredReport` from the exit status and acceptance checks. How to faithfully project *partial* vendor telemetry into the uniform shape — and how much to trust a self-reported report vs. independently re-derive it — is parked in OQ-1.

### 3.5 Acceptance checks (determinism-first verification of work)

`TaskSpec::acceptance` carries machine-checkable `Check`s that Metatron runs *after* (and where cheap, *around*) the session, independent of the harness's own claims:

```rust
enum Check {
    Command { cmd: String, expect: ExitExpectation },  // tests, build, lint
    SchemaValid { artifact: ArtifactRef, schema: SchemaRef },
    DiffConstraint(DiffPredicate),  // e.g. "touches only paths under src/foo", "no secrets"
    Custom(CheckFnRef),
}
```

These results (`CheckOutcome`) flow back as ground-truth signal: into reputation updates (`08`), into the PID `progress` dimension (`03`), and into the JIT's stability detection (`05`). This is the determinism-first principle applied at the execution boundary: *whatever can be checked is checked, not voted on* (overview §6.2).

---

## 4. Detailed design — backends & reconciliation

### 4.1 The `ExecutionBackend` trait

```rust
/// Where agents actually run. The orchestration plane above is agnostic to which
/// concrete backend is mounted.
trait ExecutionBackend: Send + Sync {
    /// Compute (don't apply) the plan to drive actual -> desired. Pure-ish: reads
    /// actual runtime state + desired config layer, emits a plan. Idempotent.
    fn reconcile(&self, desired: &WorldModel, actual: &ActualState) -> ReconcilePlan;

    /// Apply one plan. Returns per-action results; partial failure is normal and
    /// is simply re-reconciled on the next tick (no all-or-nothing transaction).
    fn apply(&self, plan: ReconcilePlan) -> BoxFuture<'_, Vec<ActionResult>>;

    /// Observe what is actually running, so the next reconcile has a fresh `actual`.
    fn observe(&self) -> BoxFuture<'_, ActualState>;

    /// Resolve the bound harness adapter for a given agent (role -> adapter binding).
    fn harness_for(&self, agent: AgentId) -> Arc<dyn AgentHarness>;
}
```

Note `reconcile` matches the canonical signature in overview §7 (`desired`/`actual` world-models); `ActualState` is the runtime-observed projection of the configuration layer plus liveness/health that only the backend can see.

### 4.2 `ReconcilePlan` and the reconcile loop

```rust
struct ReconcilePlan {
    actions: Vec<LifecycleAction>,
    generation: u64,            // monotone; ties a plan to the desired-state version it targets
}

enum LifecycleAction {
    Spawn   { agent: AgentId, role: RoleRef, harness: HarnessBinding, scope: PermissionScope },
    Retire  { agent: AgentId, drain: DrainPolicy },   // graceful stop after inflight session
    Rewire  { agent: AgentId, peers: Vec<AgentId> },  // change wiring without restart
    Restart { agent: AgentId, reason: RestartReason },// supervision response to failure
    Migrate { agent: AgentId, to: PlacementHint },    // backend-internal relocation
    NoOp    { agent: AgentId },                        // converged; nothing to do
}
```

**The reconcile loop** (run by the backend, ticked by an event or a timer):

```
loop {
    desired = world_model.configuration_layer()      // from 01; the council's accepted intent
    actual  = backend.observe().await                // what is really running
    plan    = backend.reconcile(&desired, &actual)   // pure diff -> actions
    results = backend.apply(plan).await              // best-effort; partial failure OK
    emit_telemetry(results)                          // to 07; feeds Sentinels + PID
    // converged when reconcile() yields all NoOp; otherwise next tick re-drives the gap
}
```

Properties (deliberately mirroring Kubernetes controllers, and overview §5):

- **Declarative & level-triggered.** Reconcile always recomputes from current desired-vs-actual; it never relies on having seen every intermediate edge. A missed event is harmless; the next tick corrects it.
- **Idempotent.** Re-running a plan that's already partly applied is safe; actions are keyed by `AgentId` + `generation`.
- **Convergent, not transactional.** Partial failure is not rolled back; it is simply observed and re-reconciled. There is no global lock over the fleet.
- **Desired state is authoritative and *consensus-owned*.** The Execution plane never edits desired state. "Spawn a worker," "rewire the team," "retire this agent" are **typed diffs decided by consensus** (`02`) and committed (`01`); the backend only *actuates* them. This is the firewall between *deciding* and *doing*.

### 4.3 Agent lifecycle & supervision

```
   (desired says agent X exists)
            │ Spawn
            ▼
        Provisioning ──(workspace+scope ready)──▶ Starting ──▶ Idle
            │                                                   │ assign TaskSpec
            │                                                   ▼
            │                                                Running ──(HarnessResult)──▶ Idle
            │                                       ┌───────────┤
            │                          Blocked◀─────┘  Failed / TimedOut
            │                          (mailbox 06)         │
            │                                               ▼  supervision policy
            │                                      Restart / Backoff / Escalate
            ▼ Retire (desired drops X)
        Draining ──(inflight session ends or is cancelled)──▶ Terminated
```

**Supervision** differs by backend but obeys one shared policy surface:

```rust
struct SupervisionPolicy {
    on_failure: RestartStrategy,    // OneForOne | OneForAll | RestForOne | Escalate
    max_restarts: u32,              // within `window`; exceeding it escalates upward
    window: Duration,
    backoff: Backoff,               // exponential, capped
    escalate_to: Option<AgentId>,   // supervising agent / kernel; ultimately the council
}
```

- A **failed session** (`Outcome::Failed`/`TimedOut`) is a *local* event: the supervisor restarts the agent's session per policy (idempotent — see §9 on partial side effects).
- A **persistently failing agent** that blows its restart budget **escalates**: the failure becomes observable signal (`07`), can drive a Sentinel detection and a reputation hit (`08`), and ultimately surfaces as a control signal that the **council** may respond to by *retiring or rewiring* the agent (a `02` proposal) — closing back into the governance loop. The Execution plane never *decides* to remove an agent from desired state; it surfaces evidence and lets governance decide.
- **`OneForAll`/`RestForOne`** matter for *wired teams*: if a coordinator agent dies, dependent workers may need coordinated restart, exactly as in actor supervision trees.

### 4.4 Reference backend A — `RustActorBackend`

Agents are actors in an in-process Rust actor runtime.

```rust
struct RustActorBackend {
    system: ActorSystem,                  // root supervisor + scheduler
    agents: DashMap<AgentId, ActorHandle>,// AgentId -> live actor
    registry: HarnessRegistry,            // role -> Arc<dyn AgentHarness>
    sandboxer: Arc<dyn Sandbox>,          // process/fs isolation for harness sessions (§6)
}
```

- **Embodiment:** each desired agent is an actor with a **mailbox**; `TaskSpec`s arrive as messages; the actor invokes its bound harness's `run` (typically on a blocking-task pool, since harness sessions are long and may spawn subprocesses) and replies with `HarnessResult`.
- **Supervision:** native **supervision trees** — a parent supervisor restarts children per `SupervisionPolicy`; `OneForAll` is natural here.
- **Fault isolation:** a panicking actor is contained by its supervisor; a *harness subprocess* crash is isolated by the OS process boundary the sandboxer establishes (§6.3). Memory faults inside a harness CLI cannot corrupt the Metatron process because the harness runs out-of-process.
- **Reconcile:** `Spawn` = start actor + provision workspace + apply scope; `Retire` = drain mailbox then stop; `Rewire` = update the actor's `peers` set in place (no restart); `Restart` = supervisor restart with backoff.
- **Placement:** single process / single node (or a small actor cluster). No external scheduler.

### 4.5 Reference backend B — `KubernetesCrdBackend`

Agents are **Custom Resources**; a controller reconciles them; the cluster runs them.

```yaml
# CRD (illustrative) — desired state mirrors the configuration layer
apiVersion: metatron.dev/v1
kind: Agent
metadata: { name: worker-7f3a, labels: { role: worker } }
spec:
  agentId: "blake3:…"
  role: worker
  goalRef: "progress://node/…"
  harness: { adapter: claude-code, version: "…" }
  permissionScope: { ... }          # derived from role; least privilege (§6)
  wiring: { peers: [ "agent/worker-91bd" ] }
  budget: { wallClock: 30m, cost: $2.00 }
status:
  phase: Running                    # actual state, written by the controller
  session: { id: …, outcome: … }
  conditions: [ ... ]
```

```rust
struct KubernetesCrdBackend {
    client: KubeClient,
    controller: ControllerRuntime,    // watch+reconcile loop over Agent CRs
    registry: HarnessRegistry,
}
```

- **Embodiment:** the controller materializes each `Agent` CR as a **Pod** (or Job) whose container runs the bound harness adapter; the harness session executes inside that Pod's sandbox.
- **Reconciliation is the cluster's:** Metatron's reconcile loop largely *projects desired config → CRs*; Kubernetes' own controllers + the Agent operator drive Pods toward CR spec, restart on crash (`restartPolicy`/backoff), and schedule placement across nodes. Metatron rides the platform's reconciliation rather than reimplementing it.
- **Supervision:** delegated to K8s (liveness/readiness probes, CrashLoopBackoff, `Job` retries). `SupervisionPolicy` maps onto probe + backoff + `backoffLimit` settings.
- **Fault isolation:** Pod/namespace/`NetworkPolicy`/`SecurityContext` boundaries — strictly stronger than in-process. Multi-tenant by construction.
- **Placement:** the kube-scheduler. Scales to many nodes.

### 4.6 Backend trade-offs (contrast)

| Dimension | `RustActorBackend` | `KubernetesCrdBackend` |
|-----------|--------------------|------------------------|
| **Isolation strength** | OS process per harness session; actor fault containment | Pod/namespace/cgroup/seccomp/NetworkPolicy — strongest |
| **Latency to spawn** | microseconds–ms (actor) | seconds (Pod schedule + image pull) |
| **Scale ceiling** | one node (or small actor cluster) | thousands of agents across a cluster |
| **Operational deps** | none — a single binary | a Kubernetes cluster + operator |
| **Reconciliation owner** | Metatron's own loop | shared with K8s control plane |
| **Failure handling** | supervision trees (`OneForAll` etc.) | probes + CrashLoopBackoff + Job retries |
| **Multi-tenancy** | weak (shared process) without extra sandboxing | strong (namespaces/RBAC) by default |
| **Best for** | local dev, tests, low-latency tightly-wired teams, single-tenant | production, large fleets, hard multi-tenant isolation |
| **Migration/preempt** | in-proc move is cheap; harness session still non-preemptible (§9) | Pod eviction is native but kills the in-flight session (§9) |

The point of carrying *both* is to keep the `ExecutionBackend` seam honest: an extension point that works for *only* one of "fast in-process actors" and "declarative cluster CRs" is over-fit. Both reference impls must pass the same conformance suite (§8).

### 4.7 Backend extension points (supporting both styles)

A third-party backend (e.g. a serverless or Nomad backend) implements `ExecutionBackend` and provides:

- A **placement strategy** (where a session runs).
- A **lifecycle driver** (how Spawn/Retire/Rewire/Restart/Migrate are effected).
- A **supervision mapping** (how `SupervisionPolicy` is realized).
- A **sandbox provider** (how `PermissionScope`/`WorkspaceSpec`/`ToolGrant` become real isolation — §6).
- An **`ActualState` observer** (how liveness/health is read back).

These five seams are exactly the set spanned by the two reference impls, so they are validated against both an in-process and an out-of-cluster style.

---

## 5. Interfaces & schemas (consolidated)

This section gathers the normative shapes this spec introduces (beyond the canonical types imported from overview §7). Rust-flavored pseudotypes.

```rust
// ---- Harness contract ----
trait AgentHarness { /* §3.1 */ }
struct CapabilitySet      { /* §3.3 */ }
struct MinimumGuarantees  { /* §3.3 */ }
struct HarnessDescriptor  { tool: String, version: String, model: String, scaffold: String }

struct TaskSpec        { /* §3.2 */ }
struct Context         { /* §3.2 */ }
struct HarnessResult   { /* §3.2 */ }
enum   Outcome         { Completed, Blocked{question: Text}, Failed{error: Text}, Aborted, TimedOut }
struct StructuredReport{ /* typed summary; schema-validated; never free text into SoR */ }
struct CheckOutcome    { check: Check, passed: bool, detail: Text }
enum   Telemetry       { Sparse, Medium, Rich(/* tool-call + step records */) }
struct Usage           { tokens_in: u64, tokens_out: u64, tool_calls: u32, cost: Option<Money> }

// ---- Permissions (hooks; full model in 08) ----
struct PermissionScope { fs: FsScope, net: NetScope, tools: ToolGrant, secrets: SecretScope }
struct ToolGrant(Vec<ToolPermission>);   // least-privilege allow-list per role
struct WorkspaceSpec   { root: PathSpec, mount: MountMode, isolation: WorkspaceIsolation }

// ---- Backend & reconciliation ----
trait  ExecutionBackend { /* §4.1 */ }
struct ActualState     { agents: Map<AgentId, RuntimeStatus>, generation: u64 }
struct ReconcilePlan   { actions: Vec<LifecycleAction>, generation: u64 }
enum   LifecycleAction { Spawn{..}, Retire{..}, Rewire{..}, Restart{..}, Migrate{..}, NoOp{..} }
struct SupervisionPolicy { /* §4.3 */ }

// ---- Sessions / control ----
type   SessionId = Hash;
enum   CancelMode { Graceful, Forceful }
struct CheckpointRef(Hash);
enum   CtlErr { Unsupported, NotFound, Inflight, Backend(Text) }
```

### 5.1 Conformance / capability matrix (normative summary)

| Capability | Required? | Consumed by | Fallback if absent |
|------------|-----------|-------------|--------------------|
| Runs `TaskSpec` to terminal `Outcome` | **Mandatory** | reconcile, supervision | — (invalid adapter) |
| Respects `WorkspaceSpec` + `ToolGrant` | **Mandatory** | `06`/`08` sandboxing | — (invalid adapter) |
| Final `UnifiedDiff` | **Mandatory** | state plane, checks | — |
| Schema-valid `StructuredReport` | **Mandatory** | governance, `07` | — |
| Hard `cancel(Forceful)` | **Mandatory** | reconcile/preempt (§9) | — |
| `structured_tool_log` | Optional | `07`, `05` | coarse trace from diff |
| `usage_accounting` | Optional | PID `cost` (`03`) | wall-clock cost estimate |
| `streams_progress` | Optional | `07` live view | final-result-only status |
| `cooperative_checkpoint`/`cancel` | Optional | reconcile (§9) | non-preemptible handling |
| `deterministic_replay` | Optional | JIT (`05`) | treat as non-deterministic |

---

## 6. Sandboxing & permissions (hooks; full model in `08`)

> Each agent runs with a **scoped permission set derived from its role** — least privilege, capability-scoped. This spec defines the *hooks*; the threat model, attestation, and Byzantine response are `08-trust-and-security.md`.

### 6.1 Role → scope derivation

A `RoleRef` (configuration layer) deterministically derives a `PermissionScope`:

```
PermissionScope = derive_scope(role, goal, wiring)
   fs      ⊆ the agent's WorkspaceSpec only (no access outside its workspace root)
   net     ⊆ the explicit egress allow-list for the role (default: deny-all)
   tools   = ToolGrant: only the tools the role needs (e.g. a read-only reviewer gets no write/exec)
   secrets ⊆ only credentials provably required by goal (short-lived, scoped tokens)
```

Defaults are **deny-by-default**; a role widens its scope only by explicit grant, and grants are themselves part of the configuration layer (so a scope change is a consensus-decided typed diff, auditable in the Merkle history). The `TaskSpec::permitted_tools` is the *intersection* of the role's grant and the task's needs.

### 6.2 Enforcement hooks per backend

The `Sandbox` provider seam (§4.7) realizes the scope:

| Hook | `RustActorBackend` | `KubernetesCrdBackend` |
|------|--------------------|------------------------|
| fs scope | per-session temp dir + bind-mount + (optionally) namespaces | Pod volume + `readOnlyRootFilesystem` + mounts |
| net scope | egress filter / no-network process | `NetworkPolicy` |
| tool grant | adapter only exposes granted tools to the harness CLI | same, plus container image minimization |
| secrets | short-lived token injected into session env, scrubbed after | mounted `Secret` / projected token, TTL-bound |
| isolation | OS process + seccomp/cgroup (if available) | namespace + `SecurityContext` + seccomp |

The harness is driven as a black box, but it is *confined* by the backend, not by trust in the harness's good behavior. A harness that *tries* to exceed its scope is contained by the OS/cluster boundary; an attempt is a Sentinel-observable security event (`07`/`08`).

### 6.3 Workspace isolation between concurrent Workers

Each session gets a `WorkspaceSpec` with an `isolation` mode. The default for concurrent independent Workers is **per-session isolated working copies** (e.g. a git worktree / copy-on-write clone per session), reconciled back via `HarnessResult::diff`. Shared-workspace modes exist for tightly-wired teams but raise contention and interference questions parked in OQ-2.

---

## 7. Worked example (end-to-end)

1. The council accepts a proposal (`02`) that adds a `Worker` agent `W` bound to the Claude Code adapter, wired to reviewer `R`, with goal "implement endpoint X." This is a typed diff committed to the configuration layer (`01`).
2. On the next tick, `backend.observe()` reports `W` is not running. `reconcile()` emits `Spawn{W, role=worker, harness=claude-code, scope=derive_scope(worker, goal, [R])}`.
3. `apply()` provisions `W`: an isolated workspace (git worktree of the repo), a least-privilege `PermissionScope` (write to `src/`, run tests, no network), and — on the actor backend — an actor with a mailbox.
4. `W` receives a `TaskSpec` (goal, instructions, inputs, `acceptance = [cargo test, lint, "diff touches only src/x/**"]`, budget) and a `Context` (read-only world-view, peer `R`, `tier_hint = Tier0`).
5. `W`'s actor invokes `claude_code.run(task, ctx)`. **Claude Code runs its own full agentic loop** — plans, edits files, runs tools, retries internally. Metatron does **not** intervene.
6. The adapter returns a `HarnessResult`: `outcome = Completed`, a `diff`, `artifacts`, a schema-valid `report`, `telemetry = Rich`, `usage = Some{…}`.
7. Metatron runs the `acceptance` checks independently → `check_results`. Telemetry + usage flow to `07`; check outcomes feed reputation (`08`), the PID `progress`/`cost` dims (`03`), and JIT stability detection (`05`).
8. The produced `diff`/artifacts become candidate progress-layer updates, which (via the normal Guardian→Genesis path) get proposed and committed. The loop closes.

If instead a thin CLI harness were bound, steps 5–7 are identical *except* `telemetry = Sparse`, `usage = None`, and Observability degrades per §3.3 — **the orchestration code is unchanged**. That invariance is the whole point.

---

## 8. Conformance suite (both backends, all adapters)

To keep the seams honest, two test batteries are normative:

- **Adapter conformance** — every `AgentHarness` adapter must pass: declares a `CapabilitySet` whose `minimum` holds; runs a fixture `TaskSpec` to a terminal `Outcome`; produces a parseable `diff` + schema-valid `report`; respects a deny-all `ToolGrant` (attempts to exceed are contained, surfaced, and *not* silently succeeding); honors `cancel(Forceful)` within a bounded time.
- **Backend conformance** — every `ExecutionBackend` must pass: reconcile is idempotent and level-triggered (replaying a plan converges; dropping an event still converges); Spawn/Retire/Rewire/Restart effect the intended `ActualState`; supervision restarts within policy and escalates past budget; sandbox hooks actually confine a deliberately-misbehaving fixture harness.

`RustActorBackend` and `KubernetesCrdBackend` are the two reference implementations the backend battery runs against.

---

## 9. Open questions & ambiguities

Parked, tracked, and owned here per overview §9. These are genuine — not yet decided.

- **OQ-1 — Partial-telemetry fidelity mapping.** How faithfully can a heterogeneous harness's *partial* telemetry be projected into the uniform `HarnessResult` without misrepresenting it? When a harness reports *some* tool calls but not all, do we mark the trace `Partial` and how do downstream consumers (`07`, `05`) reason about gaps? And how much of a harness's self-reported `report` should be trusted vs. independently re-derived (e.g. recompute the diff ourselves rather than believe the harness)? Over-trust corrupts the system of record; over-verification is expensive.
- **OQ-2 — Workspace/state isolation between concurrent Workers.** Default is per-session isolated working copies (§6.3), but tightly-wired teams sometimes need shared state. How do we handle write-write conflicts, interference, and visibility when two Workers operate on overlapping workspaces? Is the answer always "isolate + merge via diffs at commit," or do we need a transactional shared workspace with optimistic concurrency? How does isolation interact with the content-addressed artifact store?
- **OQ-3 — Reconciliation vs. non-preemptible sessions.** Many harness sessions cannot be cleanly preempted: a Claude Code run mid-edit has no safe checkpoint. When desired state changes (Retire/Migrate/Rewire) while a session is in flight, do we (a) wait for the session to finish (latency), (b) `cancel(Forceful)` and accept a possibly half-applied workspace (correctness — but the isolated working copy is discarded, so side effects are contained *if* the harness only touched its workspace), or (c) require `cooperative_checkpoint` for preemptible classes of work and treat the rest as atomic? How does drain interact with the level-triggered loop when a generation changes mid-session?
- **OQ-4 — Cost/quota accounting per harness.** Harnesses that lack `usage_accounting` give no token/cost data, yet the PID `cost` dimension (`03`) and per-role budgets need numbers. The fallback (wall-clock × tier price model) is crude. How do we attribute spend across heterogeneous billing models (per-token, per-seat, per-request), enforce a `Budget` *during* a non-cooperative session (we can only hard-cancel, not throttle), and reconcile estimated vs. actual spend after the fact? Quota exhaustion mid-session is a special case of OQ-3.
- **OQ-5 — Partial side effects & restart idempotency.** Supervision restarts assume sessions are idempotent, but a harness may have external side effects (pushed a branch, called an API, sent a message) before failing. Isolated workspaces contain *filesystem* effects but not *external* ones. How do we make restart safe in the presence of non-transactional external effects — effect logs + compensation, an outbox, or declaring such tools "non-restartable"?
- **OQ-6 — `descriptor()` granularity for decorrelation.** Reputation and decorrelation (`02`/`08`) need to know "how independent are these two results." Is `{tool, version, model, scaffold}` enough to estimate correlation, or do two Workers on the *same* model via *different* harnesses still fail correlatedly? What's the right similarity metric, and who owns it — here or `08`?
- **OQ-7 — Cross-session memory ownership.** `Context::memory` hints at retrieval/memory across sessions, but memory is a correlation *and* a state-of-record hazard (a harness's private memory is outside the Merkle history). Where does legitimate cross-session agent memory live, how is it versioned, and how does it avoid silently re-correlating "independent" agents that share a memory store?
- **OQ-8 — Backend migration of live agents.** `Migrate` is clean for an idle agent but undefined for one mid-session (subsumes OQ-3). Is live migration across backends (actors→Pods) ever supported, or only at session boundaries?

---

## 10. Relationships to other specs

- **`00-overview.md`** — Canonical anchor. `AgentHarness`, `ExecutionBackend`, `Tier`, `WorldModel`, `AgentId`, `Hash` are imported from §7, not redefined. Realizes the "abstract over execution" commitment (§1) and the Execution plane (§2). This spec is the "plant"/actuator in the closed loop (§5).
- **`01-state-model.md`** — The **configuration layer** of the `WorldModel` is the **desired** input to reconciliation; the **progress layer** receives the diffs/artifacts that sessions produce. `ActualState` is the runtime projection that desired is reconciled against. Scope grants and wiring are configuration-layer state.
- **`02-consensus.md`** — *Decides* which agents exist and how they're wired (Spawn/Retire/Rewire originate as typed proposals). The Execution plane only **actuates** accepted desired state; it never edits it. Escalated agent failures surface as evidence that may prompt new proposals.
- **`03-control-loop.md`** — Consumes Execution-plane measurements: `check_results`→`progress`, `usage`/estimates→`cost`, failure/restart rates→signals. PID control actions become proposals that change desired configuration, which reconciliation then enacts.
- **`05-agent-jit.md`** — Builds *on top of* this plane. Tier-0 (pure LLM harness) lives here; `Context::tier_hint` and `CapabilitySet::deterministic_replay` are the seams JIT plugs into. Compiler agents observe the telemetry this plane emits to detect stable behavior; deopt traps fall back to Tier-0 `AgentHarness::run`.
- **`06-interaction-and-mailbox.md`** — `Outcome::Blocked` routes to Guardians; ambiguity surfaces to the user via the mailbox and **the affected work blocks until answered** (overview §5). The Execution plane never fabricates answers.
- **`07-observability.md`** — Primary consumer of best-effort telemetry. **Must degrade gracefully** when a harness exposes less than `Rich` (§3.3 table). Session liveness, reconcile results, and supervision events are first-class observability inputs; Sentinels watch them.
- **`08-trust-and-security.md`** — Owns the full threat model. This spec defines only the **hooks**: role→`PermissionScope` derivation (§6.1), per-backend enforcement (§6.2), and the contract that a harness is *confined*, not *trusted*. `AgentId`, `Signature`, `Reputation` are imported. Sandbox-escape attempts are security events handed to `08`.
