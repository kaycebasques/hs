{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Control.Monad (unless)
import System.Exit (exitFailure)
import ThCrossLibMid (crossLibSplicedFortyTwo, mkSecondHopExp)

splicedInExe :: Int
splicedInExe = $(mkSecondHopExp 8)

main :: IO ()
main = do
    unless (crossLibSplicedFortyTwo == 42) $ do
        putStrLn ("FAIL: expected crossLibSplicedFortyTwo == 42, got " ++ show crossLibSplicedFortyTwo)
        exitFailure
    unless (splicedInExe == 50) $ do
        putStrLn ("FAIL: expected splicedInExe == 50, got " ++ show splicedInExe)
        exitFailure
    putStrLn "CROSS-LIBRARY TEMPLATE HASKELL TEST PASSED!"
