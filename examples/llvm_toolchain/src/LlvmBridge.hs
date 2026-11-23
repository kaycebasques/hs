{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module LlvmBridge
  ( isBuiltWithClang
  , addViaLlvmC
  ) where

import Data.Int (Int32)
import Foreign.C.Types (CInt (..))

foreign import capi "llvm_check.h value IS_CLANG_COMPILER"
  c_isClang :: CInt

foreign import ccall unsafe "llvm_c_add"
  c_llvmAdd :: Int32 -> Int32 -> Int32

isBuiltWithClang :: Bool
isBuiltWithClang = c_isClang == 1

addViaLlvmC :: Int32 -> Int32 -> Int32
addViaLlvmC = c_llvmAdd
