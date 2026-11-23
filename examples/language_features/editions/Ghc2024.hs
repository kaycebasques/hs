module Ghc2024 (Stage (..), Val (..), evalVal) where

-- DataKinds, GADTs, DerivingStrategies, and LambdaCase are enabled in GHC2024.
import Data.Kind (Type)

data Stage = Draft | Published
  deriving stock (Eq, Show)

data Val :: Stage -> Type where
  DraftVal :: Int -> Val 'Draft
  PublishedVal :: Int -> Val 'Published

evalVal :: Val s -> Int
evalVal = \case
  DraftVal n -> n
  PublishedVal n -> n * 2
