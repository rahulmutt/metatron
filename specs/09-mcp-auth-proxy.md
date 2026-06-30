# Metatron — The MCP Auth Proxy

> **Status:** Research architecture specification (v0.1)
> **Audience:** System designers and implementers of Metatron.
> **Scope:** This spec defines the **`mcp-auth-proxy`** — a **separately-deployed** component, with its **own trust boundary**, that lets Metatron agents perform privileged external actions through MCP servers **without ever holding downstream secrets**. It is the brokering gateway through which *all* outbound, privileged tool use flows. It builds directly on the identity, signing, capability, and Byzantine-response machinery of `08-trust-and-security`, and joins its audit trail to the causal chain of `07-observability`.
>
> Where this spec and `00-overview` disagree on a shared type or term, **`00-overview` wins**. Where it elaborates `08`, it reuses `08`'s names and shapes verbatim; it does not redefine them.

---

## 1. Purpose

Metatron agents are an **unreliable, probabilistically-Byzantine substrate** (`00 §1`, `08 §1`). The whole architecture is built to bound the blast radius of an agent that drifts, hallucinates, or is outright compromised. `08` bounds the blast radius *inside* the system: a leaked Worker key buys only that Worker's capabilities, never kernel power (`08 §3.1`). This spec extends the same discipline to the **most dangerous surface of all — privileged action in the outside world**: sending email, opening pull requests, moving money, paging a human, writing to a production database.

The naïve design hands each Worker the downstream credentials it needs (an API token, an OAuth refresh token, a database password) so its harness can call out directly. That design is catastrophic under Metatron's own threat model: a single prompt-injected or compromised harness (`08` T3, T4) now holds **standing secrets** to external systems, and compromise is **unbounded in time and scope** — the attacker keeps the token until a human notices and rotates it everywhere.

The `mcp-auth-proxy` exists to make that failure mode impossible by construction. Its **first principle** is:

> **Privilege separation.** An agent's *only* long-term secret is its own identity key (`08 §3.1`). It holds **zero** downstream credentials. **All** privileged external access is **brokered**. Compromising an agent therefore never compromises a standing secret — the worst case is bounded to that agent's **currently-authorized, short-lived scopes**, which are **instantly revocable**.

