{-# LANGUAGE ForeignFunctionInterface #-}

module AsmFfi
    ( asmAddOffset
    , asmDouble
    ) where

import Data.Int (Int64)

foreign import ccall unsafe "hs_asm_add_offset"
    c_asmAddOffset :: Int64 -> Int64

foreign import ccall unsafe "hs_asm_double"
    c_asmDouble :: Int64 -> Int64

asmAddOffset :: Int64 -> Int64
asmAddOffset = c_asmAddOffset

asmDouble :: Int64 -> Int64
asmDouble = c_asmDouble
