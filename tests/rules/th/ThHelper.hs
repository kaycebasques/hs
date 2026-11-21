{-# LANGUAGE TemplateHaskellQuotes #-}
module ThHelper (mkAnswerExp) where

import Language.Haskell.TH (Exp, Q)

mkAnswerExp :: Int -> Q Exp
mkAnswerExp n = [| n * 2 |]
