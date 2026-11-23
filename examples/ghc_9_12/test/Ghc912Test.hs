{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import FileNote (compilerMajorMinor, roundtripNote)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))

main :: IO ()
main = do
  unless (compilerMajorMinor == 912) $ do
    putStrLn ("Expected GHC 912, got " <> show compilerMajorMinor)
    exitFailure

  tmpDir <- maybe "/tmp" id <$> lookupEnv "TEST_TMPDIR"
  let notePath = tmpDir </> "ghc_9_12_note.bin"
      expected = "ghc-9.12.4:file-io:ok"
  actual <- roundtripNote notePath expected
  unless (actual == expected) $ do
    putStrLn ("Roundtrip mismatch: " <> show actual)
    exitFailure
