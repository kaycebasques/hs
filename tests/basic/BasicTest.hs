{-# LANGUAGE OverloadedStrings #-}
module Main where

import BootA (Tree(..), treeSum)
import CfgLib (cfgMagicCapi, cfgMagicHsc)
import Control.Exception (try)
import Control.Monad (unless)
import qualified Data.Text as T
import Greet (greetWithNative, sIfregConst)
import MidLib (clibScaled, midGhcInt, midSummary, midUcredSize, midVersionStr)
import qualified Reexported.List as RL
import qualified Reexported.MathCore as RMC
import SubDupA (subDupAVal)
import SubDupB (subDupBVal)
import System.Console.Terminfo (SetupTermError, Terminal, getCapability, setupTerm, setupTermFromEnv, termColors)
import System.Environment (lookupEnv, unsetEnv)
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
    assertEq "hsc2hs __GLASGOW_HASKELL__" 910 midGhcInt
    assertEq "hsc2hs struct ucred > 0" True (midUcredSize > 0)
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
    assertEq "fixture.txt" "rules_haskell-hermetic-fixture" (filter (`notElem` ("\r\n" :: String)) content)

    -- 9. Pure reexported-modules (boot package-qualified + hs_library shell-discovered)
    assertEq "Reexported.List.sort" [1, 2, 3 :: Int] (RL.sort [3, 1, 2])
    assertEq "Reexported.MathCore.computeValue" 25 (RMC.computeValue 5)

    -- 10. Injective unit IDs (//tests/basic/sub:dup vs //tests/basic:sub_dup)
    assertEq "subDupAVal + subDupBVal" 303 (subDupAVal + subDupBVal)

    -- 11. Hermetic static libtinfo.a engine via @hs_boot//:terminfo
    unsetEnv "TERM"
    rEmpty <- (try (setupTerm "") :: IO (Either SetupTermError Terminal))
    assertEq "empty setupTerm returns Left SetupTermError" True (either (const True) (const False) rEmpty)
    tEnvDumb <- setupTermFromEnv
    assertEq "headless setupTermFromEnv defaults to dumb (no colors)" Nothing (getCapability tEnvDumb termColors)
    tXterm <- setupTerm "xterm-256color"
    assertEq "static libtinfo.a xterm-256color termColors" (Just 256) (getCapability tXterm termColors)

    putStrLn "ALL BASIC TESTS PASSED!"
