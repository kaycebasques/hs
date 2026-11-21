module Ghc2021Lib (millionPlusFortyTwo, pairWithTag, sortedUnique) where

-- ImportQualifiedPost, NumericUnderscores, BinaryLiterals, TupleSections are GHC2021 defaults.
import Data.List qualified as L

millionPlusFortyTwo :: Int
millionPlusFortyTwo = 1_000_000 + 0b101010

pairWithTag :: a -> (a, String)
pairWithTag = (, "ghc2021")

sortedUnique :: Ord a => [a] -> [a]
sortedUnique xs = [x | (x : _) <- L.group (L.sort xs)]
