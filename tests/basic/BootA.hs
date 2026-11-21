module BootA (Tree(..), treeSum) where

import BootB (forestSum)

data Tree = Leaf Int | Node [Tree]

treeSum :: Tree -> Int
treeSum (Leaf n) = n
treeSum (Node ts) = forestSum ts