This converts "a compromised agent leaks a permanent credential to system X" into "a compromised agent can, for at most one short SVID lifetime, invoke exactly the tools its role was already authorized for — and is cut off the moment it is quarantined." That is the same move `08` makes for internal authority (price and bound, don't trust), applied to the external blast radius.

**Design stance.** This is not a perimeter bolted on; it is the same loop. We *constrain* what an agent can express to the outside world (a typed `McpToolCall` against a gated, virtual tool surface), *verify* authorization deterministically before we broker (two-layer authz derived from governed state), *bound* the blast radius (short-lived scoped SVIDs, no standing secrets), *fail closed* (no proxy ⇒ no privileged action), and *record immutably* (every brokered call is a signed telemetry event on the causal chain). Privileged action becomes a **first-class, monitored, governed** operation rather than a side effect a harness performs in the dark.

---

## 2. Concepts

| Concept | Meaning in Metatron |
|---|---|
| **Privilege separation** | The architectural invariant that agents hold no downstream secrets; the proxy holds them all and brokers every use. The core property this spec delivers. |
| **`mcp-auth-proxy` (the proxy / the gateway)** | A separately-deployed service, **deployed by the user**, that presents one virtual MCP surface to agents and brokers their tool calls to many real downstream MCP servers, injecting credentials from its own vault. Its own trust boundary, distinct from Metatron core. |
| **Brokering** | The act of receiving an agent's tool call bearing *no* downstream credential, authorizing it, attaching the correct downstream credential from the vault, executing it against the downstream server, and returning the *result only* (never the credential) to the agent. |
| **MCP-multiplexing gateway** | The proxy is not merely a token broker. It speaks MCP **natively** and **aggregates** many downstream MCP servers behind a single endpoint — initialization, tool discovery, tool invocation, streaming, long-running calls — routing each call to the right server. |
| **Virtual / unified MCP surface** | The single, aggregated, per-identity-filtered tool catalog an agent sees. It is *synthesized* by the proxy from the downstream servers the agent's role is authorized for; tools outside that authorization are **not discoverable** at all. |
| **SVID** | Short-lived, hybrid-PQ identity document an agent presents over mTLS to authenticate to the proxy. SPIFFE-style. Carries the agent's `AgentId`, an operational key, coarse `Scope` claims, and an expiry. Extends `08 §3.1` identity. |
| **Scope** | A coarse, SVID-borne authorization claim: `{ resource: McpServerId, methods: Vec<MethodPattern> }`. Governed by the configuration layer (`01`). The *first* of two authorization layers. |
| **Downstream MCP server** | A real, external MCP server (`McpServerId`) the proxy routes to — e.g. a GitHub MCP server, a Stripe MCP server, an internal ops server. Has an endpoint and a credential reference in the routing table. |
| **Vault** | The proxy's own credential store, holding the **user's** downstream secrets. The single place standing secrets live. Metatron core never reads it. |
| **SPIFFE federation** | The trust relationship by which the proxy accepts Metatron-issued SVIDs: the proxy is configured with Metatron's identity-issuer **trust bundle** and verifies SVIDs against it, without Metatron and the proxy sharing a single CA. |
| **Fast revocation list** | A frequently-polled list of `AgentId`s (and SVID serials) the proxy must stop honoring immediately — fed by `08`'s quarantine/emergency-revocation (`08 §3.6`, Open Q #1, #9). |
| **Fail-closed** | The proxy is on the hot path of every external action; if it is unreachable, agents get **no** privileged access. No proxy ⇒ no privileged action is the *safe* default. |
| **Response filtering / DLP** | Optional policy on the *return* path: redact, mask, or block fields in a downstream result before the agent ever sees them (e.g. strip PII, cap row counts). |

### 2.1 Where the proxy sits — a new trust boundary

`08 §2.1` drew Metatron's internal trust boundaries (user → Guardian, harness → state plane). This spec adds the **external action boundary**, and crucially it splits trust across **two separately-owned domains**:

```
        METATRON CORE (asserts identity)           │   mcp-auth-proxy (holds secrets)    │   THE OUTSIDE WORLD
        ── never holds downstream secrets ──        │   ── user-deployed; own vault ──    │
                                                    │                                     │
   Worker harness                                   │                                     │
    │  needs to act externally                      │                                     │
    │                                               │                                     │
    ▼  MCP client, single endpoint                  │                                     │
  ┌──────────────┐   hybrid-PQ mTLS   ┌─────────────┴──────────┐   inject downstream      │
  │ agent's MCP  │ ─────────────────▶ │  mcp-auth-proxy        │   credential from vault   │
  │ client       │   presents SVID    │  · verify SVID (fed.)  │ ────────────────────────▶ │  GitHub MCP
  │ (no secrets) │ ◀───────────────── │  · check revocation    │   downstream MCP (mTLS/   │  Stripe MCP
  └──────────────┘   result only      │  · gate discovery      │    OAuth/API key)         │  Ops MCP
                     (never a token)   │  · two-layer authz     │ ◀──────────────────────── │  ...
                                       │  · route + multiplex   │   downstream result       │
        identity-issuer ──trust────────┤  · DLP on return path  │                           │
        (Metatron) bundle  bundle      │  · emit audit → 07     │                           │
                          (federation) └────────────┬──────────┘                           │
  ──────────────────────────────────────────────────┼─────────────────────────────────────┼──────────
   Left of the first line: Metatron asserts *signed agent identity + scopes* and nothing more.
   Middle: the user's proxy is the ONLY holder of standing downstream secrets.
   The proxy trusts Metatron via SPIFFE federation; it trusts agents only for one short SVID lifetime.
```

Two rules govern this boundary, extending `08`'s R1/R2:

- **R3 — Broker, never bear.** No agent ever receives a downstream credential. Credentials are attached by the proxy at call time and stripped from every response. The agent's reachable surface contains tool *results*, never tool *secrets*.
- **R4 — Authorize against governed state, not against the bearer's claim alone.** An SVID scope claim is *necessary* but not *sufficient*: the gateway re-checks each call against fine-grained policy derived from the same consensus-governed configuration state, and against the live revocation list, before brokering.

---

## 3. Detailed design

### 3.1 Privilege separation, made concrete

The invariant from `§1`, stated operationally:

| Property | Mechanism |
|---|---|
| Agent holds **one** long-term secret (its identity key) | `08 §3.1`: the signing `SecretKey` lives in the agent's isolation boundary and never leaves it. *Nothing else* long-term is issued to the agent. |
| Agent holds **zero** downstream credentials | Downstream secrets live only in the proxy's vault (`§3.6`). They are never minted into a `CapabilitySet`, never serialized into a commit or telemetry, never handed to a harness. |
| Compromise is **bounded in scope** | A compromised agent can invoke only the tools in its current SVID scopes ∩ gateway policy (`§3.4`) — exactly what its role was already authorized for. It cannot widen this (no self-elevation, `08 §3.5`). |
| Compromise is **bounded in time** | SVIDs are short-lived (`not_after`, minutes-scale). A stolen SVID expires on its own; a stolen *identity key* still only yields SVIDs the issuer will mint for that (possibly already-quarantined) agent. |
| Compromise is **instantly revocable** | Quarantine/removal (`08 §3.6`) propagates to the proxy via the fast revocation list (`§3.7`) within one short SVID TTL — without rotating a single downstream secret. |

The decisive contrast with the naïve design:

| Naïve (agent holds the token) | Metatron (proxy brokers) |
|---|---|
| Compromise leaks a **standing** secret to system X. | Compromise leaks nothing; the secret never left the vault. |
| Blast radius = everything that token can do, **forever**, until a human rotates it. | Blast radius = the agent's authorized scopes, for **≤ one SVID TTL**, auto-expiring. |
| Containment = rotate the credential in system X (slow, manual, system-specific). | Containment = quarantine the agent (`08 §3.6`); revocation list cuts it off. **No downstream rotation needed.** |
| Each new external system multiplies standing-secret exposure across N agents. | Secrets are centralized in one hardened, user-owned vault; agents stay credential-free. |

### 3.2 The gateway is an MCP multiplexer (not just a token broker)

**Locked decision.** Agents do **not** ask the proxy for a token and then call downstream themselves. They point their MCP client at the proxy as their **single MCP endpoint**. The proxy *is* an MCP server to the agent and an MCP *client* to each downstream server. It must therefore speak MCP **natively** on both sides:

- **Initialization / capability negotiation** — the agent performs the MCP `initialize` handshake against the proxy; the proxy advertises the union of downstream capabilities it is willing to expose to *this* identity.
- **Tool discovery** — the proxy returns a **filtered, aggregated** `ToolList` (`§3.3`).
- **Tool invocation** — the proxy receives an `McpToolCall`, routes it, injects the credential, executes, and returns an `McpResult`.
- **Streaming & long-running calls** — the proxy proxies progressive/streamed results and keeps long-running downstream calls alive, relaying progress to the agent. (Breadth of coverage across heterogeneous servers is an Open Question, `§6`.)
- **Resumable sessions** — where a downstream server supports session resumption, the proxy maps the agent-facing session to the downstream session and re-injects credentials transparently on resume.

```
 agent MCP client                  mcp-auth-proxy                         downstream MCP servers
 ────────────────                  ──────────────                         ──────────────────────
   initialize ───────────────────▶ verify SVID, check revocation
                                    advertise per-identity capabilities
   ◀──────────────────────────────  initialize result
   tools/list ───────────────────▶ aggregate downstream catalogs
                                    FILTER to authorized scopes  ◀──────── (cached tool catalogs)
   ◀──────────────────────────────  ToolList  (only authorized tools)
   tools/call {server::tool} ─────▶ resolve route → McpServerId
                                    two-layer authz check
                                    fetch credential from vault ──────────▶ tools/call (+ injected cred)
                                    (stream/long-running relay) ◀────────── progress / result
                                    DLP on return path
   ◀──────────────────────────────  McpResult  (no credential)
                                    emit BrokeredCallStarted/Finished → 07
```

The **virtual tool name** an agent sees is namespaced by routing key, e.g. `github::create_pull_request`, so a single flat catalog can address many downstream servers unambiguously. The proxy owns the `virtual_tool ↔ (McpServerId, downstream_tool)` mapping (`§3.5`).

### 3.3 Gated capability discovery (per-identity tool filtering)

**Locked decision.** Discovery is **gated**. The proxy aggregates every downstream server's tool catalog, then **filters it per identity** before returning it. An agent sees **only** the tools its role is authorized for; unauthorized tools are **not even discoverable** — they do not appear in `discover_tools`, and a call naming one is rejected as if it does not exist.

This is least privilege (`08 §3.5`) applied to *visibility*, not just to invocation. It matters for two reasons:

1. **Smaller attack surface for a confused/compromised agent.** A prompt-injected harness cannot be steered toward a dangerous tool it was never shown; the tool is outside its world model.
2. **No information leak about the user's footprint.** The mere *existence* of a `stripe::create_refund` tool is itself sensitive. Gating discovery prevents one agent from enumerating capabilities provisioned for another role.

```
   aggregated downstream catalog            per-identity filter            ToolList returned to agent A
   ────────────────────────────             (Scope ∩ gateway policy)       ───────────────────────────
   github::create_pull_request   ┐          A.role authorizes:             github::create_pull_request
   github::merge_pull_request    │  ──────▶  github::{create_pull_*,   ──▶ github::list_issues
   github::list_issues           │           list_*}                        (merge_pull_request HIDDEN)
   stripe::create_refund         │           (stripe: none)                 (all stripe::* HIDDEN)
   stripe::get_balance           ┘
```

Filtering uses the **same** two-layer logic as invocation (`§3.4`) so discovery and enforcement can never disagree: a tool is discoverable iff a call to it would be authorized.

### 3.4 Two-layer authorization

**Locked decision.** Authorization is enforced at **two layers**, and a call must pass **both**.

**Layer 1 — coarse scope claims, carried in the SVID, governed by the configuration layer.**
The SVID an agent presents carries `scopes: Vec<Scope>` where each `Scope { resource: McpServerId, methods: Vec<MethodPattern> }`. These are minted by Metatron's identity-issuer **from the agent's role and grants in the configuration layer** (`01`/`08 §3.1`). They are coarse — "this agent may touch the `github` server's `create_*`/`list_*` methods" — and they ride *inside* the signed SVID, so the proxy can check them with no call back to Metatron.

**Layer 2 — fine per-tool/per-method enforcement, at the gateway, against policy derived from the same governed state.**
Scope is necessary, not sufficient (R4). At call time the gateway evaluates a **fine-grained policy** — per tool, per method, optionally per-argument (e.g. "refund ≤ \$X", "PRs only against repos in set R") — that is **derived from the same consensus-governed configuration state**. Granting a privilege is therefore a **consensus-approved state diff** (`00 §3`, "the taxonomy is state"; `08 §3.5`, "privilege is a state lookup, not a token"). The gateway is the enforcement point; the *governed state* is the source of truth that produces both the SVID scopes (Layer 1) and the gateway policy (Layer 2). They share a root, so they cannot drift.

```
   consensus-governed configuration state (01)
        │                              │
        │ projected to                 │ projected to
        ▼ (issuer)                     ▼ (policy distribution, §3.7)
   SVID.scopes  (coarse)          gateway PolicyBundle  (fine)
        │                              │
        └──────────────┬───────────────┘
                       ▼   a call is brokered IFF
         (1) target tool ∈ some SVID Scope (resource+method match)   ── Layer 1
       ∧ (2) call satisfies the fine PolicyRule for that tool        ── Layer 2
       ∧ (3) agent NOT on the fast revocation list (§3.7)
       ∧ (4) SVID not expired (not_after) and signature valid (federation, §3.8)
       ⇒ fetch credential, route, invoke; else DENY (fail-closed) + audit
```

```rust
/// Coarse claim minted into the SVID from governed config state.
struct Scope { resource: McpServerId, methods: Vec<MethodPattern> }

/// A glob/prefix matcher over MCP method/tool names, e.g. "create_*", "issues.list".
struct MethodPattern(String);

/// Fine, per-tool policy evaluated at the gateway. Derived from the SAME governed state.
struct PolicyRule {
    server: McpServerId,
    tool: ToolName,
    guard: ArgGuard,            // predicate over the call's structured arguments
    dlp: Option<DlpPolicy>,     // return-path filtering for this tool (§3.5)
    step_up: Option<StepUpPolicy>, // optional per-call elevation for dangerous tools (Open Q, §6)
}
enum ArgGuard {
    Allow,                      // any args
    Deny,
    Predicate(CelExpr),         // e.g. amount <= 5000 && currency == "USD"
}
struct PolicyBundle {
    version: Hash,              // content address; ties back to the governing config commit (01)
    rules: Vec<PolicyRule>,
}
```

**Optional return-path DLP.** On the way back, the gateway may apply a `DlpPolicy` to the `McpResult` — redacting fields, masking PII, capping result size, or blocking entirely on a match — before the agent sees anything (`§3.5`). DLP is part of the same governed policy, so what an agent may *see* is governed exactly like what it may *do*.

### 3.5 Routing, multiplexing, and the credential-injection path

The proxy holds a **routing table** keyed by `McpServerId`. Each entry binds a virtual surface to a real downstream endpoint plus a **reference** (never the value) into the vault:

```rust
type McpServerId = String;     // stable logical id, e.g. "github", "stripe-prod"
type ToolName    = String;     // downstream tool name, e.g. "create_pull_request"

struct RouteEntry {
    server: McpServerId,
    endpoint: DownstreamEndpoint,    // url + transport (stdio | http+sse | ws)
    credential: CredentialRef,       // POINTER into the vault — never the secret itself
    auth_kind: DownstreamAuthKind,   // how the credential is attached to the downstream call
    capabilities: Vec<ToolName>,     // discovered/cached downstream tool catalog
    health: ServerHealth,            // for HA routing & fail-closed decisions (§3.9)
}

struct DownstreamEndpoint { url: Url, transport: McpTransport }
enum   McpTransport { Stdio, HttpSse, WebSocket }

enum DownstreamAuthKind {
    BearerToken,                 // Authorization: Bearer <vault>
    OAuth2 { refresh: bool },    // proxy manages refresh/expiry internally (Open Q, §6)
    ApiKeyHeader { header: String },
    Mtls,                        // proxy presents a client cert from the vault
    Custom(String),
}

struct RoutingTable { routes: BTreeMap<McpServerId, RouteEntry> }

/// virtual_tool ("github::create_pull_request") -> (server, downstream tool name)
fn resolve(table: &RoutingTable, virtual_tool: &str) -> Option<(McpServerId, ToolName)>;
```

The **injection path** for one brokered call:

```
1. agent → proxy:   McpToolCall { tool: "github::create_pull_request", args, … }  (over mTLS, SVID)
2. authz:           Layer-1 scope ∧ Layer-2 policy ∧ revocation ∧ SVID validity   (§3.4)  ── else DENY
3. resolve:         "github::create_pull_request" → (server="github", tool="create_pull_request")
4. vault fetch:     CredentialRef → ephemeral, in-memory secret material (§3.6)
5. attach:          per DownstreamAuthKind (Bearer header | mTLS client cert | OAuth access token)
6. invoke:          proxy (as MCP client) → downstream server; relay streaming/long-running progress
7. DLP:             apply RouteEntry/PolicyRule DlpPolicy to the result                  (§3.4)
8. strip+return:    McpResult to agent — credential material zeroized, NEVER serialized back
9. audit:           BrokeredCallFinished → 07, joined to the causal chain (§3.10)
```

The credential exists in proxy memory only for the duration of step 5, is never logged, never placed in the `McpResult`, and is zeroized after attach.

### 3.6 The vault (downstream credential store)

The vault is the **single place standing downstream secrets live**, and it belongs to the **user**, not to Metatron core (`§3.8`). It is addressed by reference, never by value, everywhere else in the design.

```rust
/// Opaque, stable handle to a secret. Appears in the routing table and policy; the
/// secret VALUE is never embedded, logged, committed, or returned.
struct CredentialRef(String);   // e.g. "vault://github/app-token"

/// The proxy's credential store. A trait so the user can back it with their own KMS/secret manager.
trait CredentialVault {
    /// Resolve a reference to ephemeral, in-memory secret material. Caller must zeroize.
    fn fetch(&self, r: &CredentialRef) -> Result<SecretMaterial, VaultError>;

    /// Rotate/refresh a managed credential (e.g. OAuth refresh -> new access token).
    /// Refresh/expiry management is internal to the proxy (Open Q, §6).
    fn refresh(&self, r: &CredentialRef) -> Result<(), VaultError>;

    /// Health/availability for fail-closed decisions (§3.9).
    fn status(&self, r: &CredentialRef) -> CredentialStatus;
}

struct SecretMaterial(/* opaque, zeroized on drop; never serialized */);
enum   CredentialStatus { Valid, Expiring { ttl: LogicalTime }, Expired, Missing }
```

Backing implementations are deliberately pluggable (the user owns this boundary): an in-process sealed store, HashiCorp Vault, a cloud KMS / secret manager, or an HSM. Required invariants, mirroring `08 §3.5`'s secret-key isolation:

- **Reference-only egress.** Only `CredentialRef`s ever leave the vault subsystem in any persisted or transmitted form. `SecretMaterial` lives in memory, briefly, and is zeroized on drop.
- **No path to the agent.** There is no API, tool, or telemetry field through which a downstream secret can reach an agent or a harness. R3 is enforced here.
- **Managed expiry/refresh.** OAuth token refresh and credential expiry are handled *inside* the proxy (`§3.5` `OAuth2{refresh}`), so agents are never involved in a token lifecycle (the precise refresh strategy is an Open Question, `§6`).

### 3.7 Policy distribution & the fast revocation list

The proxy must stay in sync with two streams from Metatron, both **derived from governed state** and both fail-safe:

1. **Policy distribution (slow path).** The fine-grained `PolicyBundle` (`§3.4`) and the routing table's *authorization* projection are derived from the consensus-governed configuration layer (`01`). When a privilege grant is consensus-approved (a state diff lands as a signed `Commit`), the updated `PolicyBundle` — content-addressed by the governing commit — is distributed to the proxy. The proxy verifies the bundle's provenance against the federation trust bundle (`§3.8`).

2. **Fast revocation list (hot path).** The proxy **polls** a frequently-updated revocation list so that an agent quarantined or emergency-revoked by `08`'s Byzantine response (`08 §3.6`, Open Q #1/#9) **stops being honored within one short SVID TTL** — without waiting for SVID expiry and without any downstream rotation.

```rust
/// Polled at a short interval (≪ SVID TTL). Fail-safe: on staleness the proxy honors the
/// last-known-good list within a bounded grace window; recorded revocation always fails
/// closed, mere staleness does not (staleness ≠ revocation, §3.9).
struct RevocationList {
    version: Hash,
    as_of: LogicalTime,
    revoked_agents: BTreeSet<AgentId>,    // quarantined/removed (08 §3.6)
    revoked_svids: BTreeSet<SvidSerial>,  // specific issued credentials
    ttl: LogicalTime,                     // freshness bound; past this, treat as stale
}
type SvidSerial = [u8; 16];

trait RevocationFeed {
    fn poll(&self) -> Result<RevocationList, FeedError>;
}
```

The interplay is the key safety property: **internal containment (quarantine) becomes external containment (no brokered calls) within one SVID TTL, at zero downstream cost.** Quarantine an agent in the configuration layer → it lands on the revocation list → the proxy stops brokering for it → its external blast radius is closed. This is `08 §3.1`'s "instantly revocable, no standing secret to rotate," realized end to end.

### 3.8 Trust link: SPIFFE federation & hybrid-PQ transport

**Who trusts whom.** The proxy is deployed by the **user** and holds the **user's** vault. Metatron core holds **no** downstream secrets; it only **asserts signed agent identity + scopes** (the SVID). These are two separately-owned trust domains, joined by **SPIFFE federation**:

- Metatron runs an **identity-issuer** (a SPIFFE-style authority, extending `08 §3.1` identity and `08` Open Q #1 on rotation) that mints short-lived SVIDs for agents.
- The proxy is configured with Metatron's identity-issuer **trust bundle** and verifies presented SVIDs against it. The two domains do **not** share a CA; federation means "I trust credentials issued under *that* bundle," nothing more.

```rust
/// What the proxy is configured to trust. The federation root for accepting SVIDs.
struct FederationConfig {
    /// SPIFFE trust domain of the Metatron deployment, e.g. "spiffe://metatron.acme.internal".
    metatron_trust_domain: TrustDomain,
    /// The issuer's trust bundle (roots/intermediates) used to verify SVID issuer_chain/issuer_sig.
    trust_bundle: TrustBundle,
    /// Where to poll for bundle rotation (the proxy must tolerate issuer key rotation, 08 Open Q #1).
    bundle_endpoint: Url,
    /// Maximum SVID lifetime the proxy will accept regardless of not_after (defense in depth).
    max_svid_ttl: LogicalTime,
}
struct TrustDomain(String);
struct TrustBundle { roots: Vec<CertChain>, version: Hash }
```

**The SVID** (the credential the agent presents) — exactly the locked shape, reusing `08`'s `AgentId`/`PublicKey`/`Signature`/`CertChain`:

```rust
struct Svid {
    spiffe_id: SpiffeId,          // SPIFFE id, namespaces the AgentId under the trust domain
    agent_id: AgentId,            // 00 §7 / 08 §3.1 — public-key-derived identity
    operational_key: PublicKey,   // short-lived operational key used for the mTLS session
    scopes: Vec<Scope>,           // Layer-1 coarse claims (§3.4), minted from governed state
    not_after: LogicalTime,       // short TTL — bounds compromise in time (§3.1)
    issuer_chain: CertChain,      // chains to the federation trust bundle (§3.8)
    issuer_sig: Signature,        // issuer's signature over the SVID; verified against the bundle
}
struct SpiffeId(String);
```

**Crypto (consistent with `08 §3.2`/`08` Open Q #7).** The agent↔proxy transport is **hybrid post-quantum TLS** — classical **X25519** + PQ **ML-KEM** key exchange — and the agent authenticates with its **hybrid SVID** signed under **Ed25519 + ML-DSA**. This honors `08`'s crypto-agility (`SigScheme` agile; ML-DSA the parked PQ candidate) and makes the highest-value external surface PQ-secure first. Downstream-side transport (proxy↔downstream server) is whatever the downstream demands (`DownstreamAuthKind`, `§3.5`), terminated and re-originated at the proxy.

SVID verification at the proxy, per call/session:

```
verify_svid(svid):
  1. issuer_sig verifies under FederationConfig.trust_bundle      (federation)
  2. svid.not_after in the future AND (not_after - now) ≤ max_svid_ttl
  3. agent_id == agent_id(public-key in issuer-bound material)    (08 §3.1 self-certifying)
  4. agent_id ∉ RevocationList.revoked_agents  AND  serial ∉ revoked_svids   (§3.7)
  5. mTLS session is bound to svid.operational_key
  ⇒ proceed to per-call two-layer authz (§3.4); else FAIL CLOSED + audit
```

### 3.9 Fail-closed, HA-critical, and graceful degradation

**Locked decision.** The gateway is on the hot path of **every** external action. If it is down, agents lose **all** external tool access. This is the **safe default**: *no proxy ⇒ no privileged action*. A compromised or partitioned environment cannot quietly act on the outside world without a healthy, policy-current proxy in the loop.

But "safe default" must not mean "Metatron crashes." Two requirements follow:

- **The proxy MUST be horizontally scalable and highly available.** Because it gates every external action, it is a **critical, HA service**. It must scale out across replicas (the gateway logic is request-scoped and largely stateless; state is the vault, routing table, policy bundle, and revocation list, all of which are shared/replicated). Streaming and long-running calls complicate replica-affinity — see Open Questions (`§6`).
- **Metatron MUST degrade gracefully when the proxy is unreachable.** A Worker that needs an external action **blocks** on that call rather than crashing or busy-failing. The block is **surfaced via `07`** — exactly like the mailbox-block pattern in `00 §5`/`06`, where affected work blocks until answered. The blocked external call:
  - emits an `ExternalCallBlocked` event/span on the causal chain (`§3.10`), so the stall is observable, not silent;
  - feeds the **`latency`** dimension of the `ErrorVector` (`03`) via that span's duration, so the control loop *sees* external unavailability as pressure and can react (re-plan, back off, escalate to the user via the mailbox);
  - **never blocks indefinitely.** The wait is bounded by the **uniform escalation-timeout** (the shared human-block policy of `02`/`06`, `CONV-E`): on expiry the call **holds and degrades safely** — the task fails cleanly and the stall is mailbox-escalated to the user (`06`) — and it **never silently proceeds** on an irreversible external action. State is never corrupted, because (per `08 §3.5`/`02`) nothing enters the system of record except through the typed/verified/voted/signed gate, so a clean failure is always safe; resumption happens only if the proxy returns within the window.

```
   Worker needs external action
        │
        ▼
   proxy reachable & healthy? ──no──▶ BLOCK (do not crash)
        │ yes                              │  emit ExternalCallBlocked → 07 (causal chain)
        ▼                                  │  duration → ErrorVector.latency (03)
   broker the call (§3.5)                  │  steering loop may re-plan / mailbox-escalate (06)
        │                                  ▼
        ▼                            proxy returns ──▶ resume   |   timeout ──▶ clean task failure
   McpResult                                                        (state never corrupted)
```

This makes external unavailability a *measured error*, consistent with `00 §6` principle 5 ("close the loop, measure the error"), rather than an unhandled fault.

**Staleness is not revocation.** Fail-closed is the correct response to *revocation*; it is the **wrong** response to mere *staleness*. The proxy's authorization inputs — the `PolicyBundle` and the revocation list — are projected from the consensus-governed head (`§3.7`). If the council stalls (no quorum — e.g. a self-repair deadlock, `ROB-04`), the head stops advancing; naïvely validating every minutes-lived SVID against the **current advancing head** would then expire all credentials within one TTL and **amputate all external action at the worst possible moment** — including the very tools an operator needs to diagnose and recover. The gateway therefore separates the two cases explicitly:

- **Genuine revocation/quarantine** — an `AgentId`/serial recorded on the last-known-good revocation list as an **explicit decision in governed state** (`08 §3.6`) — **always fails closed**, immediately, regardless of head freshness. A stall must never weaken containment of an agent already known to be revoked.
- **Mere staleness** — the head (and thus the policy bundle / revocation list) has simply stopped advancing — is **not** treated as revocation. The proxy validates against the **last-known-good head** within a **bounded staleness grace window** (`grace_window`, operator-configured, `always ≥ one SVID TTL` so a single missed refresh cannot strand an agent). Within the window, SVIDs that were valid against the last-known-good head keep being honored even past their own `not_after`, **provided** the agent is not on the last-known-good revocation list.

```rust
struct StalenessPolicy {
    grace_window: LogicalTime,   // honor last-known-good head this long past head freeze (≥ one SVID TTL)
    recovery_safe_unbounded: bool, // keep brokering the recovery/diagnostic carve-out beyond grace_window
}
```

**Security trade-off (stated).** The grace window trades a *bounded* extension of an agent's external reach for availability during a governance liveness failure, and the cost is precisely bounded: for at most `grace_window` after the head freezes, an agent that *would have been* revoked by a decision that **never reached quorum** keeps its prior authorization — but any agent revoked **before** the freeze stays cut off (revocation state is last-known-good, never reset). Past `grace_window` with no fresh head, the proxy reverts to fail-closed: staleness that outlives the window is treated as a genuine loss of policy currency.

**Diagnostic-tool carve-out.** A small, explicitly-tagged set of recovery/diagnostic tools (`DangerClass::Normal`, marked recovery-safe in the policy bundle — e.g. read-only health/status queries and the operator escalation/mailbox path) remains brokerable **beyond** `grace_window` under the last-known-good policy, so recovery tooling stays usable while the head is frozen. The carve-out is **read-mostly and reversible by construction** (no irreversible external effect, `CONV-D`); irreversible tools never qualify, so the carve-out cannot be turned into a bypass.

### 3.10 Audit: every brokered call is on the causal chain

**Locked decision.** Privileged actions are **first-class monitored**. Every brokered call emits telemetry **joined to the causal chain (`07`)**, capturing the agent `AgentId`, the scope used, the downstream target, and the outcome. Audit reuses `07`'s envelope, correlation ids, and signed-spine guarantee verbatim — the proxy is a telemetry **producer** like any plane.

New `EventType`s contributed to `07`'s catalog (additive; same `Event`/`TelemetryEnvelope` shapes as `07 §4`):

```rust
// Added to 07's EventType enum (Execution-plane, external-action subset):
//   BrokeredCallStarted, BrokeredCallFinished, ExternalCallBlocked,
//   DiscoveryGated, BrokerAuthzDenied, DownstreamError, DlpRedaction

/// Structured attrs (07 StructuredAttrs; schema-validated, never free text — 07 §6.1).
struct BrokeredCallAttrs {
    agent: AgentId,                 // who acted
    svid_serial: SvidSerial,        // which short-lived credential
    scope_used: Scope,              // the Layer-1 scope that authorized it
    server: McpServerId,            // downstream target
    tool: ToolName,                 // the tool invoked
    args_redacted: RedactedArgs,    // field-redacted STRUCTURED args — reconstructs *what* was done for forensics
    arg_digest: Hash,               // integrity/tamper-evidence companion: content hash over the ORIGINAL args (alongside, not instead of, args_redacted)
    outcome: BrokerOutcome,         // Ok | Denied{reason} | DownstreamError{code} | Blocked | Timeout
    dlp_applied: bool,              // was the return path filtered?
    latency_ms: u64,
}

/// The call's structured arguments after field-level redaction, produced by the SAME
/// DLP policy DSL (DlpPolicy, §3.4/§3.5) that governs the return path — no second
/// redaction language. Sealed under the gateway's existing DLP/encryption machinery;
/// readable only by authorized incident forensics, never reachable by an agent (R3).
struct RedactedArgs { dlp_version: Hash, args: JsonValue }

enum BrokerOutcome { Ok, Denied(DenyReason), DownstreamError(u16), Blocked, Timeout }
enum DenyReason { OutOfScope, PolicyGuardFailed, Revoked, SvidExpired, UnknownTool, StepUpRequired }
```

How it joins the chain (`07 §2.3`): each brokered-call event carries the `Correlation` of the work that triggered it — `instruction`, `goal`, `trace`, `episode`, and the `commit`/`proposal` that authorized the underlying task. A single query "show me every external action taken because of instruction I42" walks `InstructionId → … → {BrokeredCallFinished}` and returns every privileged action, its authorizing scope, its downstream target, and its outcome — the operational meaning of "privileged actions are first-class monitored." Spine-grade brokered-call events are **signed** (`07 §4.1` `signature`) so the external-action audit log is itself tamper-evident, and **never sampled** (`07 §3`) — dropping a record of a privileged action is not permitted.

**Replayable arguments, redacted — not just a digest.** Incident forensics must be able to reconstruct *what* a privileged call actually did — which repo, which amount, which recipient — not merely prove that *some* call happened. The audit therefore records the call's **structured arguments with field-level redaction** (`args_redacted`), produced by the **same `DlpPolicy` DSL** (`§3.4`/`§3.5`) that governs the return path — **reusing** that machinery rather than introducing a second redaction language — and sealed under the gateway's existing DLP/encryption. Secrets and high-sensitivity fields are masked exactly as they would be on the return path, so the privacy concern that originally motivated a digest-only record is handled by *redaction*, not by blinding the record. The `arg_digest` is **retained alongside** as an integrity/tamper-evidence companion — a content hash over the *original* arguments that lets an investigator confirm the redacted view corresponds to what was actually sent — **not** a replacement for it. An auditor can thus both read the (redacted) blast radius of a breach and verify the record was not tampered with.

The proxy's audit emission is **non-blocking to the call path** (`07 §3`): the broker never stalls waiting on telemetry, but every brokered call *is* accounted (a dropped audit emits a `TelemetryGap`, never a silent omission).

---

## 4. Interfaces & schemas

Consolidated, normative *names and shapes* this spec contributes. Types from `00 §7` (`AgentId`, `Hash`, `Signature`, `LogicalTime`, `PublicKey`, `CertChain`) and `07`/`08` are referenced verbatim, not redefined. The two locked-canonical items (`Svid`, `Scope`, `McpAuthProxy`) appear exactly as specified upstream.

```rust
// ── The canonical credential & authorization claims (locked) ──────────────────
struct Svid {
    spiffe_id: SpiffeId, agent_id: AgentId, operational_key: PublicKey,
    scopes: Vec<Scope>, not_after: LogicalTime, issuer_chain: CertChain, issuer_sig: Signature,
}
struct Scope { resource: McpServerId, methods: Vec<MethodPattern> }

// ── The proxy contract (locked) ───────────────────────────────────────────────
trait McpAuthProxy {
    /// Filtered to authorized scopes — gated discovery (§3.3). Unauthorized tools are invisible.
    fn discover_tools(&self, svid: &Svid) -> ToolList;

    /// Brokered (§3.5): two-layer authz, vault credential injected downstream,
    /// credential NEVER returned to the agent. Result-only on the return path.
    fn invoke(&self, svid: &Svid, call: McpToolCall) -> McpResult;
}

// ── MCP surface types ─────────────────────────────────────────────────────────
struct ToolList { tools: Vec<ToolDescriptor> }    // the per-identity virtual catalog (§3.3)
struct ToolDescriptor {
    virtual_name: String,         // "github::create_pull_request" (namespaced by route, §3.2)
    server: McpServerId,
    title: String,
    input_schema: JsonSchema,     // MCP tool input schema, passed through from downstream
    streaming: bool,              // does this tool stream / run long? (§3.2)
    danger: DangerClass,          // hint for optional step-up (§6); Normal | Elevated | Critical
}

struct McpToolCall {
    tool: String,                 // virtual_name from a ToolDescriptor
    args: JsonValue,              // schema-validated against input_schema before routing
    call_id: [u8; 16],            // idempotency / correlation handle
    stream: bool,                 // client requests progressive results
    deadline: Option<LogicalTime>,// long-running bound; informs block/timeout (§3.9)
}

enum McpResult {
    /// Completed result. Carries data ONLY — no credential, possibly DLP-filtered (§3.4).
    Ok { call_id: [u8;16], content: JsonValue, dlp_applied: bool },
    /// Progressive/streamed chunk for streaming or long-running calls (§3.2).
    Progress { call_id: [u8;16], chunk: JsonValue, done: bool },
    /// Authorization or routing refusal — fail-closed (§3.4, §3.9).
    Denied { call_id: [u8;16], reason: DenyReason },
    /// Downstream server error, surfaced without leaking credential material.
    DownstreamError { call_id: [u8;16], code: u16, message: String },
    /// Proxy/credential/downstream unavailable — agent BLOCKS (§3.9).
    Unavailable { call_id: [u8;16], retry_after: Option<LogicalTime> },
}

// ── Routing & vault (§3.5, §3.6) ──────────────────────────────────────────────
struct RoutingTable { routes: BTreeMap<McpServerId, RouteEntry> }
struct RouteEntry {
    server: McpServerId, endpoint: DownstreamEndpoint, credential: CredentialRef,
    auth_kind: DownstreamAuthKind, capabilities: Vec<ToolName>, health: ServerHealth,
}
struct CredentialRef(String);     // pointer into the vault; never the secret value
trait  CredentialVault {
    fn fetch(&self, r: &CredentialRef) -> Result<SecretMaterial, VaultError>;
    fn refresh(&self, r: &CredentialRef) -> Result<(), VaultError>;
    fn status(&self, r: &CredentialRef) -> CredentialStatus;
}

// ── Authorization policy (§3.4) ───────────────────────────────────────────────
struct PolicyBundle { version: Hash, rules: Vec<PolicyRule> }
struct PolicyRule {
    server: McpServerId, tool: ToolName, guard: ArgGuard,
    dlp: Option<DlpPolicy>, step_up: Option<StepUpPolicy>,
}

// ── Trust, federation, revocation (§3.7, §3.8) ────────────────────────────────
struct FederationConfig {
    metatron_trust_domain: TrustDomain, trust_bundle: TrustBundle,
    bundle_endpoint: Url, max_svid_ttl: LogicalTime,
}
struct RevocationList {
    version: Hash, as_of: LogicalTime,
    revoked_agents: BTreeSet<AgentId>, revoked_svids: BTreeSet<SvidSerial>, ttl: LogicalTime,
}
trait RevocationFeed { fn poll(&self) -> Result<RevocationList, FeedError>; }

// ── Audit (§3.10) — additive to 07's catalog; same envelope & correlation ─────
struct BrokeredCallAttrs {
    agent: AgentId, svid_serial: SvidSerial, scope_used: Scope, server: McpServerId,
    tool: ToolName, args_redacted: RedactedArgs, arg_digest: Hash,   // redacted structured args + integrity companion (§3.10)
    outcome: BrokerOutcome, dlp_applied: bool, latency_ms: u64,
}
struct RedactedArgs { dlp_version: Hash, args: JsonValue }   // field-redacted via the return-path DLP DSL (§3.4/§3.5); sealed under DLP/encryption
```

### 4.1 Threat model (extends `08 §4.1`)

Each row is **vector → impact → mitigation**; the mitigation is the architecture, not an addition to it.

| # | Threat | Vector | Impact if unmitigated | Mitigation (and owning §) |
|---|---|---|---|---|
| **P1** | **Compromised agent steals a standing downstream secret** | Prompt injection / harness compromise (`08` T3/T4) tries to exfiltrate a credential. | Permanent, unbounded external access to system X. | **Privilege separation**: the agent holds *no* downstream secret; it never leaves the vault (R3, `§3.1`, `§3.6`). There is nothing to steal. |
| **P2** | **Compromised agent abuses its legitimate access** | A compromised but not-yet-quarantined agent invokes the tools it *is* authorized for, maliciously. | Bounded misuse of authorized scopes. | Blast radius bounded to current scopes ∩ gateway policy, for ≤ one SVID TTL (`§3.1`); two-layer authz constrains even authorized calls (arg guards, `§3.4`); quarantine → revocation list closes it within one TTL (`§3.7`). |
| **P3** | **Agent enumerates / reaches an unauthorized tool** | Confused/compromised agent tries to discover or call a tool its role lacks. | Privilege escalation; footprint disclosure. | **Gated discovery** — unauthorized tools are invisible (`§3.3`); a call to one is denied as unknown (`§3.4`). Discovery and enforcement share logic, so they can't disagree. |
| **P4** | **Forged or replayed SVID** | Attacker presents a fabricated or stale SVID. | Impersonation; expired authority reused. | Federation verification of `issuer_sig` against the trust bundle, `not_after` + `max_svid_ttl` bound, mTLS bound to `operational_key`, self-certifying `agent_id` (`§3.8`); short TTL bounds replay window. |
| **P5** | **Revoked agent keeps acting** | Quarantined/removed agent (`08 §3.6`) still holds an unexpired SVID. | Continued external action after internal containment. | **Fast revocation list**, polled ≪ SVID TTL; the proxy stops honoring the agent within one TTL with **no downstream rotation** (`§3.7`). |
| **P6** | **Proxy outage used to force unsafe fallback** | Proxy unreachable; pressure to "let agents call directly" as a workaround. | Re-introduction of standing secrets / unbrokered action. | **Fail-closed**: no proxy ⇒ no privileged action; Metatron **blocks** (graceful degradation, `§3.9`). There is no direct-call fallback path by construction. |
| **P7** | **Data exfiltration via the return path** | Downstream result carries secrets/PII the agent shouldn't see. | Sensitive data leaks into agent context / telemetry. | Optional **DLP/response filtering** governed by the same policy (`§3.4`/`§3.5`); audit records `dlp_applied` and stores **DLP-redacted structured args** (not raw args) plus an integrity `arg_digest` in telemetry (`§3.10`). |
| **P8** | **Proxy (vault) compromise** | The proxy itself — the one secret-holder — is breached. | All downstream secrets exposed. | Concentrates risk into one **user-owned, hardenable** boundary (HSM/KMS-backed vault, `§3.6`) rather than spreading standing secrets across N agents; separate trust domain from Metatron core (`§3.8`); least-privilege downstream credentials limit each one's reach. (Residual trust assumption — `§6`.) |
| **P9** | **Confused-deputy across users (multi-user)** | An action serving external user A is brokered with user B's credential/vault. | Cross-tenant privilege confusion. | Routing/vault selection must bind to the acting principal; **multi-user vault selection is an Open Question** (`§6`), flagged not closed. |

---

## 5. Deployment & operations

- **Separate deployment, separate trust domain.** The proxy is deployed and operated by the **user**, alongside but distinct from Metatron core. It holds the vault; Metatron core does not. The only link is the federation trust bundle (`§3.8`) flowing in, the SVID-bearing mTLS sessions flowing across, and the policy bundle + revocation list flowing in.
- **Horizontal scalability / HA (required).** Because the gateway gates every external action (`§3.9`), it is operated as a **critical HA service**: multiple stateless-ish replicas behind a load balancer, with shared/replicated vault, routing table, policy bundle, and revocation cache. Replica affinity for **streaming/long-running/resumable** sessions is the main complication (Open Question, `§6`).
- **Health & fail-closed posture.** Each replica tracks `ServerHealth` per downstream and `CredentialStatus` per credential. On its own unavailability, a stale revocation list past `ttl`, or a missing/expired credential, it **denies/blocks** rather than guesses — fail-closed is the default everywhere.
- **Policy & revocation freshness.** Operators tune the revocation poll interval to be **≪ the SVID TTL** so containment latency stays within one TTL. Policy bundles are content-addressed to a governing commit (`§3.4`), so an operator can always answer "which consensus decision authorized this privilege?"
- **Configuration surface.** Per deployment: the `FederationConfig` (trust domain, bundle, `max_svid_ttl`); the `RoutingTable` (downstream endpoints + `CredentialRef`s + `auth_kind`); the vault backend; the `PolicyBundle` source; the `RevocationFeed` endpoint and poll interval; the telemetry sink (`07`).
- **Observability of the proxy itself.** The proxy is a `07` producer (`§3.10`): brokered-call spine events are signed and unsampled; its own outages surface as `ExternalCallBlocked` on agents' causal chains and as `latency` pressure to the steering loop (`03`). A silent proxy is detectable the same way a silent Sentinel is (absence of expected spans, `07 §3`).
- **Credential lifecycle ops.** OAuth refresh/expiry is handled inside the proxy (`§3.6`); operators rotate downstream secrets in the vault **without touching any agent** — agents are credential-free, so downstream rotation is invisible to them.

---

## 6. Open questions & ambiguities

Parked per `00 §9`. Genuine, deferred decisions — not yet settled.

1. **HA topology & graceful-block mechanics.** What replica/affinity topology best serves a gateway that must be HA *and* carry streaming, long-running, and resumable downstream sessions (which resist statelessness)? And precisely how does a Worker *block* on an unreachable proxy without wedging the execution backend — bounded queue + timeout? backpressure into the steering-loop `latency` signal (`03`)? mailbox-escalation to the user (`06`) after a threshold? The fail-closed *intent* is locked (`§3.9`); the exact blocking/queueing/timeout mechanics and the replica model are open.
2. **Breadth of MCP-protocol coverage across heterogeneous downstreams.** Downstream MCP servers vary widely in what they implement — streaming, progress, cancellation, resumable sessions, resources/prompts beyond tools, transport (stdio vs http+sse vs ws). How much of the MCP surface must the proxy faithfully multiplex, and how does it degrade when a downstream supports less than the agent expects? A capability-intersection model is sketched (`§3.2`) but not pinned.
3. **DLP / response-filtering policy language.** `§3.4`/`§3.5` introduce return-path DLP but leave the *language* open: how are redaction/masking/size-cap/block rules expressed (CEL? a typed predicate DSL? JSONPath matchers?), how are they governed as state, and how is their performance bounded on large/streamed results without becoming a latency sink?
4. **Downstream OAuth refresh/expiry management.** The proxy manages token refresh internally (`§3.6`), but the strategy is undecided: proactive vs. lazy refresh, handling refresh-token rotation and revocation by the downstream IdP, behavior on a refresh failure mid-call (fail-closed vs. one bounded retry), and how `CredentialStatus::Expiring` feeds health-based routing.
5. **Per-call step-up authorization for especially dangerous tools.** Should some tools (`DangerClass::Critical` — e.g. "delete production database", "wire funds") require a *per-call* elevation beyond standing scope — a fresh consensus decision, a second-agent co-sign, or a human mailbox confirmation (`06`) — rather than relying on the standing SVID scope? `StepUpPolicy` is reserved in the types (`§3.4`) but its trigger conditions, authority, and latency cost are unspecified. **One aspect is *not* open, however:** whatever mechanism is chosen, its human/consensus wait is **bounded by the uniform escalation-timeout** (the shared human-block policy of `02`/`06`, `CONV-E`) — it never blocks indefinitely. On expiry the call **holds and degrades safely**: it is denied (`DenyReason::StepUpRequired`) and the request is surfaced via the mailbox (`06`), and it **never silently proceeds** on a `DangerClass::Critical`/irreversible tool. The *bounded-wait-then-safe-fallback* contract is locked; only the trigger/authority/latency-budget choices are deferred.
6. **Multi-user: whose vault/secrets when an action serves a specific external user?** When Metatron serves multiple external users (`06`/`08` Open Q #5) and a brokered action is taken *on behalf of* a particular user, which principal's credential/vault is used? Per-user vaults? A user-scoped `CredentialRef`? How does the acting agent's `AgentId` compose with the served user's identity to select the right secret without a confused-deputy (P9)? This is the deepest open question and interacts with external-user authentication, still deferred in `08 §5` #5.
7. **Trust concentration in the vault (residual assumption).** Privilege separation deliberately concentrates *all* standing downstream secrets in one place (the proxy vault). That is a better posture than N agents each holding standing secrets (P8), but it makes the proxy a high-value target. How far to push hardening — HSM/enclave-backed vault, threshold-split credentials, per-downstream isolation — is an open operational/trust decision, parallel to `08`'s kernel-key-custody question (`08 §5` #8).
8. **SVID issuance & rotation under load.** The identity-issuer (`§3.8`) extends `08`'s parked rotation/revocation question (`08 §5` #1). Issuing short-lived SVIDs for many agents at high rate, rotating the federation bundle without a brokering outage, and choosing the exact SVID TTL (containment latency vs. issuance load) are open.

---

## 7. Relationships to other specs

- **`00-overview`** — Canonical anchor. This spec reuses `AgentId`, `Hash`, `Signature`, `LogicalTime`, `PublicKey` verbatim and realizes `00 §1`'s "bound the blast radius of an unreliable substrate" at the external-action boundary. On any conflict, `00` wins.
- **`01-state-model`** — The authorization that produces both SVID scopes (Layer 1) and the gateway `PolicyBundle` (Layer 2) is **derived from the consensus-governed configuration layer**; granting a privilege is a typed, consensus-approved state diff that lands as a signed `Commit`. Policy bundles are content-addressed back to their governing commit (`§3.4`).
- **`02-consensus`** — Privilege grants/revocations are ordinary (or constitutional, for high-blast tools) proposals through the propose→verify→vote→commit loop. There is no privileged side channel to grant external access — consistent with `08 §3.4`'s "no privileged path."
- **`03-control-loop`** — Proxy/downstream unavailability is a **measured error**: blocked external calls feed the `ErrorVector.latency` dimension (`§3.9`), and the steering loop can re-plan, back off, or mailbox-escalate. External action availability becomes a controlled variable, not an unhandled fault.
- **`04-runtime-and-harness`** — Workers' harnesses are the agents that broker calls. The proxy is the **enforcement point** for external `Net`/`Exec`-style privilege, complementing `08 §3.5`'s in-sandbox `CapabilitySet`: the harness has no ambient egress; its only privileged-action path is the single MCP endpoint at the proxy.
- **`05-agent-jit`** — Tier-1/Tier-2 compiled policies broker external calls through the **same** proxy, SVID, two-layer authz, and audit as the Tier-0 interpreter; a deopt does not relax brokering. A compiled policy cannot self-grant a downstream credential any more than an interpreter can (`08 §3.5`).
- **`06-interaction-and-mailbox`** — When an external action is blocked (`§3.9`) or a dangerous tool needs per-call confirmation (`§6` #5), the **mailbox** is the human-in-the-loop channel — the same blocking pattern as ambiguity (`00 §5`). Multi-user vault selection (`§6` #6) depends on `06`'s (deferred) external-user authentication.
- **`07-observability`** — The proxy is a first-class telemetry **producer**: every brokered call emits a signed, unsampled spine event joined to the causal chain (`§3.10`), reusing `07`'s envelope, `Correlation`, and `Event` shapes. "Show every external action caused by instruction I" is a `causal_chain` walk.
- **`08-trust-and-security`** — The foundation this spec stands on. It **extends** `08`'s identity (`AgentId`, `PublicKey`, self-certifying ids), signing/crypto-agility (`SigScheme`; the hybrid-PQ Ed25519+ML-DSA / X25519+ML-KEM choice realizes `08 §3.2` + Open Q #7), capability least-privilege (`08 §3.5`), and Byzantine response (`08 §3.6`) **across the external trust boundary**: quarantine becomes external cutoff via the revocation list (`§3.7`), and privilege separation extends `08`'s "a leaked key buys only that role's capabilities" (`08 §3.1`) to "a compromised agent leaks no downstream secret at all." On any conflict, `08`'s shared types and `00` win.
