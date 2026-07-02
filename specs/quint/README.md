# Metatron Quint spec suite

Modular [Quint](https://quint-lang.org) formal specifications that actively test the
load-bearing ideas in the Metatron research architecture (`specs/*.md`). Each subsystem
is modeled as a state machine whose claimed invariants are exercised by typechecking,
named scenario tests, randomized simulation, and Apalache bounded model-checking. This
is a verification artifact, not a re-implementation — it sits alongside the prose specs
in `specs/` and reports back to them (see the design doc:
`docs/superpowers/specs/2026-07-01-metatron-quint-spec-suite-design.md`).

## Module map

```
specs/quint/
  base.qnt              # canonical types from 00 (shared vocabulary) — written, verified
  state_model.qnt        # 01 — Merkle log, typed diffs, CAS head        — written, verified
  consensus.qnt          # 02 — 6-layer funnel, propose≠dispose, quorum  — written, verified
  mailbox.qnt             # 06 — blocking mailbox, correlation tokens    — written, verified
  budgets.qnt             # 10 — hierarchical stock+rate, layered stop   — written, verified
  reputation.qnt          # 08 — reputation decay + swing-resistance     — written, verified
  sentinel.qnt            # 07/08 — Sentinel->reputation gate; ROB-06 re-check  — written, verified
  smoke.qnt               # toolchain smoke test (this task)
  verify.sh               # runs `quint verify` over every module's declared invariants
  README.md               # this file
```

All seven modules above are implemented and green (typecheck + test + `quint verify`);
see `FINDINGS.md` for the authoritative per-module status and per-invariant results.

Coverage is the core governance spine: shared `base` (from `00`) plus four subsystem
modules — `01` state-model, `02` consensus, `06` interaction/mailbox, `10` budgets.
`reputation.qnt` (from `08`) is a later addition that extends the suite beyond that
original four-module spine, modeling `08`'s decay-toward-zero-influence claim
(`00 §6` principle 4) as a falsifiable swing-resistance property. `sentinel.qnt`
(from `07`/`08`) is a further addition, modeling the Sentinel→reputation gate slice
of those specs (the ROB-06 re-check) as a bounded adversarial state machine. Other
subsystems (`03`, `04`, `05`, `09`, and the rest of `07`/`08`) remain out of scope
for now; the suite is structured to extend to them later. Each subsystem module imports only
`base` — cross-subsystem concepts are modeled as abstract oracles/parameters, not real
imports, so every module stays independently falsifiable and model-checkable.

**Abstraction note (`reputation.qnt`):** the council fixture is a 4-agent correlatable
`bloc {1,2,3,4}` plus a single honest anchor `{5}` that is only ever observed right.
This `{5}` observed-right-only shape is a deliberate bound that scopes swing-resistance
to the sub-majority-bloc threat (a correlated minority trying to swing a vote) — it does
not model full council capture (all 5 agents drifting in correlated lockstep), which is
break-glass/ROB-04 territory and out of scope here.

**Abstraction note (`sentinel.qnt`):** ground-truth guilt is the empty set and the one
honest Sentinel `{103}` only ever targets the guilty, so the honest-Sentinel and G0 paths
never fire in the adversarial `step` — deliberately isolating "can the compromised path move
weight without a sound justification?". Those paths are kept non-vacuous by dedicated
witnesses (`singleFindingInertTest`, `soundSlashReachableTest`). Sentinel ids are offset
10x from council ids so the two id spaces never alias in the `findings` pair set.

`smoke.qnt` is scaffolding for this task only: it proves the pinned toolchain
(typecheck / test / Apalache verify) actually runs end-to-end before any real subsystem
module is written.

## Abstraction conventions

Formal models are only meaningful if their abstractions are explicit:

- **Ids → bounded `int`.** `Hash`, `AgentId`, `BudgetNodeId`, and similar identifiers
  are modeled as small bounded integer domains (e.g. ≤3 agents, ≤2 users, a 5-member
  council, ≤4-deep commit chain) chosen so Apalache terminates.
- **No crypto.** `Signature`/`QuorumCertificate` collapse to an abstract
  `verifyQuorum(signers, kernelSet)` predicate. The protocol is tested, not Ed25519.
- **Correlation parameter.** LLM stochasticity is modeled as nondeterministic `any`
  choice over voter verdicts, with an explicit correlation parameter (shared
  `model_family`) so correlated-failure scenarios (e.g. ROB-01/ROB-02) are expressible.
- **Bounded domains everywhere.** Merkle collections become plain Quint maps/sets; the
  consensus aggregator is modeled by its properties (monotone, weight-bounded, `<0.5`→0,
  floored ≥0) rather than a concrete formula. Domain bounds exist so bounded
  model-checking terminates, not because the real systems are bounded.
- **`00` is normative.** Where a module's vocabulary could diverge, `base.qnt` follows
  `specs/00-overview.md`.
- **Prose specs are untouched.** `specs/*.md` bodies are never edited by this suite;
  findings are recorded separately (see the design doc's `FINDINGS.md` convention).

## Toolchain

Pinned via `.mise.toml` at the repo root:

- **Quint** — installed through mise's npm backend (`npm:@informalsystems/quint`),
  since mise has no first-party `quint` plugin. Exact version is pinned in
  `[tools]`.
- **Java (Temurin 21)** — mise-managed (`core:java`), required to run Apalache.
- **Apalache** — *not* mise-managed (it's a JVM tool distributed as a release
  tarball, not a mise plugin). Install the pinned release into
  `$APALACHE_HOME` (`~/.local/apalache`):

  ```bash
  mise install
  curl -sL https://github.com/informalsystems/apalache/releases/download/v0.47.2/apalache.tgz \
    | tar -xz -C "$HOME/.local"
  ```

  Note: `quint verify` bundles its own Apalache version manager and will
  auto-download a matching distribution into `~/.quint/apalache-dist-<version>`
  the first time it runs, independent of `$APALACHE_HOME`. The manual tarball
  install above is kept so `$APALACHE_HOME/bin/apalache-mc` is available directly
  (e.g. for `apalache-mc version` sanity checks) and so the pinned version is
  verified up front rather than implicitly trusted to quint's downloader.

## Running the suite

Everything is exposed as mise tasks (run from the repo root):

```bash
mise run quint-typecheck   # typecheck every module in specs/quint/*.qnt
mise run quint-test        # run every run/scenario test in specs/quint/*.qnt
mise run quint-verify      # Apalache bounded model-check each module's declared invariants
```

`quint-verify` shells out to `specs/quint/verify.sh`, which is also runnable directly:

```bash
bash specs/quint/verify.sh
```

You can also drive a single module manually, bypassing the loop over `*.qnt`:

```bash
quint typecheck specs/quint/smoke.qnt
quint test specs/quint/smoke.qnt
quint verify --invariant=nonNegative specs/quint/smoke.qnt
```

## The `# VERIFY:` convention

`verify.sh` decides which invariants to bounded-model-check per module by reading a
single top-of-file comment of the form:

```
// # VERIFY: inv1, inv2
```

(the leading `//` is required — Quint has no `#`-style comments; `# VERIFY:` is a
sub-tag inside a normal Quint line comment). `verify.sh` greps the first such line in
each module and passes the comma-separated invariant names straight to
`quint verify --invariant=...`. A module with no `# VERIFY:` line is skipped by
`quint-verify` (but is still typechecked and tested by the other two tasks).

## Test-naming convention

`quint test` only picks up `run`/`test` definitions whose name ends in `Test`
(Quint's own default matching rule — see `isMatchingTest` in the Quint CLI). Name
scenario runs accordingly, e.g. `run countsUpTest = ...`, or they will be silently
skipped rather than executed.
