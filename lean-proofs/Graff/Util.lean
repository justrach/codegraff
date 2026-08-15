/- Shared list helpers. Kept tiny so each kernel file stays a spec, not a
library. -/

namespace Graff.Util

def mem (x : String) : List String → Bool
  | []      => false
  | y :: ys => x == y || mem x ys

def unique : List String → Bool
  | []      => true
  | x :: xs => !mem x xs && unique xs

def countWhere (p : α → Bool) : List α → Nat
  | []      => 0
  | x :: xs => (if p x then 1 else 0) + countWhere p xs

end Graff.Util
