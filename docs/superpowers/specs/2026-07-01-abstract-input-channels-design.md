# Design — Abstract input channels for the Interaction plane

> **Status:** Design (approved for spec-edit). Target: `specs/*.md` research architecture v0.1.
> **Date:** 2026-07-01
> **Topic:** Make the Interaction plane's external boundary pluggable across transports (HTTP API, Telegram, Slack, SMS, …) without disturbing the deliberative core.

---

## 1. Motivation

The Interaction plane (`06-interaction-and-mailbox.md`) is the boundary between Metatron and the external world. Its *inner* contract is already clean and transport-agnostic: raw `Instruction`/`Answer` flow in, typed `Question`/`Notification` flow out, everything keyed by an abstract `ExternalUserId` principal, with *how a user authenticates* deferred to `08-trust-and-security.md`.

But the *outer* boundary is hardcoded to a single transport:

- `06` §4.4 defines the external API surface as one REST-flavored HTTP API (`POST /v1/instructions`, `GET /v1/notifications`, …).
- `08` §3.9 assumes identity arrives as "token / OIDC / session".

The goal is to let users drive the system through **many** channels — HTTP API, Telegram, Slack, SMS, and future additions — each with its own transport, identity system, and interaction affordances, **without** re-opening the Guardian state machine, the two-step ambiguity gate, goal normalization, or the mailbox semantics.

## 2. Core idea

Introduce a **Channel Adapter** layer that sits *outside* the Guardian, in the exact structural position that `AgentHarness` (`04-runtime-and-harness.md`) occupies for execution. `AgentHarness` abstracts *where agents run* behind a trait with declared capabilities; the Channel Adapter symmetrically abstracts *how users connect*.

The adapter is a **pure translation + identity-resolution shell** around the existing plane. The Guardian intake state machine (§3.1), the two-step gate (§2.3), `Goal` normalization, mailbox internals (§3.3), and every core artifact type (`Instruction`, `Goal`, `Question`, `Answer`, `Notification`) stay **unchanged**.

```
   Slack / Telegram / HTTP API / SMS / …        ← heterogeneous transports
            │  (channel-native events)
            ▼
   ┌───────────────────────────────┐
   │        Channel Adapter        │   NEW — one impl per channel kind
   │  • authenticate native sender │
   │  • resolve → ExternalUserId   │   (via 08 binding table)
   │  • inbound: native → Instruction/Answer
   │  • outbound: Question/Notification → native render (lossy)
   │  • correlation-token mgmt     │
   └───────────────┬───────────────┘
                   │  canonical Instruction / Answer  ▲  Question / Notification
                   ▼                                  │
   ┌───────────────────────────────────────────────────────┐
   │   Guardian intake state machine + Mailbox  (UNCHANGED) │
   └───────────────────────────────────────────────────────┘
```

## 3. Resolved design forks

Three decisions were made during brainstorming; they are normative for the spec edit.

### 3.1 Scope — channel adapter layer only

A `Channel`/`Adapter` abstraction at the `06` boundary that normalizes heterogeneous inbound events into the existing canonical `Instruction`/`Answer`, and renders `Question`/`Notification` into channel-native form. Core types (`Goal`, `Setpoint`, the gate) are untouched. Identity binding is threaded through `08`.

**Explicitly not in scope:** a formal capability-negotiation handshake, cross-channel identity linking, and any new core artifact type. (See §6 YAGNI.)

### 3.2 Identity — deterministic mapping, linking-ready

A channel-native sender (a Slack user, a Telegram user, an API token subject) maps to the canonical `ExternalUserId` through an **explicit resolution step**:

- **Default is deterministic 1:1** — `(channel_kind, native_id) → ExternalUserId`. The same human on Slack vs Telegram is two principals today, with separate mailboxes and scopes. This is consistent with "no identity rework".
- The resolution is an **explicit indirection** (a binding table owned by `08`), so a later identity-linking feature can collapse several `ChannelIdentity`s onto one `ExternalUserId` **without changing the adapter contract**. Linking policy is parked as an open question.

### 3.3 Rendering — best-effort render + explicit correlation token

Adapters own **lossy** rendering: structured `Question.options` become native buttons/quick-replies where supported (Slack blocks, Telegram inline keyboards) or a numbered/keyword list in plaintext (SMS). A small **declared-capability record** (`supports_structured_options: bool`, `supports_push: bool`, `max_len`, …) lets an adapter pick a rendering — but there is **no negotiation handshake**.

Every outbound `Question` carries an adapter-managed **correlation token** so a reply on any channel maps unambiguously back to its `QuestionId`, *without relying on channel-native threading*. This makes "answer maps to the right blocked node" hold on SMS as well as Slack.

## 4. Components

### 4.1 The `ChannelAdapter` trait (new `06` §4.5)

One impl per channel kind (`ApiAdapter`, `SlackAdapter`, `TelegramAdapter`, …). Responsibilities:

- **Inbound normalization** — turn a channel-native event into a canonical `Instruction`, or, if it correlates to an open `Question` (via the correlation token), an `Answer`. Free text stays free text; normalization to `Goal` remains the Guardian's job downstream, unchanged.
- **Outbound rendering (best-effort, lossy)** — render a `Question`/`Notification` to channel-native form guided by the declared-capability record; degrade gracefully.
- **Correlation** — mint and track a correlation token per outbound `Question`; resolve inbound replies back to the gated `QuestionId`.

