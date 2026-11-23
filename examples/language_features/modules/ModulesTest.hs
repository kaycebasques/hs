{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Configured (classify, scoreWithBias)
import Control.Monad (unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  unless (classify 0 == "zero" && classify 5 == "positive") exitFailure
  unless (scoreWithBias 20 == 42) exitFailure
