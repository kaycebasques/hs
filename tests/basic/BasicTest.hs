{-# LANGUAGE OverloadedStrings #-}
module Main where

import BootA (Tree(..), treeSum)
import CfgLib (cfgMagicCapi, cfgMagicHsc)
import Control.Monad (unless)
import qualified Data.Text as T
import Greet (greetWithNative, sIfregConst)
import MidLib (clibScaled, midSummary, midVersionStr)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import TopLib (topSummary, topValue)

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq label expected actual =
    unless (expected == actual) $ do
        putStrLn ("FAIL [" ++ label ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
        exitFailure

resolveFixture :: FilePath -> IO FilePath
resolveFixture rel = do
    mSrc <- lookupEnv "TEST_SRCDIR"
    mWs <- lookupEnv "TEST_WORKSPACE"
    case (mSrc, mWs) of
        (Just s, Just w) -> pure (s ++ "/" ++ w ++ "/" ++ rel)
        _ -> pure rel

main :: IO ()
main = do
    -- 1. Multi-library DAG + hidden_modules + CcInfo C FFI
    assertEq "greetWithNative" (T.pack "Hello, bazel (36)") (greetWithNative "bazel" 7)
    -- 2. CApiFFI
    assertEq "S_IFREG" 32768 sIfregConst
    -- 3. .hs-boot mutual recursion
    assertEq "hs-boot treeSum" 42 (treeSum (Node [Leaf 10, Node [Leaf 20, Leaf 12]]))
    -- 4. hs_cabal_library: C-only + textual .c include + hsc2hs + Paths_* + MIN_VERSION_* + cpp_options
    assertEq "midVersionStr" "0.4.2" midVersionStr
    assertEq "midSummary" "mid-ok:42:7:0.4.2" midSummary
    assertEq "clibScaled" 52 (clibScaled 5)
    -- 5. Transitive install_includes header propagation (cabal_top -> cabal_mid -> cabal_c_only)
    assertEq "topValue" 94 (topValue 5)
    assertEq "topSummary" "mid-ok:42:7:0.4.2|top=94" topSummary
    -- 6. build-type: Configure + generated header in hsc2hs & CApiFFI
    assertEq "cfgMagicHsc" 1337 cfgMagicHsc
    assertEq "cfgMagicCapi" 1337 cfgMagicCapi
    -- 7. GMP static bigint arithmetic
    assertEq "bigint 2^200"
        "1606938044258990275541962092341162602522202993782792835301376"
        (show ((2 :: Integer) ^ (200 :: Int)))
    -- 8. Runfiles data propagation
    fixturePath <- resolveFixture "tests/basic/fixture.txt"
    content <- readFile fixturePath
    assertEq "fixture.txt" "rules_hs-hermetic-fixture" (filter (`notElem` ("\r\n" :: String)) content)

    putStrLn "ALL BASIC TESTS PASSED!"
