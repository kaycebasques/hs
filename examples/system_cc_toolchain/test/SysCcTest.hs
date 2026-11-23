module Main (main) where

import Control.Monad (unless)
import SysCcBridge (hasSystemCompiler, sysMulAdd)
import System.Exit (exitFailure)

main :: IO ()
main = do
  unless hasSystemCompiler $ do
    putStrLn "Expected HAS_GNU_OR_CLANG_CC == 1"
    exitFailure
  unless (sysMulAdd 6 6 6 == 42) $ do
    putStrLn "Unexpected sys_cc_mul_add output"
    exitFailure
