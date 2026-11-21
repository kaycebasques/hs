{-# LANGUAGE ForeignFunctionInterface #-}
module CxxFfi (cxxSortedWeightedSum) where

import Data.Int (Int32)

foreign import ccall unsafe "cxx_sorted_weighted_sum"
    c_cxxSortedWeightedSum :: Int32 -> Int32 -> Int32 -> Int32

cxxSortedWeightedSum :: Int32 -> Int32 -> Int32 -> Int32
cxxSortedWeightedSum = c_cxxSortedWeightedSum
