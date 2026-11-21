module Org.RulesHs.Eval.Engine
    ( classifyScore
    , adjustedScore
    ) where

import Org.RulesHs.Internal.Secret (secretOffset)
import Org.RulesHs.Types (Label (..), defaultLabel)

-- Relies on default_extensions = ["OverloadedStrings", "LambdaCase"].
classifyScore :: Int -> Label
classifyScore = \case
    n | n < 0     -> Label "negative"
      | n == 0    -> defaultLabel
      | n < 100   -> Label "medium"
      | otherwise -> Label "high"

adjustedScore :: Int -> Int
adjustedScore n = n + secretOffset
