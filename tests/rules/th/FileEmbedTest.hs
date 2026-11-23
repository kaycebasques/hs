{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Control.Monad (unless)
import Data.FileEmbed (embedStringFile)
import FileEmbedLib (embeddedLibText, runIoLibText)
import System.Exit (exitFailure)

embeddedExeText :: String
embeddedExeText = $(embedStringFile "exe_embed_fixture.txt")

main :: IO ()
main = do
    let expectedLib = "rules_hs compile-time library data fixture\n"
        expectedExe = "rules_hs compile-time executable data fixture\n"
    unless (embeddedLibText == expectedLib) $ do
        putStrLn ("FAIL [embeddedLibText]: got " ++ show embeddedLibText)
        exitFailure
    unless (runIoLibText == expectedLib) $ do
        putStrLn ("FAIL [runIoLibText]: got " ++ show runIoLibText)
        exitFailure
    unless (embeddedExeText == expectedExe) $ do
        putStrLn ("FAIL [embeddedExeText]: got " ++ show embeddedExeText)
        exitFailure
    putStrLn "FILE-EMBED & COMPILE-TIME DATA TH TEST PASSED!"
