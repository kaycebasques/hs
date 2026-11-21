{-# LANGUAGE OverloadedStrings #-}
module Main where

import qualified Data.Text as T
import qualified Data.Text.IO as TIO

main :: IO ()
main = do
    TIO.putStrLn (T.intercalate ":" ["rules_hs", "hermetic", "ok"])
    putStrLn ("pow2_256=" ++ show ((2 :: Integer) ^ (256 :: Int)))
