module Main where

import Control.Monad (unless)
import Language.Haskell.TH (nameBase, pprint, runQ)
import System.Exit (exitFailure)
import ThBootSplice (splicedFortyTwo)
import ThCrossModSplice (crossModAnswer)
import ThQuotesLib
    ( quotedAddTree
    , quotedExpSummary
    , quotedJustValueName
    , quotedMaybeTypeName
    )

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq name expected actual =
    unless (expected == actual) $ do
        putStrLn ("FAIL [" ++ name ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
        exitFailure

main :: IO ()
main = do
    -- 1. TemplateHaskellQuotes (pure AST construction, no compile-time splice evaluation)
    assertEq "''Maybe nameBase" "Maybe" (nameBase quotedMaybeTypeName)
    assertEq "'Just nameBase" "Just" (nameBase quotedJustValueName)

    summary <- quotedExpSummary
    assertEq "quoted [| 1 + 2 |] AST" "1 + 2" summary

    rendered <- pprint <$> runQ quotedAddTree
    unless ("20" `isInfixOfStr` rendered && "22" `isInfixOfStr` rendered) $ do
        putStrLn ("FAIL [pprint quotedAddTree]: unexpected " ++ show rendered)
        exitFailure

    -- 2. Boot-package TemplateHaskell splice: $( [| 20 + 22 |] )
    assertEq "boot-only TH splice" 42 splicedFortyTwo

    -- 3. Same-library cross-module TemplateHaskell splice: $(mkAnswerExp 21)
    assertEq "same-library cross-module TH splice" 42 crossModAnswer

    putStrLn "TEMPLATE HASKELL TEST PASSED!"
  where
    isInfixOfStr needle haystack =
        any (startsWith needle) (tailsStr haystack)
    startsWith [] _ = True
    startsWith _ [] = False
    startsWith (x : xs) (y : ys) = x == y && startsWith xs ys
    tailsStr [] = [[]]
    tailsStr s@(_ : xs) = s : tailsStr xs
