{-# LANGUAGE CPP #-}

#include "HsBaseConfig.h"

-- | Core value primitives for testing @hs_haddock@ HTML, QuickJump,
-- hyperlinked source, and hermetic CPP preprocessing.
module HaddockCore
  ( CoreValue (..)
  , renderCoreValue
  ) where

import HaddockSecret (secretMultiplier)

-- | A documented algebraic wrapper around an 'Int' payload.
newtype CoreValue = CoreValue
  { unCoreValue :: Int
  -- ^ Extract the underlying integer payload.
  }
  deriving (Eq, Show)

-- | Scale a t'CoreValue' using CPP-configured constant and hidden helper.
renderCoreValue :: CoreValue -> String
renderCoreValue (CoreValue n) =
  show (n * secretMultiplier + HADDOCK_CPP_OFFSET)