Illustrative shape (Rust-flavored pseudotypes, consistent with `00` §7):

```rust
type ChannelId = Hash;   // stable id of a configured channel instance

enum ChannelKind { Api, Slack, Telegram, Sms, /* extensible */ Other(String) }

struct ChannelCapabilities {
    supports_structured_options: bool, // native buttons / quick-replies
    supports_push: bool,               // server-initiated delivery vs poll-only
    supports_threading: bool,          // native reply threading (advisory only)
    max_message_len: Option<u32>,
}

/// Authenticated channel-native sender, pre-resolution.
struct ChannelIdentity {
    channel_kind: ChannelKind,
    native_id: Text,          // Slack user id, Telegram user id, API token subject, …
    auth_evidence: Bytes,     // channel-native proof; VERIFIED by the adapter, checked per 08
}

/// Opaque, adapter-managed; identifies WHICH question a reply answers.
/// NOT an authorization credential (see §4.3).
struct CorrelationToken(Bytes);

trait ChannelAdapter {
    fn kind(&self) -> ChannelKind;
    fn capabilities(&self) -> ChannelCapabilities;

    /// Authenticate the native sender and resolve to a principal (via 08 binding).
    /// Rejects unauthenticated / unbindable senders.
    fn authenticate(&self, ev: &InboundEvent) -> Result<ExternalUserId, AuthReject>;

    /// Inbound: native event -> canonical Instruction, or Answer if it carries a
    /// correlation token for an open Question.
    fn ingest(&self, ev: InboundEvent, who: ExternalUserId) -> InboundItem; // Instruction | Answer

    /// Outbound: render a Question/Notification to native form; mint a correlation
    /// token for Questions so the reply routes back to `gates`.
    fn render_question(&self, q: &Question) -> (NativeMessage, CorrelationToken);
    fn render_notification(&self, n: &Notification) -> NativeMessage;
}
```

The Guardian receives `InboundItem`s and emits `Question`/`Notification`s exactly as today; it is unaware which adapter produced or will deliver them.

### 4.2 Channel identity resolution (`06` §4.5 + `08` §3.9)

The adapter authenticates a `ChannelIdentity` using **channel-native means** (Slack request signing, Telegram webhook/bot-token secret, API OIDC/token), then resolves it to an `ExternalUserId` via a **binding table owned by `08`**. `08` §3.9's `UserAuthn` is generalized from "token / OIDC / session" to "channel-native authn evidence, verified by the adapter, bound to an `ExternalUserId` via the resolution table". Default binding is deterministic 1:1 (§3.2).

### 4.3 Preserved trust boundaries

- **Authentication ≠ content trust (restated per-channel).** `08` T2 injection-scrubbing and the typed-`Proposal`/council-verify gate apply to *every* channel's input identically. A well-authenticated Slack message is no more content-trusted than any other input.
- **The correlation token is not an auth credential.** It identifies *which* question a reply answers; *who is allowed to answer* is still the `08` `may_answer` scope check on the resolved `ExternalUserId`. This prevents "guess the token → answer someone else's blocking question".

## 5. Per-spec changes (all additive)

| Spec | Change |
|------|--------|
| **`06-interaction-and-mailbox.md`** | New §2.6 (Channel concept) + §3.8 (adapter data flow, correlation, lossy rendering) + §4.5 (`ChannelAdapter` trait, `ChannelIdentity`, `ChannelCapabilities`, `CorrelationToken`). Reframe §4.4: the REST surface becomes **one concrete adapter (`ApiAdapter`) over a transport-agnostic contract**, not *the* boundary. Add a resolved decision (§5) and the identity-linking open question (§6). |
| **`08-trust-and-security.md`** | Generalize §3.9: `ChannelIdentity → ExternalUserId` binding table, per-channel authn evidence, "correlation token is not a credential" note. Add threat-model row **T13 — channel spoofing / cross-channel identity confusion**. |
| **`00-overview.md`** | Glossary: add **Channel**, **Channel Adapter**. Canonical types §7: add `ChannelId`/`ChannelIdentity` alongside `ExternalUserId`; note the adapter boundary in the Interaction plane description. |
| **`07-observability.md`** | Add **channel** as a telemetry dimension (interruption rate, answer latency, render-degradation events per channel kind). One paragraph. |
| **`README.md`** | One line in the `06` row + a key-design-decision bullet on pluggable channels. |

## 6. Non-goals (YAGNI)

- **No formal capability-negotiation handshake** — declared capability flags only.
- **No cross-channel identity linking now** — the resolution indirection is in place; linking policy is deferred (open question).
- **No new core artifact types** — `Instruction`/`Goal`/`Question`/`Answer`/`Notification` are unchanged; the adapter only translates at the edge.

## 7. Open questions (carried into the specs)

1. **Cross-channel identity linking policy.** When and how several `ChannelIdentity`s should collapse onto one `ExternalUserId` — and how per-channel trust levels combine — is deferred. The resolution indirection makes it addable without changing the adapter contract. (`06`/`08`)
2. **Per-channel trust weighting.** Whether some channels (e.g. a signed API token) should carry different authorization weight than others (e.g. an SMS number) is left open; today all resolved principals are equal once bound. (`08`)
