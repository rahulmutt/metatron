---
id: OE-01
title: Multi-variable PID controller on an unmodelable plant
severity: high
category: overengineering
status: resolved
affected_specs: [03-control-loop.md, 00-overview.md]
review_verdict: SOFTENED
---

# OE-01 — Multi-variable PID controller on an unmodelable plant

## Problem

`03-control-loop.md` adopts the full apparatus of classical control theory — P/I/D
gains, anti-windup, derivative-on-measurement, Ziegler–Nichols tuning, a reserved
MIMO gain matrix `Γ` — while the spec itself concedes the preconditions PID needs
do not hold: no plant model, a nonstationary plant, a vetoing/lagging actuator (the
council), noisy LLM-judge sensors, and (§8a) **no stability proof**.

In practice the integral term over "stuck for a while" is just a counter, the
derivative is filtered down to near-zero, and the anti-thrash behavior is actually
delivered by **deadband + hysteresis + cooldown** (threshold logic), not by PID.
§5 then spends its full length fighting windup and oscillation that PID *introduces*
under exactly these conditions.

## Why it matters

The control-theoretic framing is the system's headline mental model ("steers itself
with a multi-variable PID controller") but it is mostly vocabulary. The rigor of the
words ("stability", "gains") outruns what the mechanism delivers, and the extra
machinery is cognitive load plus a tuning surface that doesn't transfer.

## Proposed change

Reduce to the load-bearing core: a **per-dimension proportional response to a
normalized measured-error vector**, gated by deadband + hysteresis + cooldown, with
a "persistently-stuck" counter, all routed through governance so the controller can
only advise. Reintroduce I/D terms (and the `Γ` matrix) only when a measured
oscillation in the simple version demonstrably requires them.

## Steelman caveat

PID is routinely deployed as a model-free heuristic on plants with no transfer
function, and "multi-variable PID over an error vector" can be read as a framing for
"steer on measured error, not on hope." The objection is to shipping the *full* PID
apparatus + Ziegler–Nichols + MIMO `Γ` as Resolved, not to closed-loop steering
itself. Keep the loop; drop the unearned terms.

## Acceptance

- [ ] §03 leads with the proportional + deadband/hysteresis/cooldown core.
- [ ] I, D, anti-windup, Ziegler–Nichols, and `Γ` are moved to "deferred until a
      measured oscillation demands them," or justified against an observed instability.
- [ ] Related: ROB-01 (the error vector measures disagreement, not wrongness).

## Resolution

Reduce to the lean core: §03 now leads with a per-dimension proportional response over
the normalized measured-error vector, gated by deadband + hysteresis + cooldown and a
persistently-stuck counter. I/D terms, anti-windup, Ziegler–Nichols tuning, and the
MIMO `Γ` matrix are moved to "deferred until a measured oscillation demands them."

Rationale: on an unmodelable, nonstationary plant the full PID apparatus is mostly
vocabulary — the anti-thrash behavior is actually delivered by the threshold logic, and
the deferred terms can be reintroduced against an observed instability rather than
shipped on faith.

Coverage: satisfies both acceptance checks — the proportional + deadband/hysteresis/
cooldown core leads, and the I/D/anti-windup/Ziegler–Nichols/`Γ` machinery is explicitly
parked behind a measured-oscillation trigger. The ROB-01 cross-reference (the error
vector measures disagreement, not wrongness) is carried in ROB-01's resolution.
