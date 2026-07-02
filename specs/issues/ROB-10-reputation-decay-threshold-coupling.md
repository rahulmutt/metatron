---
id: ROB-10
title: Reputation's "decay to zero influence" claim is silent on the quantitative decay-rate / consensus-threshold coupling
severity: medium
category: robustness
status: open
affected_specs: [00-overview.md, 08-trust-and-security.md]
review_verdict: MODEL-SURFACED
---

# ROB-10 — Reputation's "decay to zero influence" claim is silent on the quantitative decay-rate / consensus-threshold coupling

## Status

**Open.** Surfaced by formal modeling (Quint suite `specs/quint/reputation.qnt`, Task 6
falsifiability probe), not by the original adversarial spec review. No prose change has
been applied yet; the suggested clarification below is proposed for `00 §6.4` / `08 §3.3`
and cross-referenced from ROB-03.

## What the model found

The spec's reputation narrative makes a **qualitative** claim in several places: `00 §6`
principle 4 says "chronically-drifting agents **decay toward zero influence** automatically";
`08 §3.3` frames the same mechanism as influence "**decayed toward the class prior**" (and
`08 §3.7`'s diagram shows "decay toward 0"). So a drifting — and especially a *correlated*
drifting — bloc "loses its teeth" and cannot swing consensus (`00 §6`, ROB-02 framing).

(A secondary imprecision the model makes relevant: `00 §6` says influence decays to **zero**,
while `08 §3.3` says it decays to the **class prior** — a *non-zero* floor. If the operative
floor is a non-zero class prior, a drift-flagged bloc retains that prior weight, which only
*sharpens* the coupling this finding is about: the residual per-agent weight after decay is
exactly the quantity that must stay below the ⅔ margin.)
The prose nowhere states the **quantitative precondition** on which that claim depends:
the decay *rate* must be fast enough, relative to the ⅔ ordinary pass threshold and the
drift-detection lag, that a fully drift-flagged bloc's *residual* weight cannot still sum
past the threshold.

`specs/quint/reputation.qnt` makes the claim falsifiable. The `swingResistance` invariant
— `not(passesOrdinary(taintedWeight, totalWeight))`, checked against the **same**
`base.passesOrdinary` predicate consensus uses — asserts that the combined weight of the
drift-flagged bloc (`driftCount >= DRIFT_LIMIT`) can never meet the ⅔ ordinary threshold.

At the shipped calibration (`CAP=6, DECAY=2, DRIFT_LIMIT=3`), the derived ceiling
`DRIFT_WEIGHT_CAP = max(0, CAP - DRIFT_LIMIT*DECAY) = 0`: every tainted agent is pinned to
weight 0, so `taintedWeight = 0` and `swingResistance` holds robustly (non-vacuously — the
`blocDefangedTest` witness drives the whole bloc `{1,2,3,4}` tainted and the invariant still
holds; Apalache confirms it over the full step relation).

Mutating **only** the decay rate to `DECAY=1` (leaving the threshold and drift limit
unchanged) raises the derived ceiling to `DRIFT_WEIGHT_CAP = max(0, 6-3) = 3` and breaks
the invariant. A concrete reachable trace: each of the four bloc agents is observed right
up to `CAP=6`, then observed wrong `DRIFT_LIMIT=3` times, landing at weight `3` with
`driftCount = 3` (drift-flagged). The honest anchor `{5}` is untouched at `START=4`. Then:

- `taintedWeight = 4 * 3 = 12`
- `totalWeight   = 12 + 4 = 16`
- `passesOrdinary(12, 16)` = `3*12 = 36 >= 2*16 = 32` → **true**, so `swingResistance` is
  **false**: a persistently-wrong, correlated bloc *does* clear the ⅔ threshold.

So the "decay to zero influence" guarantee is not unconditional — it holds only while

```
|bloc| * max(0, CAP - DRIFT_LIMIT*DECAY)   stays below the ⅔ margin of total weight
```

i.e. while `3 * (|bloc| * DRIFT_WEIGHT_CAP) < 2 * (|bloc| * DRIFT_WEIGHT_CAP + anchorFloor)`.
At `DECAY=2` this holds (`0 < 8`); at `DECAY=1` it fails (`36 >= 32`).

### Note on detectability (why the default gate does not catch this)

The `DECAY=1` counterexample is only reachable after the bloc first *climbs* to `CAP` and
then drifts down — a trace of ~20 steps. Apalache / `quint verify` default to
`--max-steps=10`, so a plain default-depth `quint verify --invariant=swingResistance` at
`DECAY=1` returns `[ok] No violation found` — **the fragility is invisible at the default
bound**. The violation was instead demonstrated deterministically with a concrete
reachability witness (`quint test`) that drives the exact 20-step trace above. This is
itself worth recording: the calibration's safety margin cannot be confirmed by the
default-depth gate alone.

## Affected spec §

- `00-overview.md` §6 (reputation-weighted ⅔/¾ thresholds) and §7 (`Reputation`) — states
  the weighting and thresholds but not the decay-rate precondition coupling them.
- `08-trust-and-security.md` §3.3 (reputation as trust substrate): "an agent that drifts
  off-character … has its influence decayed toward the class prior" and §3.7's "decay
  toward 0" diagram — qualitative only. §3.3.1's acknowledgement that "the exact prior
  magnitude and decay schedule are empirical and remain open (§5)" concerns the
  **class-prior inheritance bleed** (Sybil/rotation momentum), *not* the drift-decay-rate
  vs consensus-threshold precondition this finding is about.

## Relationship to ROB-02

Distinct. ROB-02 (the "correlated failure is the headline residual risk" framing) concerns
a **novel / undetected** correlated failure that has *no track record* for reputation to
price against. This finding is the complementary case: a **detected, already-priced**
correlated drift — the bloc *is* drift-flagged and reputation *is* down-weighting it — where
the down-weighting still fails to defang the bloc unless the decay rate is calibrated
against the threshold. ROB-02's mitigation (measured decorrelation) does not address this;
it is a precondition on the decay dynamics themselves.

## Suggested resolution

State the decay-rate precondition alongside the qualitative claim, in `00 §6.4` (or
wherever the reputation dynamics are normatively tuned) and cross-referenced from ROB-03:
the "decays toward zero influence" guarantee is conditional on the per-round decay being
fast enough — relative to the ⅔/¾ pass thresholds and the drift-detection lag — that a
fully drift-flagged bloc's residual reputation-weight cannot sum past the pass threshold,
i.e. `|bloc| * (residual per-agent weight after DRIFT_LIMIT decays)` must stay below the
⅔ margin of total council weight. Either state the precondition inline, or point to where
the decay schedule is empirically tuned (§5) and note that its calibration is *load-bearing
for swing-resistance*, not merely a convergence-speed knob.
