{-# LANGUAGE TemplateHaskell #-}
module ThCrossModSplice (crossModAnswer) where

import ThHelper (mkAnswerExp)

crossModAnswer :: Int
crossModAnswer = $(mkAnswerExp 21)
