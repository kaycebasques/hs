{-# LANGUAGE OverloadedStrings #-}
module Main where

import BootA (Tree(..), treeSum)
import CfgLib (cfgMagicCapi, cfgMagicHsc)
import qualified Data.Text.IO as TIO
import Greet (greetWithNative, sIfregConst)
import TopLib (topSummary)

main :: IO ()
main = do
    TIO.putStrLn (greetWithNative "rules_hs" 7)
    putStrLn ("s_ifreg=" ++ show sIfregConst)
    putStrLn ("tree=" ++ show (treeSum (Node [Leaf 10, Node [Leaf 20, Leaf 12]])))
    putStrLn ("cabal=" ++ topSummary)
    putStrLn ("cfg=" ++ show cfgMagicHsc ++ "/" ++ show cfgMagicCapi)
    -- Exercise GMP bignum arithmetic (verifies static libgmp.a works at runtime!)
    putStrLn ("bigint=" ++ show ((2 :: Integer) ^ (200 :: Int)))
