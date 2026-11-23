{-# LANGUAGE TemplateHaskellQuotes #-}

module Calc.ThTag (mkBonusExp) where

import Language.Haskell.TH (Exp, Q)

mkBonusExp :: Int -> Q Exp
mkBonusExp n = [| n + 7 |]
