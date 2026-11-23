{-# LANGUAGE ForeignFunctionInterface #-}

#include "ConfiguredVal.h"
#include "tiny_clib.h"

module ConfiguredConsts (configuredFortyTwo) where

foreign import ccall unsafe "tiny_clib_base"
  c_tinyClibBase :: Int

configuredFortyTwo :: Int
configuredFortyTwo = c_tinyClibBase + (#const CONFIGURED_OFFSET)
