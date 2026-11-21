module Math.Core (computeValue) where

import Math.Internal (secretOffset)

computeValue :: Int -> Int
computeValue x = x * 3 + secretOffset
