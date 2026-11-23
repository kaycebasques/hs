module Main (main) where

import SysCcBridge (hasSystemCompiler, sysMulAdd)

main :: IO ()
main = putStrLn ("system_cc=" <> show hasSystemCompiler <> " result=" <> show (sysMulAdd 6 6 6))
