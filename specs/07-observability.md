# Metatron — Observability Plane

> **Status:** Research architecture specification (v0.1)
> **Plane:** Observability (cross-cutting; taps every other plane)
> **Owning agents:** Sentinel (watch); every other agent is a *producer*.
> **Primary spec dependencies:** `00-overview.md` (canonical types & vocabulary — when this spec disagrees with 00, 00 wins). Consumes from and feeds back into `01-state-model.md`, `02-consensus.md`, `03-control-loop.md`, `04-runtime-and-harness.md`, `05-agent-jit.md`, `06-interaction-and-mailbox.md`, `08-trust-and-security.md`.

---

## 1. Purpose

The bootstrap mandate is unambiguous: **"Monitoring should be paramount — it should be easy to monitor everything that is going on."** This plane discharges that mandate. It is the realization of cross-cutting principle **§6.6 — *Record everything immutably; monitoring is first-class, not an afterthought.***

Observability is the **fifth plane**, and unlike the other four it is **cross-cutting**: it owns no business logic of its own, but **taps** Interaction, Governance, State, and Execution, plus itself. Its job is to make the entire **closed loop (§5)** — `user instruction → goal → proposal → votes/decision → commit → reconcile/execution → measurement → error vector → next control action → next proposal` — **observable, queryable, and causally reconstructable end to end**.

It serves three classes of consumer, in priority order:

1. **Machine consumers, in-loop (first-class).** Two named internal consumers close the control loop:
   - **Sentinel agents** consume telemetry to detect off-protocol / out-of-character behavior, drift, and rising trap rates — feeding **reputation (08)** and **tier demotion (05)**.
   - **PID estimators (03)** consume metrics to compute the **`ErrorVector`**, including consensus **`dispersion`** as the **divergence** signal.
   These are not dashboards-for-humans bolted on afterward; they are load-bearing components of the governor. The plane is designed *for them first*.
2. **Human operators.** Live dashboards, streaming tails, alerting, and forensic query over the history of *how the system became what it is*.
3. **External tooling.** OpenTelemetry-compatible export so existing infrastructure (collectors, Prometheus, Tempo/Jaeger, Loki, Grafana) can be reused rather than reinvented — consistent with Metatron's *extensible-like-Kubernetes* ethos.

