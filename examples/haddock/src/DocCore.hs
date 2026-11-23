-- | Core counter types and operations documented by @:core_haddock@.
module DocCore
  ( Counter (..)
  , stepCounter
  ) where

import DocInternal (internalStep)

-- | Monotonic integer counter.
newtype Counter = Counter
  { unCounter :: Int
  -- ^ Current counter value.
  }
  deriving (Eq, Show)

-- | Advance a t'Counter' by one step.
stepCounter :: Counter -> Counter
stepCounter (Counter n) = Counter (internalStep n)
