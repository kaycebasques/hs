module Main (main) where

import FileNote (compilerMajorMinor)

main :: IO ()
main = putStrLn ("ghc=" <> show compilerMajorMinor)
