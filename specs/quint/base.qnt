module base {
  // --- ids (bounded ints for MC; see README abstraction conventions) ---
  type AgentId = int
  type UserId  = int          // ExternalUserId — distinct principal type from AgentId
  type CostUnit = int         // 00 uses f64; ints keep MC decidable

  // --- agent taxonomy (00 §3) ---
  type Role = Guardian | Genesis | Worker | Compiler | Sentinel
  pure def isKernel(r: Role): bool = r == Guardian or r == Genesis

  // --- state layers (00 / 01) ---
  type Layer = Configuration | Progress | Both

  // --- domain bounds (Global Constraints) ---
  pure val MAX_AGENTS = 3
  pure val MAX_USERS  = 2
  pure val COUNCIL_N  = 5
  pure val MAX_DEPTH  = 4

  // consensus thresholds as exact rationals over integer weight sums:
  // pass iff 3*approve_weight >= 2*total_weight (ordinary) / 4*aw >= 3*tw (constitutional)
  pure def passesOrdinary(approveW: int, totalW: int): bool = 3 * approveW >= 2 * totalW
  pure def passesConstitutional(approveW: int, totalW: int): bool = 4 * approveW >= 3 * totalW

  run kernelClassificationTest = assert(isKernel(Guardian) and isKernel(Genesis)
                                    and not(isKernel(Worker)))
  run thresholdMathTest = assert(passesOrdinary(2, 3) and not(passesConstitutional(2, 3)))
}
