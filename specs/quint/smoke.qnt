// # VERIFY: nonNegative
module smoke {
  var n: int
  action init = n' = 0
  action step = n' = n + 1
  val nonNegative = n >= 0
  run countsUpTest = init.then(step).then(step).then(all { assert(n == 2), n' = n })
}
