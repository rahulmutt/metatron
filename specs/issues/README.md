# Spec Review — Tracked Issues

Issues raised by the adversarial design review of `specs/*.md` (2026-06-30). The review judged the spec set against two competing goods — **robustness** and **simplicity/usability** — and specifically hunted for **overengineering**.

Each issue was produced by a per-spec reviewer, **steelmanned by a skeptic** (verdict `CONFIRMED` / `SOFTENED` / `REJECTED`), and synthesized. Only `CONFIRMED`/`SOFTENED` findings are tracked here; rejected critiques were dropped.

> These are **design issues against a v0.1 research architecture**, not implementation bugs. Resolving an issue may mean editing a spec, recording a deliberate deferral, or downgrading machinery to the lean alternative.

## Conventions

- One file per issue: `<CATEGORY>-<NN>-<slug>.md`.
- Frontmatter fields: `id`, `title`, `severity`, `category`, `status`, `affected_specs`, `review_verdict`.
- `status` lifecycle: `open` → `in-progress` → `resolved` / `wontfix` / `deferred`.
- Categories: `overengineering` (OE), `robustness` (ROB), `usability` (UX).

## Index

### Overengineering — is each piece of machinery *earning* its complexity?

| ID | Severity | Title |
|----|----------|-------|
| [OE-01](./OE-01-pid-controller.md) | high | Multi-variable PID controller on an unmodelable plant |
| [OE-02](./OE-02-post-quantum-default.md) | medium | Hybrid post-quantum crypto mandated as the default now |
| [OE-03](./OE-03-tier2-jit-synthesis.md) | high | Tier-2 JIT code synthesis trusts an undefined equivalence metric |
| [OE-04](./OE-04-merkle-dag-store.md) | medium | Hand-rolled Merkle DAG storage engine for a linear log |
| [OE-05](./OE-05-reputation-economy.md) | medium | Reputation modeled as an adaptive-control economy for 5–7 voters |
| [OE-06](./OE-06-spiffe-spire-pki.md) | medium | SPIFFE/SPIRE + custom attestor + offline root CA for a single node |

### Robustness — does it hold up under Byzantine agents, partial failure, scale?

| ID | Severity | Title |
|----|----------|-------|
| [ROB-01](./ROB-01-confident-collective-error.md) | critical | Confident collective error is invisible to the feedback loop |
| [ROB-02](./ROB-02-voter-independence-false.md) | high | Tolerance claim rests on voter independence admitted false elsewhere |
| [ROB-03](./ROB-03-reputation-inert-at-genesis.md) | high | Reputation is inert exactly when stakes are highest |
| [ROB-04](./ROB-04-council-self-repair-deadlock.md) | high | Council self-repair must be ratified by the broken council |
| [ROB-05](./ROB-05-consensus-stall-amputation.md) | high | Consensus stall amputates the external-action plane in minutes |
| [ROB-06](./ROB-06-sentinel-consensus-sidedoor.md) | high | Sentinels are a single-agent side door into consensus weighting |
| [ROB-07](./ROB-07-reversibility-classifier-undefined.md) | high | Blast-radius reversibility classifier is undefined yet gates autonomy |
| [ROB-08](./ROB-08-audit-arg-digest-only.md) | medium | Audit records only an arg-digest, defeating forensics |
| [ROB-09](./ROB-09-mailbox-safe-hold-multigate.md) | high | Mailbox does not state that a node's Blocked state is the conjunction of all its gating Questions |

### Usability — can a competent engineer hold the model in their head?

| ID | Severity | Title |
|----|----------|-------|
| [UX-01](./UX-01-five-vocabularies.md) | high | Five expert vocabularies make the model un-teachable |
| [UX-02](./UX-02-reconciliation-overloaded.md) | high | "Reconciliation" names two different nested loops |
| [UX-03](./UX-03-governance-throughput-bottleneck.md) | high | Full consensus on every diff is the throughput bottleneck |
| [UX-04](./UX-04-human-block-deadends.md) | medium | Many paths dead-end at "block until a human answers" |
| [UX-05](./UX-05-false-plane-role-grid.md) | low | Five planes / five roles invite a false 1:1 grid |
| [UX-06](./UX-06-agentnode-co-owned.md) | low | AgentNode is co-owned by all five planes |
