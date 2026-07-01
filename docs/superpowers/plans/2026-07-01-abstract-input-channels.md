# Abstract Input Channels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Interaction plane's external boundary pluggable across transports (HTTP API, Telegram, Slack, SMS, …) by introducing a Channel Adapter layer, without disturbing the deliberative core.

**Architecture:** Add a `ChannelAdapter` trait at the `06` boundary — mirroring `04`'s `AgentHarness` — that authenticates channel-native senders, resolves them to the existing `ExternalUserId` via an `08`-owned binding table, normalizes inbound events into the unchanged canonical `Instruction`/`Answer`, and renders outbound `Question`/`Notification` into channel-native form with an explicit correlation token. All core types and the Guardian state machine are untouched; every change is additive.

**Tech Stack:** Markdown research-architecture specs under `specs/`. Rust-flavored pseudotypes. No code, no compiler — "tests" are grep/consistency verifications against the spec set's own conventions.

## Global Constraints

- **`00-overview.md` is authoritative.** When any spec disagrees with `00` on vocabulary or a shared type, `00` wins. New shared types (`ChannelId`, `ChannelKind`, `ChannelIdentity`) must be introduced in `00` §7 and referenced (not redefined) elsewhere. (`README.md` conventions)
- **Additive only.** Do not remove or rename existing core artifact types (`Instruction`, `Goal`, `Question`, `Answer`, `Notification`) or alter the Guardian intake state machine (`06` §3.1). The adapter is a translation shell outside the Guardian.
- **Spec section format:** `Purpose → Concepts → Detailed design → Interfaces/schemas → Resolved decisions → Open questions → Relationships` (`README.md` conventions). New content lands in the matching existing section of each file.
- **Code blocks are Rust-flavored pseudotypes**, reusing `00` §7 names verbatim (`Hash`, `Text`, `Bytes`, `ExternalUserId`, `Question`, `Answer`, `Notification`).
- **Source of truth for the change set:** `docs/superpowers/specs/2026-07-01-abstract-input-channels-design.md`.
- **Commit after each task.** One commit per spec file touched.

---

## File Structure

All edits are to existing files; no new files. Task order follows the dependency chain — `06` defines the canonical adapter contract and types, `00` promotes the shared types, then `08`/`07`/`README` reference them.

- `specs/06-interaction-and-mailbox.md` — owns the `ChannelAdapter` trait, `ChannelIdentity`, `ChannelCapabilities`, `CorrelationToken`; reframes §4.4 as one concrete adapter. **(Task 1)**
- `specs/00-overview.md` — promotes `ChannelId`/`ChannelKind`/`ChannelIdentity` to canonical types §7; adds glossary entries. **(Task 2)**
- `specs/08-trust-and-security.md` — generalizes §3.9 identity to a `ChannelIdentity → ExternalUserId` binding table; adds threat row T13. **(Task 3)**
- `specs/07-observability.md` — adds `channel` as a telemetry dimension on interaction metrics. **(Task 4)**
- `specs/README.md` — updates the `06` row and adds a key-design-decision bullet. **(Task 5)**

---

### Task 1: Channel Adapter layer in `06-interaction-and-mailbox.md`

**Files:**
- Modify: `specs/06-interaction-and-mailbox.md` — add §2.6 (after §2.5, currently ends before `## 3` at line 149); add §3.8 (after §3.7, which ends before `## 4` at line 279); add §4.5 (after §4.4, whose surface-summary table + budgets paragraph end before `## 5` at line 500); add one Resolved decision (§5) and one Open question (§6); add a Channel row to the §7 relationships table.

**Interfaces:**
- Produces (referenced by later tasks): `ChannelId`, `ChannelKind`, `ChannelIdentity { channel_kind, native_id, auth_evidence }`, `ChannelCapabilities { supports_structured_options, supports_push, supports_threading, max_message_len }`, `CorrelationToken`, and the `ChannelAdapter` trait with methods `kind`, `capabilities`, `authenticate`, `ingest`, `render_question`, `render_notification`.

