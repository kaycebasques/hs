-- | Downstream client module verifying cross-target @haddock_deps@
-- @--read-interface@ hyperlinks to "HaddockCore".
module HaddockClient
  ( boostCore
  ) where

import HaddockCore (CoreValue (..))

-- | Increment a t'CoreValue' imported from @core_lib@.
boostCore :: CoreValue -> CoreValue
boostCore (CoreValue x) = CoreValue (x + 1)
