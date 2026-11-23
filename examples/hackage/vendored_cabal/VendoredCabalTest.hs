module Main (main) where

import ConfiguredConsts (configuredFortyTwo)
import Control.Monad (unless)
import ExprLexer (lexExpr)
import ExprParser (evalExpr)
import LitSumParser (evalLitSum)
import ReexportedSubMod (subModTag)
import System.Exit (exitFailure)
import VendoredMainLib (embeddedPkgAsset, pkgVer)

main :: IO ()
main = do
  unless (configuredFortyTwo == 42) exitFailure
  unless (pkgVer == "1.4.0") exitFailure
  unless (embeddedPkgAsset == "vendored-cabal-data-ok\n") exitFailure
  unless (subModTag == "sublib-ok") exitFailure
  unless (evalExpr (lexExpr "2 + 5 * 8") == 42) exitFailure
  unless (evalLitSum (lexExpr "10 + 12 + 20") == 42) exitFailure