- [ ] **Step 1: Add §2.6 "Channels — the pluggable external boundary" after §2.5**

Insert immediately before the `---` that precedes `## 3. Detailed design`. Content to add:

```markdown
### 2.6 Channels — the pluggable external boundary

Everything above describes the plane's *internal* contract: raw `Instruction`/`Answer` in, typed `Question`/`Notification` out, keyed by an abstract `ExternalUserId`. That contract is deliberately transport-agnostic. A **Channel** is a concrete way a user reaches the system — an HTTP API, Telegram, Slack, SMS — and a **Channel Adapter** is the translation shell that sits *outside* the Guardian and connects one such transport to the internal contract.

The adapter occupies the same structural position for *user connection* that `AgentHarness` (`04`) occupies for *agent execution*: a pluggable boundary that maps one heterogeneous external world onto one canonical internal contract. Adding a channel is implementing an adapter; **the Guardian intake state machine (§3.1), the two-step gate (§2.3), goal normalization, and the mailbox (§3.3) do not change.**

An adapter has three jobs: (1) **authenticate** the channel-native sender and **resolve** it to an `ExternalUserId` (via the binding table owned by `08`, §3.9); (2) **normalize inbound** channel-native events into a canonical `Instruction` — or, when the event correlates to an open `Question`, an `Answer`; (3) **render outbound** `Question`/`Notification` into channel-native form, best-effort and lossy, tracking a **correlation token** so any reply routes back to the exact `QuestionId` it answers. There is **no capability-negotiation handshake**: an adapter merely *declares* what it can do (`ChannelCapabilities`) and degrades gracefully.
```

- [ ] **Step 2: Verify §2.6 inserted and ordered correctly**

Run: `grep -n "^### 2\.\|^## 3\." specs/06-interaction-and-mailbox.md`
Expected: `### 2.6 Channels` appears after `### 2.5` and before `## 3. Detailed design`.

- [ ] **Step 3: Add §3.8 "Channel adapter data flow" after §3.7**

Insert immediately before the `---` that precedes `## 4. Interfaces & schemas`. Content to add:

```markdown
### 3.8 Channel adapter data flow, rendering & correlation

```
inbound:  native event ──authenticate──▶ ExternalUserId ──ingest──▶ {Instruction | Answer} ──▶ Guardian (§3.1)
outbound: Question/Notification ──render (lossy)──▶ native message  (+ correlation token for Questions)
reply:    native reply ──match correlation token──▶ QuestionId ──▶ Answer ──▶ deliver_answer (§4.3)
```

**Inbound normalization.** The adapter turns a channel-native event into a canonical `Instruction`. If the event carries a correlation token for an open `Question`, it is instead ingested as an `Answer` to that `QuestionId` (the same one-channel-two-semantics rule as the API's `in_reply_to`, §4.4). Free text stays free text — normalization to a `Goal` remains the Guardian's job (§3.1), unchanged.

**Outbound rendering is best-effort and lossy.** A `Question`'s structured `options` (§4.2) render as native controls where the adapter's `ChannelCapabilities.supports_structured_options` is true (Slack blocks, Telegram inline keyboards) and otherwise degrade to a numbered/keyword list the user answers in plain text. A channel with `supports_push == false` is polled by the client rather than pushed to. Degradation is the adapter's own concern; the Guardian emits one canonical `Question` regardless of channel.

**Correlation is explicit, not threading-dependent.** Every rendered `Question` carries an adapter-managed `CorrelationToken`, so a reply on *any* channel maps unambiguously back to its `QuestionId` even when the channel cannot thread (e.g. SMS). Channel-native threading (Slack `thread_ts`, Telegram reply-to) may *inform* the token but is never the sole basis for correlation.

**The correlation token is not an authorization credential.** It identifies *which* `Question` a reply answers; *who* may authoritatively answer is still the `08` `may_answer` scope check on the resolved `ExternalUserId` (§2.2, §3.6). A guessed or leaked token cannot answer another principal's blocking `Question`.
```

