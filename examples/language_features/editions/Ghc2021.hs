module Ghc2021 (ghc2021Sample) where

-- ImportQualifiedPost and NumericUnderscores are enabled by default in GHC2021.
import Data.List qualified as L

ghc2021Sample :: Int
ghc2021Sample = L.foldl' (+) 0 [1_000, 42]
