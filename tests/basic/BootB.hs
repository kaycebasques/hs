module BootB (forestSum) where

import {-# SOURCE #-} BootA (Tree, treeSum)

forestSum :: [Tree] -> Int
forestSum = sum . map treeSum
