module Main (main) where

import Control.Monad (unless)
import LiterateCalc (triangularNumber)
import System.Exit (exitFailure)

main :: IO ()
main = unless (triangularNumber 9 == 45) exitFailure
