# Metatron — Specifications

**Metatron** is a principled, extensible orchestration platform for multi-agent systems — "Kubernetes for agents." It is governed by a *council* of agents that reach consensus over how the system evolves, treats LLM-backed agents as a probabilistically-Byzantine substrate to be engineered around, and steers itself toward a user's target on a measured error vector. The core is implemented in **Rust**.

> **The core idea, in one sentence:** a *deliberative governor wrapped around a reconciliation loop* — changes are **authored by one set of agents (Guardians) and decided by a separate council (Genesis)** (*propose ≠ dispose*), and **anything machine-checkable is verified deterministically before anyone votes** (*verify-before-vote*). Everything else — control-theoretic steering, an optimizing JIT, the Condorcet jury, the Merkle/identity layer — is *implementation framing* layered on that core, and is **skippable on first read**. See the [minimal mental model](#minimal-mental-model) below and the load-bearing table in [`00` §1](./00-overview.md).

This directory is a **research architecture specification**: a principled, complete conceptual design that captures the full vision with rigor, even where parts are not yet implementable.

> New here? Read **[`00-overview.md`](./00-overview.md)** first — it defines the vocabulary, the planes, the agent taxonomy, the closed loop, and the canonical shared types every other spec builds on. Everything else assumes it.

---

## The system at a glance

```
┌─────────────────────────────────────────────────────────────┐
│  INTERACTION PLANE   user instructions in · ambiguity mailbox │   06
├─────────────────────────────────────────────────────────────┤
│  GOVERNANCE PLANE    consensus · typed proposals · steering   │   02, 03
├─────────────────────────────────────────────────────────────┤
│  STATE PLANE         layered world-model · Merkle DAG         │   01
├─────────────────────────────────────────────────────────────┤
│  EXECUTION PLANE     harness orchestration · JIT tiers        │   04, 05
├─────────────────────────────────────────────────────────────┤
│  OBSERVABILITY PLANE traces/metrics/events across all planes  │   07
└─────────────────────────────────────────────────────────────┘
   cross-cutting: trust & identity (08) · external-tool gateway (09)
```

**The closed loop:** user instruction → Guardian normalizes it into a goal → for consequential changes, the Genesis council deliberates and votes on a typed proposal (routine/reversible advances skip full consensus — single Guardian + post-hoc audit) → on accept, a signed commit advances the Merkle head → the execution plane **reconciles** reality toward desired state → observability measures the gap → the **steering loop** turns the measured error vector into the next proposal. Two nested loops: the **steering loop** (governance) moves *desired* state and is wrapped *around* the **reconciliation loop** (execution), which moves *actual* state toward the committed desired state.

---

## Minimal mental model

*Hold this much before opening any domain spec; the rest is detail.*

1. **The system state is a versioned object.** It has two layers — a **configuration layer** (which agents exist and how they're wired) and a **progress layer** (work toward the goal). Every change is a typed, signed diff appended to a single content-addressed log. (`01`)
2. **Changes are proposed and disposed by *different* agents.** **Guardians** (user-facing) author typed proposals; the **Genesis** council decides them. Proposer ≠ disposer — no agent both authors and ratifies a change. (`00`, `02`, `06`)
3. **Machine-checkable things are checked, not voted on.** Deterministic verification runs *before* any vote; LLM judgment is the fallback for the genuinely subjective. (`02`)
4. **Voting is decorrelated, then weighted.** Diverse agents vote blind (in isolation) before any discussion; votes are weighted by a scalar track-record reputation. Because independence is only approximate, **a correlated, confidently-wrong council is the main residual risk**, watched for explicitly. (`02`, `07`)
5. **Not every change pays for consensus.** Routine/reversible advances run under a single Guardian with post-hoc audit; full consensus is reserved for high-blast-radius/irreversible/constitutional changes. **Unknown reversibility ⇒ escalate to a human.** (`00`, `02`, `06`)
6. **Two nested loops.** The **execution/reconciliation loop** drives reality toward committed desired-state; the **steering loop** (wrapped around it) moves desired-state toward the user's target by emitting proposals from a measured error vector. (`03`, `04`)
7. **Stable agents get cheaper.** A stabilized LLM agent (Tier-0) can be memoized (Tier-1) with a guard that deoptimizes back to the LLM on surprise. (`05`)
8. **Privileged external action is brokered.** Agents never hold downstream secrets; every external call goes through the `mcp-auth-proxy`, scoped from governed state and audited. (`08`, `09`)

Everything else — PID control theory, the optimizing-JIT analogy, the Condorcet jury math, the Merkle DAG and SPIFFE identity machinery — is **framing or implementation detail** layered on the eight points above. See the load-bearing table in [`00` §1](./00-overview.md) for how much of each analogy actually ships.

---

## Reading order

The specs are layered; each builds on the ones above it. This is the recommended path:

| # | Spec | What it covers | Read it to understand… |
|---|------|----------------|------------------------|
| **00** | [overview](./00-overview.md) | Vision, five planes, agent taxonomy, closed loop, principles, **glossary**, **canonical types** | The whole system and its shared vocabulary |
| **01** | [state-model](./01-state-model.md) | Layered world-model (config + progress), content-addressed Merkle DAG, typed diffs, signed commits, logical time | What "the system state" *is* and how it's versioned |
| **02** | [consensus](./02-consensus.md) | Probabilistic-Byzantine framing (Condorcet), the 6-layer protocol: typed → verify → blind vote → reputation-weight → bounded deliberation → posterior+dispersion | How agents agree on a state change despite being unreliable |
| **03** | [control-loop](./03-control-loop.md) | The steering loop: proportional response on a measured error vector + deadband/hysteresis/cooldown (full PID deferred — OE-01), the error-vector dimensions + estimators, advisory-actions-through-governance boundary | How the system *steers itself* toward the user's target |
| **04** | [runtime-and-harness](./04-runtime-and-harness.md) | `AgentHarness` abstraction (Claude Code, Codex, …), capability negotiation, `ExecutionBackend` (Rust actors \| K8s CRDs), reconciliation | Where agents actually run |
| **05** | [agent-jit](./05-agent-jit.md) | Tier 0 + Tier 1 with deopt traps (Tier-2 synthesis deferred — OE-03), Compiler vs Sentinel roles, equivalence/safety, the JIT analogy | How stable agents get compiled to cheap deterministic code |
| **06** | [interaction-and-mailbox](./06-interaction-and-mailbox.md) | Multi-user intake, goal→setpoint, the two-step ambiguity gate, blocking-until-answered mailbox API | How the system talks to its users |
| **07** | [observability](./07-observability.md) | Trace/metric/event model, end-to-end causal correlation, Sentinel + steering-loop-estimator feeds, verification-coverage signal | How "monitor everything" is made real |
| **08** | [trust-and-security](./08-trust-and-security.md) | Identity, signing, reputation, sandboxing, Byzantine response, **agent identity & external-tool authorization** | How the system trusts (and distrusts) its own agents |
| **09** | [mcp-auth-proxy](./09-mcp-auth-proxy.md) | User-deployed gateway-only MCP broker; privilege separation, gated discovery, two-layer authz, fail-closed/HA | How agents safely act in the world without holding secrets |
| **10** | [budgets](./10-budgets.md) | User-defined hierarchical (global→class→agent) stock + rate budgets; reserved-floor+shared-burst allocation; layered depletion enforcement; off-budget deterministic notifier | How the user bounds and scopes spend, and how agents pause/throttle when depleted |

**Cross-cutting:** `07` taps every plane; `08` and `09` thread trust through all of them.

---

## Agent taxonomy

A **separation of powers** — proposer ≠ voter:

| Role | Power | Does |
|------|-------|------|
| **Guardian** | *Propose* | User-facing; normalize instructions, detect ambiguity, author typed proposals |
| **Genesis** | *Dispose* | The council; deliberate + vote; reach consensus over state updates |
| **Worker** | *Execute* | Task-doers, each a role+goal bound to an `AgentHarness` |
| **Compiler** | *Optimize* | Perform JIT tiering; install deopt guards |
| **Sentinel** | *Watch* | Detect drift/off-protocol behavior; feed reputation (k-of-n corroborated), observability, the steering loop's divergence signal |

Guardian + Genesis are the privileged **kernel**; the rest are dynamic and governed by consensus. The taxonomy itself *is* the configuration layer of the state.

---

## Key design decisions

The forks that shape everything else (see each spec's *Resolved decisions* section for the full rationale):

- **Consensus** — tame nondeterminism by *constraining* the output space (typed proposals), *verifying* deterministically before voting, and *decorrelating* agents (diverse harnesses, blind voting) per the Condorcet jury theorem. Independence is only approximate, so this is a **mitigation, not a guarantee** — correlated failure is the headline residual risk, and measured base-model/harness diversity is an operational precondition for quorum independence (ROB-01/ROB-02).
- **Write-path tiering** — full council consensus is reserved for high-blast-radius/irreversible/constitutional changes; routine, reversible advances (worker spawns, progress updates) proceed under a **single Guardian + post-hoc audit** with optimistic concurrency on the head (UX-03).
- **Liveness** — tiered by blast radius: low-stakes/reversible work proceeds after a bounded timeout; high-stakes (constitutional, irreversible, costly) escalates to a human under a **bounded escalation-timeout → hold-and-degrade-safely** policy (never blocks indefinitely, never silently proceeds on irreversible actions; deterministic cross-user precedence breaks ties — UX-04). Council deadlock has a **founder-threshold break-glass** recovery that bypasses the broken quorum (ROB-04).
- **Reputation** — a **scalar track-record weight in [0,1] decaying to a class prior** (OE-05); hard off-protocol behavior is detected mechanically and quarantined via quorum/human escalation, *separate* from the weight. A **burn-in regime** gates autonomy on verification coverage at genesis and after every recomposition, when weights are uncalibrated (ROB-03).
- **JIT autonomy** — scaled by blast radius: Tier-1 autonomous with deopt-to-LLM; **Tier-2 synthesis is deferred** until its equivalence metric exists (OE-03); emergency demotes act-then-ratify.
- **Tenancy** — multi-user from the start (per-user mailboxes, principals, authorization scopes).
- **Identity** — single-node default: **keypair `AgentId` + short-lived orchestrator-signed token + polled revocation list**; SPIFFE/SPIRE + the Metatron workload attestor are **gated behind a multi-cluster trigger** (OE-06). `AgentId` decoupled from a short-lived rotatable key; **hybrid post-quantum** crypto (`Ed25519+ML-DSA`, `X25519+ML-KEM`) kept as the default.
- **Trust root** — threshold-of-founders (also the **break-glass authority** for council-deadlock recovery — ROB-04); offline root CA → SPIRE intermediate issuer, gated behind multi-cluster.
- **External actions** — gateway-only `mcp-auth-proxy`: agents never hold downstream secrets; every privileged call is brokered, scoped from governed state, and **audited with field-redacted structured arguments** (plus an integrity digest — ROB-08). A consensus stall validates SVIDs against the **last-known-good head within a bounded grace window** rather than instantly amputating external action (ROB-05).
- **Budgets** — user-defined budgets are **hierarchical** (global→class→agent) and carry both a **stock** (cumulative) and a **rate** (token-bucket) allowance, denominated in the normalized `CostUnit`. Allocation is **reserved-floor + shared-burst** so kernel governance stays funded under pressure while ephemeral workers run on shared burst; reallocation is a **tiered typed write** (in-pool top-ups fast-path, ceiling/floor changes constitutional). Depletion runs a **layered stop** (soft-threshold → cooperative drain → checkpoint/freeze → hard-cancel backstop; throttle for rate), announced by an **off-budget deterministic notifier** so telling the user "out of budget" never itself needs budget (`10`).

---

## Open research questions

Deliberately unresolved (genuine research, not gaps) — each lives in its spec's *Open questions* section:

- A tractable **formal stability proof** for the control loop on a nonstationary plant (`03`)
- The precise **equivalence metric** between a stochastic LLM policy and synthesized deterministic code (`05`)
- A **correlation-aware vote aggregation** formula (independence is only approximate) (`02`)
- The **target-scale telemetry budget** — affordability of the never-sampled spine at large org-charts (`07`)
- **Guardrails on learned setpoints** so revealed-preference learning can't drift unsafe (`03`)
- **Cross-user *values* arbitration** when authorized users issue contradictory instructions — a deterministic precedence *floor* (authorization rank, then first-committed-wins) now prevents deadlock; the higher-level arbitration policy remains open (`06`)

---

## Conventions

- Each subsystem spec follows: **Purpose → Concepts → Detailed design → Interfaces/schemas → Resolved decisions → Open questions → Relationships.**
- Code blocks are **Rust-flavored pseudotypes**; the normative shared types live in [`00-overview.md` §7](./00-overview.md).
- When any spec disagrees with `00` on vocabulary or a shared type, **`00` wins.**
- Status: research architecture **v0.1**. Not yet an implementation plan — see a spec's *Open questions* before building against it.
