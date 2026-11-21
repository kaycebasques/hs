{-# LANGUAGE TemplateHaskell #-}

module ThCrossLibMid
    ( crossLibSplicedFortyTwo
    , mkSecondHopExp
    ) where

import Language.Haskell.TH (Exp, Q, integerL, litE)
import ThCrossLibBase (mkCrossLibTripledExp)

-- Evaluates a cross-library TH splice (calling C FFI) while compiling this hs_library.
crossLibSplicedFortyTwo :: Int
crossLibSplicedFortyTwo = $(mkCrossLibTripledExp 14)

-- Second-hop TH splice generator depending transitively on ThCrossLibBase.
mkSecondHopExp :: Int -> Q Exp
mkSecondHopExp delta =
    litE (integerL (fromIntegral (crossLibSplicedFortyTwo + delta)))
