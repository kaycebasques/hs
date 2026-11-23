{-# LANGUAGE TemplateHaskell #-}

module Main (main) where

import Control.Monad (unless)
import EmbeddedLib (embeddedBanner)
import Language.Haskell.TH (nameBase)
import QuotesLib (mkTripleExp, quotedMaybeName)
import SpliceLib (crossLibFortyTwo)
import System.Exit (exitFailure)

main :: IO ()
main = do
  unless (nameBase quotedMaybeName == "Maybe") exitFailure
  unless (crossLibFortyTwo == 42) exitFailure
  unless ($(mkTripleExp 10) == 30) exitFailure
  unless (embeddedBanner == "embedded-via-file-embed\n") exitFailure
