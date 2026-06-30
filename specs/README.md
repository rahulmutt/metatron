# Metatron — Specifications

**Metatron** is a principled, extensible orchestration platform for multi-agent systems — "Kubernetes for agents." It is governed by a *council* of agents that reach consensus over how the system evolves, treats LLM-backed agents as a probabilistically-Byzantine substrate to be engineered around, and steers itself toward a user's target with a multi-variable PID controller. The core is implemented in **Rust**.

This directory is a **research architecture specification**: a principled, complete conceptual design that captures the full vision with rigor, even where parts are not yet implementable.

> New here? Read **[`00-overview.md`](./00-overview.md)** first — it defines the vocabulary, the planes, the agent taxonomy, the closed loop, and the canonical shared types every other spec builds on. Everything else assumes it.

---

## The system at a glance

```
┌─────────────────────────────────────────────────────────────┐
│  INTERACTION PLANE   user instructions in · ambiguity mailbox │   06
├─────────────────────────────────────────────────────────────┤
│  GOVERNANCE PLANE    consensus · typed proposals · PID        │   02, 03
├─────────────────────────────────────────────────────────────┤
│  STATE PLANE         layered world-model · Merkle DAG         │   01
├─────────────────────────────────────────────────────────────┤
│  EXECUTION PLANE     harness orchestration · JIT tiers        │   04, 05
├─────────────────────────────────────────────────────────────┤
│  OBSERVABILITY PLANE traces/metrics/events across all planes  │   07
└─────────────────────────────────────────────────────────────┘
   cross-cutting: trust & identity (08) · external-tool gateway (09)
```

**The closed loop:** user instruction → Guardian normalizes it into a goal → Genesis council deliberates and votes on a typed proposal → on accept, a signed commit advances the Merkle head → the execution plane reconciles reality toward desired state → observability measures the gap → the PID controller turns the measured error vector into the next proposal. A deliberative, control-theoretic governor wrapped around Kubernetes-style reconciliation.

---

## Reading order

The specs are layered; each builds on the ones above it. This is the recommended path:

| # | Spec | What it covers | Read it to understand… |
|---|------|----------------|------------------------|
| **00** | [overview](./00-overview.md) | Vision, five planes, agent taxonomy, closed loop, principles, **glossary**, **canonical types** | The whole system and its shared vocabulary |
| **01** | [state-model](./01-state-model.md) | Layered world-model (config + progress), content-addressed Merkle DAG, typed diffs, signed commits, logical time | What "the system state" *is* and how it's versioned |
| **02** | [consensus](./02-consensus.md) | Probabilistic-Byzantine framing (Condorcet), the 6-layer protocol: typed → verify → blind vote → reputation-weight → bounded deliberation → posterior+dispersion | How agents agree on a state change despite being unreliable |
| **03** | [control-loop](./03-control-loop.md) | Multi-variable PID, the error-vector dimensions + estimators, advisory-actions-through-governance boundary, stability engineering | How the system *steers itself* toward the user's target |
| **04** | [runtime-and-harness](./04-runtime-and-harness.md) | `AgentHarness` abstraction (Claude Code, Codex, …), capability negotiation, `ExecutionBackend` (Rust actors \| K8s CRDs), reconciliation | Where agents actually run |
| **05** | [agent-jit](./05-agent-jit.md) | Tier 0/1/2 with deopt traps, Compiler vs Sentinel roles, equivalence/safety, the JIT analogy | How stable agents get compiled to cheap deterministic code |
| **06** | [interaction-and-mailbox](./06-interaction-and-mailbox.md) | Multi-user intake, goal→setpoint, the two-step ambiguity gate, blocking-until-answered mailbox API | How the system talks to its users |
| **07** | [observability](./07-observability.md) | Trace/metric/event model, end-to-end causal correlation, Sentinel + PID-estimator feeds | How "monitor everything" is made real |
| **08** | [trust-and-security](./08-trust-and-security.md) | Identity, signing, reputation, sandboxing, Byzantine response, **agent identity & external-tool authorization** | How the system trusts (and distrusts) its own agents |
| **09** | [mcp-auth-proxy](./09-mcp-auth-proxy.md) | User-deployed gateway-only MCP broker; privilege separation, gated discovery, two-layer authz, fail-closed/HA | How agents safely act in the world without holding secrets |

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
| **Sentinel** | *Watch* | Detect drift/off-protocol behavior; feed reputation, observability, the PID divergence signal |

Guardian + Genesis are the privileged **kernel**; the rest are dynamic and governed by consensus. The taxonomy itself *is* the configuration layer of the state.

---

## Key design decisions

The forks that shape everything else (see each spec's *Resolved decisions* section for the full rationale):

- **Consensus** — tame nondeterminism by *constraining* the output space (typed proposals), *verifying* deterministically before voting, and *decorrelating* agents (diverse harnesses, blind voting) per the Condorcet jury theorem.
- **Liveness** — tiered by blast radius: low-stakes/reversible work proceeds after a timeout; high-stakes (constitutional, irreversible, costly) blocks for a human.
- **Reputation** — class-prior with decay; calibrated against ground truth; bounded slashing.
- **JIT autonomy** — scaled by blast radius: Tier-1 autonomous, Tier-2 needs consensus, emergency demotes act-then-ratify.
- **Tenancy** — multi-user from the start (per-user mailboxes, principals, authorization scopes).
- **Identity** — SPIFFE/SPIRE + a Metatron workload attestor; `AgentId` decoupled from a short-lived rotatable key; **hybrid post-quantum** crypto (`Ed25519+ML-DSA`, `X25519+ML-KEM`).
- **Trust root** — threshold-of-founders; offline root CA → SPIRE intermediate issuer.
- **External actions** — gateway-only `mcp-auth-proxy`: agents never hold downstream secrets; every privileged call is brokered, scoped from governed state, and audited.

---

## Open research questions

Deliberately unresolved (genuine research, not gaps) — each lives in its spec's *Open questions* section:

- A tractable **formal stability proof** for the control loop on a nonstationary plant (`03`)
- The precise **equivalence metric** between a stochastic LLM policy and synthesized deterministic code (`05`)
- A **correlation-aware vote aggregation** formula (independence is only approximate) (`02`)
- The **target-scale telemetry budget** — affordability of the never-sampled spine at large org-charts (`07`)
- **Guardrails on learned setpoints** so revealed-preference learning can't drift unsafe (`03`)
- **Cross-user conflict arbitration** when authorized users issue contradictory instructions (`06`)

---

## Conventions

- Each subsystem spec follows: **Purpose → Concepts → Detailed design → Interfaces/schemas → Resolved decisions → Open questions → Relationships.**
- Code blocks are **Rust-flavored pseudotypes**; the normative shared types live in [`00-overview.md` §7](./00-overview.md).
- When any spec disagrees with `00` on vocabulary or a shared type, **`00` wins.**
- Status: research architecture **v0.1**. Not yet an implementation plan — see a spec's *Open questions* before building against it.
