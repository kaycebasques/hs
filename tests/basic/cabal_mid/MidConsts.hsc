{-# LANGUAGE ForeignFunctionInterface #-}
module MidConsts (clibMagic, testFlag) where

#include <clib.h>

clibMagic :: Int
clibMagic = #const CLIB_MAGIC

testFlag :: Int
testFlag = #const CABAL_TEST_FLAG
