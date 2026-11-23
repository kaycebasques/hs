{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import Greet (greetingFor, uniqueSortedTags)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let actual = greetingFor "  Haskell  "
      expected = "Hello, Haskell, from rules_haskell."
  unless (actual == expected) $ do
    putStrLn ("Expected: " <> show expected <> ", got: " <> show actual)
    exitFailure

  let tags = uniqueSortedTags [" bazel ", "haskell", "bazel"]
  unless (tags == ["bazel", "haskell"]) $ do
    putStrLn ("Unexpected sorted tags: " <> show tags)
    exitFailure
