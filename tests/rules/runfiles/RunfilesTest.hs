module Main where

import Control.Monad (unless)
import DataLib (readRunfileTrimmed, resolveRunfile)
import Data.Maybe (fromMaybe)
import DirectDataLib (readDirectLibData, readTransitiveLibData)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq name expected actual =
    unless (expected == actual) $ do
        putStrLn ("FAIL [" ++ name ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
        exitFailure

main :: IO ()
main = do
    -- 1. Direct data file attached to hs_test
    testTxt <- readRunfileTrimmed "tests/rules/runfiles/test_data.txt"
    assertEq "hs_test direct data" "from-hs-test-direct-data" testTxt

    -- 2. Transitive data attached to direct hs_library dep
    directLibTxt <- readDirectLibData
    assertEq "hs_library direct dep data" "from-direct-hs-library-data" directLibTxt

    -- 3. 2-hop transitive data (data_provider_lib -> direct_data_lib -> hs_test)
    transLibTxt <- readTransitiveLibData
    assertEq "hs_library 2-hop transitive data" "from-hs-library-transitive-data" transLibTxt

    -- 4. Locate hs_binary passed via hs_test data and execute it as a tool
    toolPath <- resolveRunfile "tests/rules/runfiles/data_tool_bin"
    let expectedOut = "tool=from-hs-binary-tool-data\nlib=from-hs-library-transitive-data\n"

    -- 4a. Invoke with inherited Bazel test environment (--enable_runfiles & --incompatible_strict_action_env)
    (ec1, out1, err1) <- readCreateProcessWithExitCode (proc toolPath []) ""
    assertEq "data_tool_bin inherited env exit code" ExitSuccess ec1
    assertEq "data_tool_bin inherited env stderr" "" err1
    assertEq "data_tool_bin inherited env stdout" expectedOut out1

    -- 4b. Invoke with minimal stripped env containing ONLY RUNFILES_DIR + TEST_WORKSPACE (no PATH, no TEST_SRCDIR)
    mRf <- lookupEnv "RUNFILES_DIR"
    mTs <- lookupEnv "TEST_SRCDIR"
    ws <- fromMaybe "_main" <$> lookupEnv "TEST_WORKSPACE"
    let rfRoot = case (mRf, mTs) of
            (Just d, _) | not (null d) -> d
            (_, Just d) | not (null d) -> d
            _ -> error "Neither RUNFILES_DIR nor TEST_SRCDIR is set!"
        cp = (proc toolPath []) { env = Just [("RUNFILES_DIR", rfRoot), ("TEST_WORKSPACE", ws)] }
    (ec2, out2, err2) <- readCreateProcessWithExitCode cp ""
    assertEq "data_tool_bin RUNFILES_DIR-only exit code" ExitSuccess ec2
    assertEq "data_tool_bin RUNFILES_DIR-only stderr" "" err2
    assertEq "data_tool_bin RUNFILES_DIR-only stdout" expectedOut out2

    putStrLn "DATA & RUNFILES TEST PASSED!"
