module Main (main) where

import AssetLib (compileTimeAsset, readRuntimeLibAsset, resolveRunfile)
import Control.Monad (unless)
import System.Exit (exitFailure)

main :: IO ()
main = do
  let expectedLib = "compile-and-runtime-library-data\n"
  unless (compileTimeAsset == expectedLib) exitFailure
  runtimeLib <- readRuntimeLibAsset
  unless (runtimeLib == expectedLib) exitFailure

  testPath <- resolveRunfile "runfiles/test_asset.txt"
  testTxt <- readFile testPath
  unless (testTxt == "runtime-test-fixture\n") exitFailure
