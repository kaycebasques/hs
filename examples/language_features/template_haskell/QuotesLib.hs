{-# LANGUAGE TemplateHaskellQuotes #-}

module QuotesLib
  ( quotedMaybeName
  , mkTripleExp
  ) where

import Language.Haskell.TH (Exp, Name, Q)

quotedMaybeName :: Name
quotedMaybeName = ''Maybe

mkTripleExp :: Int -> Q Exp
mkTripleExp n = [| n * 3 |]
