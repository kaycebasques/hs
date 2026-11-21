{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Monad (unless)
import Ghc2021Lib (millionPlusFortyTwo, pairWithTag, sortedUnique)
import H2010Lib (doIfH2010, lookupAddH2010)
import H98Lib (predH98, sumDownH98)
import Org.RulesHs.Eval.Engine (adjustedScore, classifyScore)
import Org.RulesHs.Types (Label (..), defaultLabel)
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

    -- default_extensions + custom ghc_opts (-Wall -Werror -O2) + hs_source_dirs = ["src"] + hidden_modules
    assertEq "classifyScore -1" (Label "negative") (classifyScore (-1))
    assertEq "classifyScore 0" defaultLabel (classifyScore 0)
    assertEq "classifyScore 50" (Label "medium") (classifyScore 50)
    assertEq "classifyScore 250" (Label "high") (classifyScore 250)
    assertEq "adjustedScore 35" 42 (adjustedScore 35)

    putStrLn "LANG & EXTENSIONS TEST PASSED!"
