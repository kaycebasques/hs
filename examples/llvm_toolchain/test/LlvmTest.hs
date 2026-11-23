module Main (main) where

import Control.Monad (unless)
import LlvmBridge (addViaLlvmC, isBuiltWithClang)
import System.Exit (exitFailure)

main :: IO ()
main = do
  unless isBuiltWithClang $ do
    putStrLn "Expected IS_CLANG_COMPILER == 1 under toolchains_llvm"
    exitFailure
  unless (addViaLlvmC 20 22 == 42) $ do
    putStrLn "Unexpected llvm_c_add result"
    exitFailure
