{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Monad (unless)
import Ghc2021Lib (millionPlusFortyTwo, pairWithTag, sortedUnique)
import Ghc2024Lib (Box (..), Mode (..), TaggedVal (..), describeMode, evalTagged)
import H2010Lib (doIfH2010, lookupAddH2010)
import H98Lib (predH98, sumDownH98)
import LitBootA (LitEven (..), isLitEven)
import LitBootB (isLitOdd)
import LiterateBird (birdBanner, birdFibonacci)
import LiterateLatex (latexSquareSum)
import Org.RulesHaskell.Eval.Engine (adjustedScore, classifyScore)
import Org.RulesHaskell.Types (Label (..), defaultLabel)
import System.Exit (exitFailure)

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq name expected actual =
    unless (expected == actual) $ do
        putStrLn ("FAIL [" ++ name ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
        exitFailure

main :: IO ()
main = do
    -- Haskell98 (NPlusKPatterns)
    assertEq "predH98 10" 9 (predH98 10)
    assertEq "predH98 0" 0 (predH98 0)
    assertEq "sumDownH98 5" 15 (sumDownH98 5)

    -- Haskell2010 (DoAndIfThenElse + PatternGuards)
    assertEq "doIfH2010 True" (Just 42) (doIfH2010 True)
    assertEq "doIfH2010 False" (Just 10) (doIfH2010 False)
    assertEq "lookupAddH2010 hit" 30 (lookupAddH2010 [("a", 12), ("b", 18)] "a" "b")
    assertEq "lookupAddH2010 miss" (-1) (lookupAddH2010 [("a", 12)] "a" "z")

    -- GHC2021 (ImportQualifiedPost + NumericUnderscores + BinaryLiterals + TupleSections)
    assertEq "millionPlusFortyTwo" 1000042 millionPlusFortyTwo
    assertEq "pairWithTag" (7 :: Int, "ghc2021") (pairWithTag (7 :: Int))
    assertEq "sortedUnique" ([1, 2, 3] :: [Int]) (sortedUnique [3, 1, 2, 1, 3])

    -- GHC2024 (DataKinds, GADTs, DerivingStrategies, LambdaCase, RoleAnnotations)
    assertEq "describeMode Fast" "ghc2024:fast" (describeMode Fast)
    assertEq "describeMode Safe" "ghc2024:safe" (describeMode Safe)
    assertEq "evalTagged FastInt" 42 (evalTagged (FastInt 21))
    assertEq "evalTagged SafeInt" 0 (evalTagged (SafeInt (-5)))
    assertEq "Box deriving stock" (Box (42 :: Int)) (Box 42)

    -- Literate Haskell (.lhs Bird-style, .lhs LaTeX-style, and .lhs-boot mutual recursion)
    assertEq "birdBanner" "literate-bird-ok" birdBanner
    assertEq "birdFibonacci 8" 21 (birdFibonacci 8)
    assertEq "latexSquareSum [1..4]" 30 (latexSquareSum [1, 2, 3, 4])
    assertEq "isLitEven 6" (LitEven True) (isLitEven 6)
    assertEq "isLitOdd 6" False (isLitOdd 6)
    assertEq "isLitOdd 7" True (isLitOdd 7)

    -- default_extensions + custom ghc_opts (-Wall -Werror -O2) + hs_source_dirs = ["src"] + hidden_modules
    assertEq "classifyScore -1" (Label "negative") (classifyScore (-1))
    assertEq "classifyScore 0" defaultLabel (classifyScore 0)
    assertEq "classifyScore 50" (Label "medium") (classifyScore 50)
    assertEq "classifyScore 250" (Label "high") (classifyScore 250)
    assertEq "adjustedScore 35" 42 (adjustedScore 35)

    putStrLn "LANG & EXTENSIONS TEST PASSED!"
