{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Control.Monad (unless)
import Data.FileEmbed (embedStringFile)
import FileEmbedLib (embeddedLibText, runIoLibText)
import Language.Haskell.TH (litE, runIO, stringL)
import Language.Haskell.TH.Syntax (qAddDependentFile)
import System.Exit (exitFailure)

embeddedExeText :: String
embeddedExeText = $(embedStringFile "exe_embed_fixture.txt")

runIoExeText :: String
runIoExeText =
    $( do
        qAddDependentFile "tests/rules/th/exe_embed_fixture.txt"
        txt <- runIO (readFile "tests/rules/th/exe_embed_fixture.txt")
        litE (stringL txt)
     )

main :: IO ()
main = do
    let expectedLib = "rules_haskell compile-time library data fixture (UTF-8: Café λ)\n"
        expectedExe = "rules_haskell compile-time executable data fixture (UTF-8: Café λ)\n"
    unless (embeddedLibText == expectedLib) $ do
        putStrLn ("FAIL [embeddedLibText]: got " ++ show embeddedLibText)
        exitFailure
    unless (runIoLibText == expectedLib) $ do
        putStrLn ("FAIL [runIoLibText]: got " ++ show runIoLibText)
        exitFailure
    unless (embeddedExeText == expectedExe) $ do
        putStrLn ("FAIL [embeddedExeText]: got " ++ show embeddedExeText)
        exitFailure
    unless (runIoExeText == expectedExe) $ do
        putStrLn ("FAIL [runIoExeText]: got " ++ show runIoExeText)
        exitFailure
    putStrLn "FILE-EMBED & COMPILE-TIME DATA TH TEST PASSED!"
