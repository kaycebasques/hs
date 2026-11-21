{-# LANGUAGE TemplateHaskell #-}
module ThBootSplice (splicedFortyTwo) where

splicedFortyTwo :: Int
splicedFortyTwo = $( [| 20 + 22 |] )
