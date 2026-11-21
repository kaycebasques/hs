module BootA (Tree(..), treeSum) where

data Tree = Leaf Int | Node [Tree]

treeSum :: Tree -> Int
