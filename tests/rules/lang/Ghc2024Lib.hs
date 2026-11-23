-- No {-# LANGUAGE #-} pragmas: DataKinds, GADTs, DerivingStrategies,
-- LambdaCase, and RoleAnnotations are all enabled by default_language = "GHC2024".
module Ghc2024Lib
    ( Mode (..)
    , TaggedVal (..)
    , Box (..)
    , describeMode
    , evalTagged
    ) where

import Data.Kind (Type)

data Mode = Fast | Safe
    deriving stock (Eq, Show)

type role Box representational
newtype Box a = Box a
    deriving stock (Eq, Show)

data TaggedVal :: Mode -> Type where
    FastInt :: Int -> TaggedVal 'Fast
    SafeInt :: Int -> TaggedVal 'Safe

describeMode :: Mode -> String
describeMode = \case
    Fast -> "ghc2024:fast"
    Safe -> "ghc2024:safe"

evalTagged :: TaggedVal m -> Int
evalTagged = \case
    FastInt n -> n * 2
    SafeInt n -> max 0 n
