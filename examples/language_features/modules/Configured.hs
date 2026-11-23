-- OverloadedStrings, LambdaCase, and CPP are enabled via default_extensions.
module Configured (classify, scoreWithBias) where

import Configured.Internal (secretBias)
import Data.Text (Text)

classify :: Int -> Text
classify = \case
  0 -> "zero"
  n | n > 0 -> "positive"
  _ -> "negative"

scoreWithBias :: Int -> Int
scoreWithBias n = n + secretBias + FEATURE_BONUS
