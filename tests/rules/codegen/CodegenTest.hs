{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import CalcLexer (Token (..), scanCalc)
import CalcParser (parseCalc)
import Control.Monad (unless)
import Data.Attoparsec.ByteString.FastSet (charClass, memberChar)
import qualified Data.ByteString.Char8 as BS8
import Data.UnixTime (UnixTime (..), fromEpochTime, toEpochTime)
import DataPkg (dataPkgVersionString, embeddedCabalData, withSubHelper)
import DemoReexportedSub (subHelperStep)
import Language.Haskell.Lexer (lexerPass0)
import LitCalcParser (parseLitSum)
import System.Console.ANSI (SGR (..), setSGRCode)
import System.Exit (exitFailure)
import Text.Show.Pretty (parseValue, valToStr)
import Text.XML (Document (..), Element (..), Name (..), parseLBS, def)
import qualified Data.ByteString.Lazy.Char8 as BL8
import qualified Text.Libyaml as Yaml
import Conduit (runConduitRes, (.|), sinkList)

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq label expected actual =
    unless (expected == actual) $ do
        putStrLn ("FAIL [" ++ label ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
        exitFailure

main :: IO ()
main = do
    -- 1. Source-bootstrapped Alex (.x) + Happy (.y) + Literate Happy (.ly)
    let toks = scanCalc "2 + 3 * (4 + 5)"
    assertEq "alex tokens" [TokInt 2, TokPlus, TokInt 3, TokStar, TokLParen, TokInt 4, TokPlus, TokInt 5, TokRParen] toks
    assertEq "happy .y precedence" 29 (parseCalc toks)
    assertEq "happy .ly sum" 42 (parseLitSum (scanCalc "10 + 12 + 20"))

    -- 2. Hackage packages using Alex & Happy + Paths_<pkg> (pretty-show & haskell-lexer)
    case parseValue "Just [1, 2]" of
        Nothing -> putStrLn "FAIL: pretty-show parseValue returned Nothing" >> exitFailure
        Just v -> assertEq "pretty-show roundtrip" "Just [ 1 , 2 ]" (unwords (words (valToStr v)))
    assertEq "haskell-lexer token count" 5 (length (lexerPass0 "x = 1"))

    -- 3. Direct Cabal sublibrary import (@hackage//:attoparsec__attoparsec-internal)
    --    and local hs_cabal_library sublibrary + Paths_<pkg> + compile-time data-files
    assertEq "attoparsec-internal FastSet" True (memberChar 'x' (charClass "xyz"))
    assertEq "hs_cabal_library Paths_ version" "0.3.1" dataPkgVersionString
    assertEq "hs_cabal_library compile-time data" "cabal-data-file-content:ok\n" embeddedCabalData
    assertEq "hs_cabal_library sublib call" 142 (withSubHelper 42)
    assertEq "hs_cabal_library reexported sublib" 107 (subHelperStep 7)

    -- 4. Cabal reexported-modules (@hackage//:ansi-terminal re-exports ansi-terminal-types)
    unless (not (null (setSGRCode [Reset]))) $ do
        putStrLn "FAIL: ansi-terminal setSGRCode returned empty string"
        exitFailure

    -- 5. Cabal build-type: Custom (cabal-doctest -> Simple: xml-conduit)
    case parseLBS def (BL8.pack "<root><item/></root>") of
        Left err -> putStrLn ("FAIL: xml-conduit parse error: " ++ show err) >> exitFailure
        Right doc -> assertEq "xml-conduit root name" "root" (nameLocalName (elementName (documentRoot doc)))

    -- 6. Cabal build-type: Configure + hsc2hs (unix-time)
    let ut = fromEpochTime 1700000000
    assertEq "unix-time epoch roundtrip" 1700000000 (toEpochTime ut)

    -- 7. C-only Cabal package (libyaml -> libyaml-clib)
    events <- runConduitRes (Yaml.decode (BS8.pack "key: val\n") .| sinkList)
    unless (length events >= 4) $ do
        putStrLn ("FAIL: libyaml expected >= 4 YAML events, got " ++ show (length events))
        exitFailure

    putStrLn "CODEGEN & HACKAGE CABAL FEATURES TEST PASSED!"
