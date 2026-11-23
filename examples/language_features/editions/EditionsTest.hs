{-# LANGUAGE DataKinds #-}

module Main (main) where

import Control.Monad (unless)
import Ghc2021 (ghc2021Sample)
import Ghc2024 (Val (..), evalVal)
import H2010 (lookupSumH2010)
import H98 (countdownH98)
import System.Exit (exitFailure)

main :: IO ()
main = do
  unless (countdownH98 5 == 15) exitFailure
  unless (lookupSumH2010 [("a", 20), ("b", 22)] "a" "b" == Just 42) exitFailure
  unless (ghc2021Sample == 1042) exitFailure
  unless (evalVal (PublishedVal 21) == 42 && evalVal (DraftVal 7) == 7) exitFailure
