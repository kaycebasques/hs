module Main (main) where

import LlvmBridge (addViaLlvmC, isBuiltWithClang)

main :: IO ()
main = putStrLn ("clang=" <> show isBuiltWithClang <> " sum=" <> show (addViaLlvmC 20 22))
