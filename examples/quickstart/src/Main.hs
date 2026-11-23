{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Greet (greetingFor)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  let target = case args of
        (name : _) -> T.pack name
        [] -> "Bazel 9"
  TIO.putStrLn (greetingFor target)
