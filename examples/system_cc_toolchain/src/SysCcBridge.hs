{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module SysCcBridge
  ( hasSystemCompiler
  , sysMulAdd
  ) where

import Data.Int (Int32)
import Foreign.C.Types (CInt (..))

foreign import capi "sys_cc.h value HAS_GNU_OR_CLANG_CC"
  c_hasCompiler :: CInt

foreign import ccall unsafe "sys_cc_mul_add"
  c_mulAdd :: Int32 -> Int32 -> Int32 -> Int32

hasSystemCompiler :: Bool
hasSystemCompiler = c_hasCompiler == 1

sysMulAdd :: Int32 -> Int32 -> Int32 -> Int32
sysMulAdd = c_mulAdd