Note: the nested triple-backtick diagram must use a language-less fence; when pasting, ensure the outer section is plain Markdown (the diagram block is fenced with ``` and closed before the prose).

- [ ] **Step 4: Verify §3.8 inserted and ordered correctly**

Run: `grep -n "^### 3\.[78]\|^## 4\." specs/06-interaction-and-mailbox.md`
Expected: `### 3.8 Channel adapter data flow` appears after `### 3.7` and before `## 4. Interfaces & schemas`.

- [ ] **Step 5: Add §4.5 "Channel adapters" after §4.4**

Insert immediately before the `---` that precedes `## 5. Resolved decisions`, i.e. after the "Setting budgets (`10`)." paragraph. Content to add:

````markdown
### 4.5 Channel adapters

The external API surface of §4.4 is **one concrete adapter** (`ApiAdapter`) over a transport-agnostic contract, not *the* boundary. Every channel — API, Slack, Telegram, SMS — is an implementation of the `ChannelAdapter` trait below; the Guardian is unaware which adapter produced an inbound item or will deliver an outbound one.

```rust
type ChannelId = Hash;               // stable id of one configured channel instance

enum ChannelKind { Api, Slack, Telegram, Sms, Other(String) } // extensible

/// What an adapter can natively do. DECLARED, not negotiated (no handshake).
struct ChannelCapabilities {
    supports_structured_options: bool, // native buttons / quick-replies
    supports_push: bool,               // server-initiated delivery vs poll-only
    supports_threading: bool,          // native reply threading (advisory only)
    max_message_len: Option<u32>,
}

/// An authenticated channel-native sender, PRE-resolution.
/// Resolved to an ExternalUserId via the 08-owned binding table (08 §3.9).
struct ChannelIdentity {
    channel_kind: ChannelKind,
    native_id: Text,      // Slack user id, Telegram user id, API token subject, …
    auth_evidence: Bytes, // channel-native proof; VERIFIED by the adapter, checked per 08
}

/// Opaque, adapter-managed. Identifies WHICH Question a reply answers.
/// NOT an authorization credential — answer-authz is the 08 `may_answer` check.
struct CorrelationToken(Bytes);

/// The channel-boundary contract. One implementation per ChannelKind.
trait ChannelAdapter {
    fn kind(&self) -> ChannelKind;
    fn capabilities(&self) -> ChannelCapabilities;

    /// Authenticate the native sender and resolve to a principal (via 08 binding).
    /// Rejects unauthenticated / unbindable senders.
    fn authenticate(&self, ev: &InboundEvent) -> Result<ExternalUserId, AuthReject>;

    /// Inbound: native event -> canonical Instruction, or Answer if it carries a
    /// CorrelationToken for an open Question.
    fn ingest(&self, ev: InboundEvent, who: ExternalUserId) -> InboundItem; // Instruction | Answer

    /// Outbound: render to native form. render_question mints a CorrelationToken
    /// so the reply routes back to the Question's `gates` node.
    fn render_question(&self, q: &Question) -> (NativeMessage, CorrelationToken);
    fn render_notification(&self, n: &Notification) -> NativeMessage;
}

enum InboundItem { Instruction(Instruction), Answer(Answer) }
```

Authentication *mechanism* per channel (Slack request signing, Telegram webhook/bot-token secret, API OIDC/token) and the `ChannelIdentity → ExternalUserId` binding are owned by `08` (§3.9) and referenced, not redefined, here — exactly as §4.4 already defers authentication to `08`.
````

- [ ] **Step 6: Verify §4.5 inserted with the trait and types**

Run: `grep -n "### 4.5 Channel adapters\|trait ChannelAdapter\|struct ChannelIdentity\|CorrelationToken\|struct ChannelCapabilities" specs/06-interaction-and-mailbox.md`
Expected: all five present, `### 4.5` before `## 5. Resolved decisions`.

- [ ] **Step 7: Add a Resolved decision and an Open question**

In `## 5. Resolved decisions`, append a new numbered item (item 8, after the existing item 7):

```markdown
8. **The external boundary is a pluggable Channel Adapter.** The REST surface of §4.4 is **one concrete `ApiAdapter`** over a transport-agnostic contract; any channel (Slack, Telegram, SMS, …) is a `ChannelAdapter` implementation (§4.5) that authenticates a channel-native sender, resolves it to an `ExternalUserId` via the `08` binding table (§3.9), normalizes inbound events to `Instruction`/`Answer`, and renders `Question`/`Notification` best-effort with an explicit **correlation token**. Adapters **declare** capabilities (`ChannelCapabilities`); there is **no negotiation handshake** and the correlation token is **not** an authorization credential (§3.8). The core types and the Guardian state machine are unchanged.
```

In `## 6. Open questions & ambiguities`, append a new numbered item:

```markdown
3. **Cross-channel identity linking.** By default each `(channel_kind, native_id)` binds to its own `ExternalUserId` (§3.8, §4.5; binding owned by `08` §3.9), so the same human on Slack vs Telegram is two principals. The `ChannelIdentity → ExternalUserId` **indirection** makes it possible to later collapse several channel identities onto one principal **without changing the adapter contract**, but *when* and *how* to link — and whether per-channel trust should carry different authorization weight — is deferred. **Governance/identity-open.** Parked.
```

- [ ] **Step 8: Add a Channel row to the §7 relationships table**

In `## 7. Relationships to other specs`, the `08-trust-and-security.md` row already covers external identity. Update it to add the binding-table clause. Change the existing `08` row's final sentence to also read:

```markdown
| **`08-trust-and-security.md`** | Owns external identity & authorization (§5 decision 2): how `ExternalUserId` authenticates, how its session binds, how per-user **authorization scopes** are issued, and how answer-authorization is checked — the external-vs-internal trust boundary. **Also owns the `ChannelIdentity → ExternalUserId` binding table (§3.9) that each Channel Adapter (§4.5) resolves through.** This plane *assumes* an authenticated `ExternalUserId` and resolved scopes and consumes them; `08` defines how they come to be. The Mailbox is the system's outermost trust boundary. |
```

- [ ] **Step 9: Verify decisions, open question, and relationship edits**

Run: `grep -n "pluggable Channel Adapter\|Cross-channel identity linking\|ChannelIdentity → ExternalUserId binding table" specs/06-interaction-and-mailbox.md`
Expected: three matches — the §5 decision, the §6 open question, the §7 relationship clause.

- [ ] **Step 10: Consistency check — no core types renamed, `00`-authority note present**

Run: `grep -c "struct Instruction\|struct Goal\|struct Question\|struct Answer\|struct Notification" specs/06-interaction-and-mailbox.md`
Expected: `5` (all original core-type definitions in §4 still present, unchanged).

- [ ] **Step 11: Commit**

```bash
git add specs/06-interaction-and-mailbox.md
git commit -m "specs/06: add pluggable Channel Adapter boundary (ChannelAdapter trait, ChannelIdentity, correlation token)"
```

---

### Task 2: Promote channel types to canonical `00-overview.md`

**Files:**
- Modify: `specs/00-overview.md` — add the channel types to Canonical Types §7 (near the `UserPrincipal` definition at line 291); add two glossary entries in §8 (near the `Mailbox` / `External user` entries around line 359–361).

**Interfaces:**
- Consumes: `ChannelId`, `ChannelKind`, `ChannelIdentity` (defined in Task 1, `06` §4.5).
- Produces: the same three names promoted to canonical `00` §7 status, so `08`/`07`/`README` reference `00`, not `06`.

- [ ] **Step 1: Add canonical channel types to §7 after the `UserPrincipal` block**

After the line `struct UserPrincipal { id: ExternalUserId, scopes: Vec<AuthorizationScope> }` (line 291), insert:

```rust
/// A concrete transport a user reaches the system through (API, Slack, Telegram, …).
/// The Interaction plane (06 §4.5) plugs one ChannelAdapter in per ChannelKind;
/// the deliberative core stays transport-agnostic.
type ChannelId = Hash;
enum ChannelKind { Api, Slack, Telegram, Sms, Other(String) }

/// An authenticated channel-native sender, resolved to an ExternalUserId via the
/// 08-owned binding table (08 §3.9). Default binding is deterministic 1:1.
struct ChannelIdentity { channel_kind: ChannelKind, native_id: Text, auth_evidence: Bytes }
```

- [ ] **Step 2: Verify §7 canonical types added**

Run: `grep -n "type ChannelId\|enum ChannelKind\|struct ChannelIdentity" specs/00-overview.md`
Expected: three matches, all inside `## 7. Canonical Interfaces & Types` (before `## 8. Glossary`).

- [ ] **Step 3: Add glossary entries in §8 after the `Mailbox` entry**

After the `| **Mailbox** | The notification/question channel between the system and the user. |` line, insert two rows:

```markdown
| **Channel** | A concrete transport a user reaches the system through — HTTP API, Slack, Telegram, SMS. The Interaction plane's external boundary is pluggable across channels (`06` §2.6, §4.5). |
| **Channel Adapter** | The translation shell (one per `ChannelKind`) outside the Guardian that authenticates a channel-native sender, resolves it to an `ExternalUserId`, normalizes inbound events into canonical `Instruction`/`Answer`, and renders `Question`/`Notification` to native form. The user-connection analogue of `AgentHarness` (`04`). |
```

- [ ] **Step 4: Verify glossary entries added**

Run: `grep -n "^| \*\*Channel\*\*\|^| \*\*Channel Adapter\*\*" specs/00-overview.md`
Expected: two matches inside `## 8. Glossary`.

- [ ] **Step 5: Commit**

```bash
git add specs/00-overview.md
git commit -m "specs/00: promote Channel/ChannelKind/ChannelIdentity to canonical types + glossary"
```

---

### Task 3: Generalize identity binding in `08-trust-and-security.md`

**Files:**
- Modify: `specs/08-trust-and-security.md` — generalize §3.9 (line 526) and its `UserPrincipal`/`UserAuthn` block (lines 536–544); add threat row T13 after T12 (line 642); update the glossary "External user (principal)" line (line 32) and the `06` relationship row (line 673) to mention the binding table.

**Interfaces:**
- Consumes: `ChannelIdentity`, `ChannelKind`, `ExternalUserId` (canonical, `00` §7).
- Produces: `ChannelBinding` table concept + the rule "adapter verifies channel-native auth evidence; `08` resolves `ChannelIdentity → ExternalUserId`"; threat T13.

- [ ] **Step 1: Add a channel-binding bullet and type to §3.9**

In `### 3.9`, after the existing bullet "**Authenticated before a Guardian acts.**" (line 533), add a new bullet:

```markdown
- **Identity arrives through a channel and is resolved by a binding table.** A user reaches the system through a **Channel** (`06` §2.6) — API, Slack, Telegram, SMS. The `06` **Channel Adapter** authenticates the channel-native sender using **channel-native means** (Slack request signing, Telegram webhook/bot-token secret, API OIDC/token) and hands `08` a verified `ChannelIdentity`; `08` resolves it to an `ExternalUserId` through a **binding table**. The default binding is **deterministic 1:1** — `(channel_kind, native_id) → ExternalUserId` — so the same human on two channels is two principals today. The resolution is an **explicit indirection**, so future identity-linking can collapse several `ChannelIdentity`s onto one `ExternalUserId` **without changing the adapter contract** (linking policy open, `06` §6).
```

- [ ] **Step 2: Generalize the `UserAuthn` block**

Replace the `UserPrincipal` code block (lines 536–544, the `struct UserPrincipal { … } struct UserScope { … }` block and its `authn: UserAuthn` comment). Change the `authn` field comment and add the binding types:

```rust
/// A SEPARATE principal type from AgentId; authenticated at the 06 API boundary.
struct UserPrincipal {
    user: UserId,                 // NOT an AgentId; distinct namespace
    scopes: Vec<UserScope>,       // which goals / budgets this user may set
    authn: UserAuthn,             // channel-native authn evidence, verified by the 06 adapter
}
struct UserScope { goals: GoalPattern, budget: BudgetCeiling }

/// Resolves an authenticated channel-native identity (06 §4.5) to a UserPrincipal.
/// Default binding is deterministic 1:1; the indirection lets future identity-linking
/// map several ChannelIdentitys onto one principal without changing the 06 adapter.
struct ChannelBinding { identity: ChannelIdentity, principal: UserId }
type BindingTable = Map<ChannelIdentity, UserId>;
```

- [ ] **Step 3: Verify §3.9 edits**

Run: `grep -n "binding table\|struct ChannelBinding\|type BindingTable\|channel-native authn evidence" specs/08-trust-and-security.md`
Expected: the new bullet, `ChannelBinding`, `BindingTable`, and the revised `authn` comment all present in §3.9.

- [ ] **Step 4: Add threat row T13 after T12**

After the T12 table row (line 642), insert:

```markdown
| **T13** | **Channel spoofing / cross-channel identity confusion** | An attacker forges a channel-native sender (spoofed Slack signature, replayed Telegram webhook, guessed API token) or exploits the `ChannelIdentity → ExternalUserId` resolution to act as another principal; or a leaked/guessed **correlation token** is used to answer another user's blocking `Question`. | Impersonation of a bound principal; unauthorized instructions/answers; one user's blocked work answered by another. | The adapter **verifies channel-native auth evidence** before binding (§3.9); resolution is a **deterministic 1:1 binding table** (no ambient authority to cross principals). The **correlation token is not an authorization credential** — answer-authz is the `may_answer` scope check on the *resolved* `ExternalUserId` (`06` §3.8), so a stolen token cannot answer another principal's `Question`. All channel input still passes injection-scrub + the typed-`Proposal`/council-verify gate (T2). Per-channel authn hardening interacts with `06` §4.5. |
```

- [ ] **Step 5: Verify T13 added and numbering contiguous**

Run: `grep -n "\*\*T12\*\*\|\*\*T13\*\*" specs/08-trust-and-security.md`
Expected: T12 then T13 on consecutive table rows.

- [ ] **Step 6: Update the §8-adjacent glossary line and the `06` relationship row**

Update the glossary "External user (principal)" line (line 32) to append: change its end to read `… authenticated at the API boundary (`06`) — through a **Channel Adapter** that resolves a channel-native `ChannelIdentity` to this principal via a binding table (§3.9) — with per-user authorization scopes. Metatron is **multi-user** …` (keep the rest of the sentence intact).

Update the `06-interaction-and-mailbox` relationships row (line 673) to append one sentence: `This spec also owns the `ChannelIdentity → ExternalUserId` **binding table** (§3.9) that `06`'s Channel Adapters resolve through.`

- [ ] **Step 7: Verify relationship/glossary edits**

Run: `grep -n "Channel Adapter\|ChannelIdentity → ExternalUserId" specs/08-trust-and-security.md`
Expected: matches in the glossary line (32-area), §3.9, T13, and the `06` relationship row.

- [ ] **Step 8: Commit**

```bash
git add specs/08-trust-and-security.md
git commit -m "specs/08: channel-native identity binding table + T13 (channel spoofing / correlation-token misuse)"
```

---

### Task 4: Add channel telemetry dimension to `07-observability.md`

**Files:**
- Modify: `specs/07-observability.md` — the "Interaction plane (06) — Guardians" emission block in §3.2 (the `Events`/`Metrics`/`Spans` bullets around line 176–178).

**Interfaces:**
- Consumes: `ChannelKind` (canonical, `00` §7); the existing interaction metrics `interaction.instructions_total`, `interaction.ambiguity_rate`, `interaction.question_blocked_seconds`, `interaction.questions_open`.
- Produces: a `channel` metric dimension + a `render_degradation` event, referenced by no later task (terminal).

- [ ] **Step 1: Add the `channel` dimension and a degradation metric to the Interaction plane emission block**

In the `#### Interaction plane (06) — Guardians` block of §3.2, append to the **Metrics** bullet (after `interaction.questions_open (gauge)`):

```markdown
 All interaction metrics carry a **`channel` dimension** (`ChannelKind` — `api` | `slack` | `telegram` | `sms` | …) so interruption rate, answer latency, and open-question counts are attributable per channel. Adds `interaction.render_degradation_total{channel}` (counter — outbound `Question`s whose structured options were rendered lossily because the channel lacks `supports_structured_options`, `06` §3.8).
```

Append to the **Events** bullet: change the trailing `NotificationSent.` to `NotificationSent`, and add `, RenderDegraded` so the list ends `…, NotificationSent, RenderDegraded.`

- [ ] **Step 2: Verify the emission block edits**

Run: `grep -n "channel.*dimension\|render_degradation_total\|RenderDegraded" specs/07-observability.md`
Expected: three matches inside §3.2's Interaction plane block.

- [ ] **Step 3: Commit**

```bash
git add specs/07-observability.md
git commit -m "specs/07: add per-channel telemetry dimension + render-degradation signal"
```

---

### Task 5: Update `README.md` reading-order row and design decisions

**Files:**
- Modify: `specs/README.md` — the `06` row in the reading-order table (line 63); the "Key design decisions" list (around line 98, the Tenancy bullet).

**Interfaces:**
- Consumes: all prior tasks' concepts. Terminal task.

- [ ] **Step 1: Update the `06` reading-order row**

Change the `06` table row's "What it covers" cell to append `, pluggable channel adapters (API/Slack/Telegram/…)`:

```markdown
| **06** | [interaction-and-mailbox](./06-interaction-and-mailbox.md) | Multi-user intake, goal→setpoint, the two-step ambiguity gate, blocking-until-answered mailbox API, pluggable channel adapters (API/Slack/Telegram/…) | How the system talks to its users |
```

- [ ] **Step 2: Add a Channels key-design-decision bullet**

In `## Key design decisions`, after the **Tenancy** bullet (line 98), add:

```markdown
- **Channels** — the Interaction plane's external boundary is **pluggable**: a `ChannelAdapter` (one per API/Slack/Telegram/SMS/…) authenticates a channel-native sender, resolves it to an `ExternalUserId` via an `08`-owned binding table, and translates between heterogeneous transports and the unchanged canonical `Instruction`/`Question`/`Answer` core. Adapters **declare** capabilities (no negotiation handshake) and carry an explicit **correlation token** so replies route back to the exact blocking question. The REST API is just one adapter. Default identity binding is 1:1 per `(channel, native-id)`; cross-channel linking is deferred (`06`, `08`).
```

- [ ] **Step 3: Verify README edits**

Run: `grep -n "pluggable channel adapters\|\*\*Channels\*\*" specs/README.md`
Expected: two matches — the `06` row and the new key-design-decision bullet.

- [ ] **Step 4: Final cross-spec consistency check**

Run: `grep -rn "ChannelAdapter\|ChannelIdentity\|correlation token\|CorrelationToken\|binding table" specs/*.md | grep -c .`
Expected: multiple matches across `00`, `06`, `07`, `08`, `README` — confirming the concept is threaded through every touched spec with consistent naming.

- [ ] **Step 5: Commit**

```bash
git add specs/README.md
git commit -m "specs/README: add pluggable channels to reading order + key design decisions"
```

---

## Self-Review Notes

- **Spec coverage vs design doc §5 table:** `06` (Task 1), `08` (Task 3), `00` (Task 2), `07` (Task 4), `README` (Task 5) — all five rows covered.
- **Design forks covered:** adapter-only scope (Task 1 §2.6/§4.5), deterministic-linking-ready identity (Task 3 binding table), best-effort render + correlation token (Task 1 §3.8, T13 in Task 3).
- **Type consistency:** `ChannelId`/`ChannelKind`/`ChannelIdentity`/`ChannelCapabilities`/`CorrelationToken`/`ChannelAdapter` are spelled identically in Tasks 1–5; canonical promotion (`00`, Task 2) precedes external references (`08`/`07`/`README`).
- **No placeholders:** every step gives the literal Markdown/pseudotype to insert and a grep to verify it.
