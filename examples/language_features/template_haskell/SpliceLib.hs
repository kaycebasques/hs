{-# LANGUAGE TemplateHaskell #-}

module SpliceLib (crossLibFortyTwo) where

import QuotesLib (mkTripleExp)

crossLibFortyTwo :: Int
crossLibFortyTwo = $(mkTripleExp 14)
