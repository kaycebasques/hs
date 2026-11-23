module Org.RulesHaskell.Types
    ( Label (..)
    , defaultLabel
    ) where

import Data.Text qualified as T

-- Relies on default_extensions = ["OverloadedStrings", "DerivingStrategies"].
newtype Label = Label { unLabel :: T.Text }
    deriving stock (Eq, Show)

defaultLabel :: Label
defaultLabel = Label "rules_haskell"