**Non-goals.** This plane does not *decide* anything (that is Governance), does not *store the system of record* (that is the State plane's Merkle DAG), and does not *act* (Sentinels act, but as agents in the taxonomy, governed by consensus like any other). Observability **observes**. The one hard rule it inherits from §6.1 (*constrain the output space*): telemetry is **structured and schema-validated**, never free text into a sink nobody can query.

---

## 2. Concepts

### 2.1 The unified TRACE / METRIC / EVENT model

All telemetry in Metatron is exactly one of three kinds. They share a common envelope (§4.1) and a common correlation scheme (§2.3) so they can be joined.

| Kind | What it is | Mutability | Cardinality | Primary consumer |
|------|-----------|------------|-------------|------------------|
| **Event** | An immutable **fact** that something happened at a point in logical+wall time. | Append-only, never updated. | One per occurrence. | Sentinels (pattern/anomaly), forensic query, audit. |
| **Metric** | A **time series** — a named, dimensioned numeric sample stream. | Aggregatable. | High-rate, downsampled. | PID estimators (03). |
| **Trace** | A **causal span tree** over one unit of work; spans carry parent links and timing. | Append-only spans. | One tree per loop iteration / sub-task. | Causal reconstruction, latency analysis, both machine consumers. |

These are **three views of the same underlying activity**, not three separate pipelines. An `Event` typically *closes* a `Span` and *increments* a `Metric` in the same emission. Example: a Genesis member casting a blind vote emits the **event** `BlindVoteCast`, closes the **span** `vote.cast` under the proposal's trace, and increments the **metric** `consensus.votes_total{verdict="approve"}`.

```
        one occurrence: "Genesis g7 cast an Approve vote on proposal P"
                 │
     ┌───────────┼─────────────────────────────┐
     ▼           ▼                             ▼
   EVENT       SPAN (closes)                METRIC (increments)
 BlindVoteCast vote.cast{voter=g7}     consensus.votes_total{verdict=approve}
 (immutable     parent=consensus.round  + observes confidence as a gauge
  fact, signed) trace_id=T(P)
```

#### Event — immutable facts

An `Event` is the atomic, immutable record that *something happened*. The canonical catalog of event types (the closed-loop spine) is:

- **Interaction:** `InstructionReceived`, `AmbiguityDetected`, `QuestionRaised`, `QuestionAnswered`, `GoalNormalized`, `NotificationSent`.
- **Governance:** `ProposalAuthored`, `VerificationRun`, `BlindVoteCast`, `DeliberationRoundStarted`, `DecisionReached`, `ControlActionEmitted`.
- **State:** `CommitAppended`, `HeadAdvanced`, `ForkObserved`, `ReconcileRequested`.
- **Execution:** `ReconcileActionStarted`, `ReconcileActionFinished`, `HarnessSessionStart`, `HarnessSessionEnd`, `TrapFired`, `DeoptOccurred`, `TierPromoted`, `TierDemoted`.
- **Observability-self:** `ErrorVectorSampled`, `SentinelAlertRaised`, `DriftDetected`, `TelemetryGap` (a source emitted less than its declared capability), `RetentionExpired`.

Every event the closed loop *requires* to be reconstructable is in this list. Events are **immutable facts**: a `Decision` that is later overturned does not mutate the original `DecisionReached` event; a new event is appended.

#### Metric — time series the PID consumes

A `Metric` is a `(name, dimensions, value, kind, timestamp)` sample. Kinds: `Counter` (monotone), `Gauge` (point-in-time), `Histogram` (distribution). The PID estimators (03) subscribe to a defined set of **control metrics** (§3.4) that map onto the `ErrorVector` components: `progress`, `cost`, `divergence`, `latency`. Crucially, **`divergence` is sourced from the consensus `dispersion`** carried on each `Decision`.

#### Trace — causal spans

A `Trace` is a tree of `Span`s sharing one `trace_id`. A span has `span_id`, `parent_span_id`, a name, a start/end (wall + logical time), a status, and attributes. Traces are how the **causal chain** of one loop iteration is reconstructed (§2.4). They are OpenTelemetry-span-shaped (§3.6) so external trace tooling works unmodified.

### 2.2 Producers and the tap model

**Every agent and every plane is a producer.** Emission is not optional and not centralized in one component — it is a *capability of the substrate*. Three tap mechanisms, in decreasing fidelity:

1. **Native instrumentation (in-process planes).** Governance, State, and the in-process `RustActorBackend` call the emission API directly with full-fidelity structured telemetry. This is the common case for the kernel.
2. **Backend taps (out-of-process execution).** The `KubernetesCrdBackend` taps pod logs, CRD status transitions, and the OTel collector sidecar. Fidelity is high but asynchronous.
3. **Harness taps (best-effort).** `AgentHarness` telemetry is **best-effort** by contract (§3.5). A rich harness streams token-level events; a poor one exposes only a final diff. The plane **degrades gracefully** (§3.5) rather than dropping the source.

### 2.3 Correlation: the IDs that thread the loop

This is the **key requirement**. To "monitor everything" means the causal chain is reconstructable end to end. Five identifiers thread it (full schema §4.2):

| Id | Scope | Born at | Threads |
|----|-------|---------|---------|
| `InstructionId` | one user instruction | `InstructionReceived` (Interaction) | the **root** of one causal chain |
| `GoalId` | one normalized goal | `GoalNormalized` | links instruction → governance work |
| `TraceId` | one loop *iteration* | `ProposalAuthored` (or a control action) | all spans of one proposal→commit→reconcile→measure cycle |
| `CommitHash` | one accepted state update | `CommitAppended` (State) | ties trace to the immutable Merkle node (`Commit.proposal`, `Commit.decision`) |
| `EpisodeId` | one cause→effect→correction arc | first proposal of an arc | groups successive `TraceId`s the PID chained together |

**The invariant:** every `Event`, `Metric`, and `Span` carries as many of these as are known at emission time. The Merkle `Commit` already references `proposal` and `decision` hashes (00 §7); observability **does not duplicate** that linkage — it *joins to it* via `CommitHash`. The telemetry layer is the **causal index** over the immutable history, not a competing copy of it.

### 2.4 The causal chain (worked example)

```
InstructionId=I42 ───────────────────────────────────────────────────────── (root)
  │  Interaction: InstructionReceived → GoalNormalized → GoalId=G7
  │
  ├─ TraceId=T1 (loop iteration 1)            EpisodeId=E3 ┐
  │    Governance: ProposalAuthored(P1, derived_from=I42)  │
  │      └ VerificationRun(P1)  → events + verify metrics   │
  │      └ BlindVoteCast ×N (decorrelated, isolated)        │
  │      └ DeliberationRoundStarted ×r                      │
  │      └ DecisionReached(P1): posterior, dispersion=0.31  │  dispersion ─┐
  │    State: CommitAppended(C1, proposal=P1, decision=D1)  │              │
  │    Execution: ReconcileActionStarted/Finished           │              ▼
  │      └ HarnessSessionStart/End (best-effort telemetry)  │        PID divergence
  │      └ TrapFired? DeoptOccurred?                         │
  │    Observability-self: ErrorVectorSampled(progress,cost,│              │
  │                         divergence, latency)            │              │
  └─ TraceId=T2 (loop iteration 2)                          ┘              │
       Governance: ControlActionEmitted ◀── PID error vector ◀────────────┘
         └ ProposalAuthored(P2, derived_from=ControlAction(T1))
         ... chain continues, same EpisodeId=E3 ...
```

A single query "show me everything that happened because of instruction I42" walks `InstructionId=I42 → GoalId → {TraceId} → {CommitHash}` and returns the entire interleaved Event/Metric/Span stream, ordered by **logical time (01)** with wall-clock as a secondary key. That walk is the operational meaning of *"monitor everything that is going on."*

---

## 3. Detailed design

### 3.1 Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  PRODUCERS (every plane, every agent)                                       │
│  Interaction · Governance · State · Execution · Observability-self          │
└───────────────┬───────────────┬───────────────┬───────────────────────────┘
   native       │ backend tap   │ harness tap   │  (best-effort, may be sparse)
   instrument.  ▼ (K8s/actors)  ▼ (final-diff…) ▼
        ┌───────────────────────────────────────────────┐
        │  EMISSION API  (Telemetry trait, §4.3)          │   non-blocking,
        │  envelope-stamps correlation ids, validates      │   bounded buffers,
        │  schema, assigns logical+wall time               │   lossy-by-policy
        └───────────────────────┬─────────────────────────┘
                                ▼
        ┌───────────────────────────────────────────────┐
        │  TELEMETRY BUS  (async, partitioned by TraceId)  │
        │  fan-out; OTLP-framed internally                 │
        └───┬───────────────┬───────────────┬─────────────┘
            ▼               ▼               ▼
   ┌──────────────┐ ┌──────────────┐ ┌───────────────────────┐
   │ EVENT LOG    │ │ METRIC TSDB  │ │ TRACE STORE           │
   │ append-only  │ │ time series  │ │ span trees            │
   │ (facts)      │ │ (downsampled)│ │ (causal)              │
   └──────┬───────┘ └──────┬───────┘ └──────────┬────────────┘
          │                │                    │
          ▼                ▼                    ▼
   ┌─────────────────────────────────────────────────────────┐
   │  QUERY + STREAM LAYER  (§3.7)  ── causal index over above │
   └───┬─────────────────────┬───────────────────┬───────────┘
       ▼                     ▼                   ▼
  ┌─────────┐         ┌──────────────┐   ┌──────────────────────┐
  │SENTINELS│         │ PID ESTIMATORS│   │ HUMANS / EXTERNAL OTel│
  │ (watch) │         │ (03)          │   │ dashboards · export   │
  └────┬────┘         └──────┬───────┘   └──────────────────────┘
       │ reputation(08)      │ ErrorVector(03)
       │ tier demotion(05)   ▼
       ▼               Governance: ControlActionEmitted → next Proposal
   Governance / 02 / 05
```

The bus is **non-blocking by construction**: producers never block the control loop on a slow sink (§3.8). Loss, when it must happen, is **policy-driven and itself observable** (it emits a `TelemetryGap`).

### 3.2 What every plane emits (concrete enumeration)

This is the normative emission contract. Each row is `Event(s) · key Metric(s) · Span(s)`.

#### Interaction plane (06) — Guardians
- **Events:** `InstructionReceived`, `GoalNormalized`, `AmbiguityDetected`, `QuestionRaised`, `QuestionAnswered`, `NotificationSent`.
- **Metrics:** `interaction.instructions_total`; `interaction.ambiguity_rate`; `interaction.question_blocked_seconds` (how long work blocked on the mailbox — feeds **latency**); `interaction.questions_open` (gauge).
- **Spans:** `intake` (root span; opens `TraceId` lineage via `InstructionId`/`GoalId`), `normalize`, `await_user` (the blocking span — its duration is the mailbox-block latency).

#### Governance plane (02, 03) — Guardians (author) + Genesis (dispose)
- **Events:** `ProposalAuthored`, `VerificationRun`, `BlindVoteCast`, `DeliberationRoundStarted`, `DecisionReached`, `ControlActionEmitted`.
- **Metrics:** `consensus.proposals_total{outcome}`; `consensus.votes_total{verdict}`; `consensus.posterior` (histogram); **`consensus.dispersion` (the divergence source)**; `consensus.rounds` (histogram — deliberation cost); `consensus.verify_failures_total`; `control.error_vector{dim}` (gauge, one series per dimension); `control.action_magnitude{dim}`.
- **Spans:** `proposal.author`, `proposal.verify`, `consensus.round`, `vote.cast` (one per Genesis member; **carries `voter` and `confidence`** but is emitted *post-decision-reveal* so it cannot leak votes and break blind-voting decorrelation — see §3.9), `control.compute_error`.

#### State plane (01)
- **Events:** `CommitAppended`, `HeadAdvanced`, `ForkObserved`, `ReconcileRequested`.
- **Metrics:** `state.commits_total{layer}`; `state.head_depth` (gauge); `state.forks_total`; `state.commit_apply_seconds` (histogram); `state.state_size_bytes{layer}`.
- **Spans:** `commit.append`, `commit.verify_signatures`, `head.advance`. Each span's attributes include the `CommitHash`, so the trace **joins directly to the Merkle node** (no copy of state).

#### Execution plane (04, 05) — Workers, Compilers
- **Events:** `ReconcileActionStarted`, `ReconcileActionFinished`, `HarnessSessionStart`, `HarnessSessionEnd`, `TrapFired`, `DeoptOccurred`, `TierPromoted`, `TierDemoted`.
- **Metrics:** `exec.reconcile_actions_total{status}`; `exec.harness_session_seconds` (histogram — **latency** input); `exec.tokens_total{harness}` and `exec.cost_units_total{harness}` (the **cost** input); `exec.trap_rate{agent}` (**Sentinel + tier-demotion input**); `exec.deopt_total`; `exec.tier{agent}` (gauge: 0/1/2); `exec.progress_delta` (artifacts/sub-goals resolved — **progress** input).
- **Spans:** `reconcile.action`, `harness.session` (best-effort children: `harness.step`, `harness.tool_call`, `harness.diff` — present only at the harness's declared capability, §3.5), `jit.trap`, `jit.deopt`.

#### Observability-self plane (07) — Sentinels + the plane itself
- **Events:** `ErrorVectorSampled`, `SentinelAlertRaised`, `DriftDetected`, `TelemetryGap`, `RetentionExpired`.
- **Metrics:** `obs.events_total{kind}`; `obs.dropped_total{reason}` (lossy-by-policy accounting); `obs.ingest_lag_seconds`; `obs.sentinel_alerts_total{severity}`; `obs.coverage_ratio{source}` (observed-vs-declared capability — the graceful-degradation gauge, §3.5).
- **Spans:** `sentinel.scan`, `error_vector.sample`, `telemetry.export`. The plane **observes itself**: a Sentinel that goes silent is detected by the absence of `sentinel.scan` spans.

### 3.3 Data path to Sentinels

Sentinels are **dynamic agents (taxonomy §3)** subscribed to the stream layer. Their input is primarily the **Event** view and trap-rate **Metrics**:

```
Telemetry bus ─▶ stream subscription (filtered by event kind & metric name)
   ├─ off-protocol detector  ◀─ schema-validation failures, out-of-order spans,
   │                            events that violate the consensus state machine
   ├─ out-of-character detector ◀─ per-agent behavioral baseline vs current
   │                               (token patterns, tool-call mix, vote patterns)
   ├─ drift detector ◀─ rolling divergence of an agent from its own history
   │                    and from peers (raises DriftDetected)
   └─ trap-rate monitor ◀─ exec.trap_rate{agent}, exec.deopt_total
                              │
        SentinelAlertRaised ──┼──▶ Reputation update (08): drifting agents decay
                              └──▶ Tier demotion (05): rising trap rate ⇒ deopt /
                                   demote a Tier-1/2 agent back toward Tier-0
```

Sentinels **do not mutate state directly** — separation of powers (§3 taxonomy) holds. They raise alerts and feed reputation/tier signals; any *structural* response (quarantine, rewire, demote) is a **typed proposal** decided by consensus (02), or an automatic deopt governed by 05's trap contract. This keeps even the watchdog inside the constitutional loop.

### 3.4 Data path to the PID estimators (03)

The PID estimators subscribe to the **Metric** view and compute the `ErrorVector` (00 §7). Mapping is explicit:

```
control metric (source plane)                  →  ErrorVector component
─────────────────────────────────────────────────────────────────────
exec.progress_delta, state.commits_total{...}  →  progress  (distance to goal)
exec.cost_units_total, exec.tokens_total       →  cost      (budget pressure)
consensus.dispersion  (per Decision)           →  divergence(council disagreement)
exec.harness_session_seconds,                  →  latency   (responsiveness)
  interaction.question_blocked_seconds
```

`divergence` deserves emphasis: it is **not** re-derived by the observability plane. The consensus protocol computes `Decision.dispersion` (00 §7: *"how split the council was -> feeds PID divergence"*). The observability plane merely **transports** it as the `consensus.dispersion` metric and the PID reads it. This keeps the divergence signal authoritative and single-sourced.

Each PID computation emits `ErrorVectorSampled` (closing the measurement, with the originating `TraceId`/`EpisodeId`) and the resulting control action emits `ControlActionEmitted` carrying `derived_from` so the **next** `ProposalAuthored` is causally linked back (00 §7: `Proposal.derived_from`). This is the seam that closes the loop in the telemetry graph.

### 3.5 Best-effort harness telemetry & graceful degradation

Per 00 §7, `AgentHarness::capabilities() -> CapabilitySet`, and **telemetry is best-effort**. Harnesses sit on a fidelity spectrum:

```
 high fidelity ──────────────────────────────────────────▶ low fidelity
 token stream · per-tool-call · intermediate diffs · ... · final diff only
```

The plane **represents partial telemetry explicitly rather than dropping it**. Mechanism:

1. **Declared coverage.** A harness's `CapabilitySet` includes a `TelemetryCapability` declaring which span/event types it *can* emit (`token_stream`, `tool_calls`, `intermediate_diffs`, `final_diff_only`, …). This is the **04 capability negotiation**, reused — observability does not invent a second negotiation.
2. **Synthetic spans for the unobserved.** When a harness declares `final_diff_only`, the plane still opens a `harness.session` span. The interior is recorded as a single `harness.opaque` child span with `status = inferred` and `attributes.basis = "final_diff"`. The session start/end and the resulting commit are real; the *interior steps* are explicitly marked **unobserved**, never fabricated as if observed.
3. **Coverage ratio.** `obs.coverage_ratio{source}` = observed-event-types / declared-capability event-types, surfaced per source. A drop below the declared floor emits `TelemetryGap`. This makes *the absence of telemetry itself a first-class, queryable signal* — you can always tell apart "nothing happened" from "we couldn't see what happened."
4. **Consumer-side degradation.** PID estimators and Sentinels treat a metric with low `coverage_ratio` as **higher-variance**, not as zero. (E.g., the PID may widen its uncertainty / reduce derivative gain on a sparsely-observed `latency`; a Sentinel raises its detection threshold rather than firing false alarms on a source it can barely see.) Degradation is *graceful* — the loop keeps closing on a noisier signal, it does not stall on a missing one.

**Invariant:** a missing measurement is represented as a **known unknown** (a typed gap with a coverage ratio), never as a silent zero and never as a fabricated value.

### 3.6 OpenTelemetry alignment

Metatron telemetry is **OpenTelemetry-shaped at the wire level** so existing infrastructure is reusable (the Kubernetes ethos: *reuse infra, don't reinvent*).

- **Events** map to OTel **Logs** (structured, with severity + body + attributes) *and* OTel **Events** on spans where one closes a span.
- **Metrics** map 1:1 to OTel **Metrics** (`Counter`/`Gauge`/`Histogram` → Sum/Gauge/Histogram).
- **Traces** map 1:1 to OTel **Traces/Spans**; `TraceId`/`span_id` use the OTel id format.
- Metatron's correlation ids (`InstructionId`, `GoalId`, `CommitHash`, `EpisodeId`) ride as **semantic-convention attributes** under a `metatron.*` namespace (e.g. `metatron.instruction_id`, `metatron.commit_hash`).
- The transport frame is **OTLP**; an embedded OTel **Collector** can fan out to Prometheus (metrics), Tempo/Jaeger (traces), and Loki/ClickHouse (events) with **zero custom exporters**.

Metatron's *internal* consumers (Sentinels, PID) read from the native bus for low latency; *external* consumers attach via the Collector. The two never diverge because both are fed the same OTLP stream.

### 3.7 Storage & retention

Three logical stores, each tuned to its kind (whether they are physically separate or co-located is an **open question**, §5):

| Store | Holds | Shape | Default retention |
|-------|-------|-------|-------------------|
| **Event log** | immutable facts | append-only log, indexed by all correlation ids | tiered: hot 7d, warm 90d, cold (object store) ≥ 1y |
| **Metric TSDB** | time series | downsampled rollups | raw 24–72h; 1m rollup 30d; 1h rollup 1y |
| **Trace store** | span trees | sampled (§3.8) | full for sampled traces 30d; *always-keep* for traces touching a `DecisionReached` or `TrapFired` |

**Retention policy is itself causal-aware.** A trace is **never** evicted while its `CommitHash` is still reachable on the live Merkle chain *and* the operator policy demands replayability — i.e., the audit guarantee "you can reconstruct how the system became what it is" (§6.6) is honored by **pinning** telemetry whose commit is load-bearing. Eviction emits `RetentionExpired` (so even forgetting is observable).

The **relationship between the event log and the Merkle commit history** (shared store vs. separate) is deliberately left open (§5); §2.3 fixes only that they are *joined by `CommitHash`*, not duplicated.

### 3.8 Sampling, cost & non-blocking emission

"Monitor everything" collides with telemetry volume at scale. The reconciling principles:

- **Events on the closed-loop spine are never sampled.** Every `ProposalAuthored`, `BlindVoteCast`, `DecisionReached`, `CommitAppended`, `TrapFired`, `ControlActionEmitted`, `QuestionRaised/Answered`, `ErrorVectorSampled` is recorded at **100% fidelity**. These are facts of governance and audit; dropping one breaks causal reconstruction.
- **High-cardinality interior telemetry is sampled.** Harness `token_stream` and `tool_call` spans use **tail-based sampling** keyed on outcome: keep 100% of traces that hit an error, a trap, a deopt, or high dispersion; sample the boring successful path. This keeps cost bounded while preserving every *interesting* trace.
- **Metrics are aggregated at the edge**, not stored per-sample.
- **Emission is non-blocking.** Producers write to bounded per-`TraceId` buffers. On backpressure the policy is *drop interior samples first, spine events last, and account every drop* (`obs.dropped_total{reason}` + a `TelemetryGap`). The control loop **must never block on telemetry** — observability is best-effort *to the producer*, authoritative *to the consumer*.

Exact sampling rates, and whether full-fidelity is affordable at target scale, are an **open question (§5)**.

### 3.9 Blind-voting hazard (decorrelation safety)

Observability could *accidentally break consensus*: principle §6.3 says blind votes are cast **in isolation, before deliberation**, to keep errors **decorrelated**. A naive live stream of `BlindVoteCast` events would let a not-yet-voted Genesis member observe peers' votes and **correlate** — defeating the Condorcet decorrelation. Therefore:

- `vote.cast` spans and `BlindVoteCast` events are **embargoed**: buffered and only released to the stream/query layer **after the blind-vote round closes** for that proposal. Pre-reveal, they exist only in write-ahead form, visible to no agent consumer.
- `consensus.dispersion`/`consensus.posterior` are emitted **only on `DecisionReached`**, never incrementally.
- Sentinels analyze voting patterns **post-decision** only.

This is a case where the observability plane must actively *protect* a governance invariant rather than passively report. Recorded immutably (§6.6), but **revealed on a schedule that preserves decorrelation (§6.3).**

---

## 4. Interfaces & schemas

Rust-flavored pseudotypes. Reuses canonical types from 00 §7 verbatim (`Hash`, `AgentId`, `LogicalTime`, `Signature`, `ErrorVector`, `CapabilitySet`, `Tier`).

### 4.1 The common envelope

```rust
/// Every Event, Metric sample, and Span ships inside this envelope.
struct TelemetryEnvelope {
    kind: TelemetryKind,            // Event | Metric | Trace(span)
    source: SourceRef,             // which plane/agent/harness produced it
    correlation: Correlation,      // §4.2 — the ids that thread the loop
    logical_time: LogicalTime,     // primary ordering key (from 01)
    wall_time: u64,                // ns since epoch; secondary key, for humans
    coverage: Coverage,            // observed | inferred | gap  (§3.5)
    signature: Option<Signature>,  // present for spine events (audit-grade)
}

enum TelemetryKind { Event(Event), Metric(MetricSample), Span(Span) }

enum Coverage {
    Observed,                      // directly instrumented, full fidelity
    Inferred { basis: Text },      // reconstructed (e.g. from a final diff)
    Gap { declared: u32, seen: u32 }, // known unknown; drives coverage_ratio
}

struct SourceRef {
    plane: Plane,                  // Interaction|Governance|State|Execution|Observability
    agent: Option<AgentId>,
    harness: Option<HarnessId>,
    backend: Option<BackendRef>,   // RustActor | KubernetesCrd
}
```

### 4.2 Correlation — the loop-threading ids

```rust
/// As many of these as are known at emission time are always stamped.
struct Correlation {
    instruction: Option<InstructionId>, // root of one user-caused chain
    goal: Option<GoalId>,               // normalized goal
    trace: Option<TraceId>,             // one loop iteration's span tree
    episode: Option<EpisodeId>,         // a cause→effect→correction arc
    commit: Option<Hash>,               // CommitHash → joins the Merkle node (01)
    proposal: Option<Hash>,             // Proposal hash (02)
    decision: Option<Hash>,             // Decision hash (02)
    derived_from: Option<Hash>,         // control action / instruction that caused this (03)
}

type InstructionId = Hash;
type GoalId        = Hash;
type TraceId       = [u8; 16];   // OTel-format trace id
type EpisodeId     = Hash;
type HarnessId     = Hash;
```

### 4.3 The emission API

```rust
/// Implemented by the runtime and handed to every producer. Non-blocking.
trait Telemetry {
    /// Record an immutable fact. Spine events are signed & never sampled.
    fn event(&self, e: Event, c: &Correlation);

    /// Record a metric sample (aggregated at the edge).
    fn metric(&self, m: MetricSample, c: &Correlation);

    /// Open a causal span; returns a guard whose drop closes it.
    fn span(&self, name: &str, c: &Correlation) -> SpanGuard;

    /// Declare reduced telemetry capability (graceful degradation, §3.5).
    /// Mirrors 04's CapabilitySet; emits TelemetryGap when seen < declared.
    fn declare_coverage(&self, source: &SourceRef, cap: &TelemetryCapability);
}

/// Subset of the harness CapabilitySet (00 §7) describing emittable telemetry.
struct TelemetryCapability {
    can_emit: Vec<EmissionType>,   // TokenStream|ToolCalls|IntermediateDiffs|FinalDiffOnly|...
}
```

### 4.4 Event, Metric, Span

```rust
struct Event {
    ty: EventType,                 // catalog of §2.1 / §3.2
    attrs: StructuredAttrs,        // schema-validated; never free text (§6.1)
}

enum EventType {
    // Interaction
    InstructionReceived, GoalNormalized, AmbiguityDetected,
    QuestionRaised, QuestionAnswered, NotificationSent,
    // Governance
    ProposalAuthored, VerificationRun, BlindVoteCast,
    DeliberationRoundStarted, DecisionReached, ControlActionEmitted,
    // State
    CommitAppended, HeadAdvanced, ForkObserved, ReconcileRequested,
    // Execution
    ReconcileActionStarted, ReconcileActionFinished,
    HarnessSessionStart, HarnessSessionEnd,
    TrapFired, DeoptOccurred, TierPromoted, TierDemoted,
    // Observability-self
    ErrorVectorSampled, SentinelAlertRaised, DriftDetected,
    TelemetryGap, RetentionExpired,
}

struct MetricSample {
    name: String,                  // e.g. "consensus.dispersion"
    kind: MetricKind,              // Counter | Gauge | Histogram
    value: f64,
    dims: BTreeMap<String, String>,// dimensions (low-cardinality)
}

struct Span {
    trace: TraceId,
    span: [u8; 8],
    parent: Option<[u8; 8]>,
    name: String,
    start_logical: LogicalTime, start_wall: u64,
    end_logical: Option<LogicalTime>, end_wall: Option<u64>,
    status: SpanStatus,            // Ok | Error | Inferred(§3.5)
    attrs: StructuredAttrs,
}
```

### 4.5 Query & stream interface

```rust
trait ObservabilityQuery {
    /// THE causal-reconstruction query: everything caused by one instruction,
    /// interleaved Event/Metric/Span, ordered by logical_time. (§2.4)
    fn causal_chain(&self, root: InstructionId) -> CausalChain;

    /// Scoped pulls for the two machine consumers.
    fn events(&self, filter: EventFilter) -> Stream<Event>;       // Sentinels
    fn metrics(&self, q: MetricQuery) -> TimeSeries;              // PID estimators
    fn trace(&self, t: TraceId) -> SpanTree;                     // latency / causal

    /// Live tail for dashboards & Sentinels. Respects the blind-vote embargo (§3.9).
    fn subscribe(&self, filter: StreamFilter) -> LiveStream;

    /// Coverage introspection — "what can we even see right now?" (§3.5)
    fn coverage(&self, source: &SourceRef) -> CoverageReport;
}
```

### 4.6 Consumer contracts (named)

```rust
/// Sentinel input contract (§3.3) → feeds Reputation (08) & tier demotion (05).
trait SentinelFeed {
    fn off_protocol(&self) -> Stream<Event>;     // schema/state-machine violations
    fn drift(&self) -> Stream<DriftSignal>;      // per-agent baseline deviation
    fn trap_rates(&self) -> TimeSeries;          // exec.trap_rate{agent}
}

/// PID estimator input contract (§3.4) → computes ErrorVector (03).
trait ControlFeed {
    fn progress(&self) -> TimeSeries;
    fn cost(&self) -> TimeSeries;
    fn divergence(&self) -> TimeSeries;          // sources consensus.dispersion
    fn latency(&self) -> TimeSeries;
    /// Coverage-weighted variance hint, so the PID can degrade gracefully (§3.5).
    fn confidence(&self, dim: &str) -> f32;
}
```

---

## 5. Open questions & ambiguities

These are **parked, not resolved** — tracked here per the spec-set convention (00 §9).

1. **Telemetry volume & cost at scale; sampling vs. full fidelity.** §3.8 fixes that *spine events* are never sampled, but the affordability of even that floor at large org-charts is unproven. Open: target-scale budget, whether tail-based sampling rates should themselves be a **PID-controlled** dimension (observability cost as a control input), and the crossover where full-fidelity interior telemetry becomes infeasible.
2. **Shared vs. separate storage for the event log and the Merkle commit history.** §2.3/§3.7 fix only that they are *joined by `CommitHash`*, never duplicated. Open: should the immutable event log and the Merkle DAG (01) share one content-addressed store (single source of immutable truth, simpler audit) or stay separate (different access patterns, independent retention)? Trade-off: storage unification vs. coupling the audit log's availability to the state plane's.
3. **Privacy of user-instruction content in traces.** `InstructionReceived` and the causal chain may carry sensitive user-instruction text. Open: redaction/tokenization policy, whether instruction *bodies* live outside telemetry (referenced by `InstructionId` only) while telemetry holds only the hash, and how this interacts with the §6.6 "record everything" mandate and external OTel export (§3.6). Cross-ref 08 (trust/security) and 06 (interaction).
4. **Clock & ordering across async agents.** Events are ordered primarily by **logical time (01)**, but logical clocks give a partial order; concurrent events across decorrelated agents may be incomparable. Open: is the 01 logical clock sufficient to *totally* order the causal chain for reconstruction, or is a hybrid logical clock (HLC) needed to break ties deterministically for human-readable timelines? Reference 01's logical-time model.
5. **Sentinel authority boundary.** §3.3 keeps Sentinels advisory (alerts → reputation/tier, structural change via consensus). Open: which automatic responses (e.g. emergency deopt on a trap storm) may a Sentinel trigger *without* a consensus round, and how is that emergency power bounded and itself audited? Cross-ref 05 (trap contract) and 08.
6. **Embargo window vs. liveness.** §3.9 embargoes blind-vote telemetry until a round closes to protect decorrelation. Open: how does this interact with real-time operator dashboards that want to watch consensus *as it happens* — is there a privileged human-only view that doesn't feed back into agent decisions, and does exposing it to a human risk an out-of-band correlation channel?
7. **Coverage-ratio semantics for novel harnesses.** §3.5's `coverage_ratio` presumes a *declared* capability to divide by. Open: how is coverage defined for a harness that under-declares (emits *more* than promised) or whose capability drifts mid-session?

---

## 6. Relationships to other specs

- **00-overview** — Canonical anchor. This plane is §2's fifth (cross-cutting) plane; it operationalizes principle §6.6 (*record everything; monitoring is first-class*) and §6.5 (*close the loop, measure the error*). Reuses `Hash`, `AgentId`, `LogicalTime`, `Signature`, `ErrorVector`, `CapabilitySet`, `Tier`, `Commit` verbatim.
- **01-state-model** — Telemetry **joins** the Merkle DAG via `CommitHash` rather than duplicating it; uses 01's **logical time** as the primary ordering key. The event-log-vs-Merkle-storage question (§5.2) and the clock-ordering question (§5.4) both defer to 01.
- **02-consensus** — Consumes `Proposal`/`Vote`/`Decision`; transports `Decision.dispersion` as the authoritative `divergence` signal; **protects** the blind-vote decorrelation invariant via the embargo (§3.9). Sentinel alerts feed reputation, which 02 uses to weight votes.
- **03-control-loop** — The PID estimators are a **named first-class consumer** (§3.4). Observability supplies every `ErrorVector` component as a control metric and emits `ErrorVectorSampled` / `ControlActionEmitted`, closing the loop's telemetry seam (`derived_from`).
- **04-runtime-and-harness** — Harness telemetry is **best-effort**, governed by 04's `CapabilitySet` negotiation, which observability reuses (does not re-invent) for graceful degradation (§3.5). Backends (`RustActorBackend`, `KubernetesCrdBackend`) are tap sources (§2.2).
- **05-agent-jit** — Emits `TrapFired`/`DeoptOccurred`/`TierPromoted`/`TierDemoted` and `exec.trap_rate`; Sentinels' trap-rate monitor feeds **tier demotion** here (§3.3). The Compiler observes stable behavior *through this plane's* spans/metrics.
- **06-interaction-and-mailbox** — Roots every causal chain at `InstructionReceived`/`GoalNormalized`; the mailbox-block duration (`interaction.question_blocked_seconds`) feeds the PID **latency** dimension; instruction-content privacy (§5.3) is shared with 06.
- **08-trust-and-security** — Spine events are **signed** (audit-grade); Sentinel alerts feed **reputation** decay; instruction-privacy and Sentinel-authority bounds (§5.3, §5.5) are shared with 08. Sentinels are the watch role from taxonomy §3, but remain inside the constitutional loop (no direct state mutation).
