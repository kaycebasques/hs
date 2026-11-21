{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module CfgLib (cfgMagicHsc, cfgMagicCapi) where

#include <GeneratedCfg.h>
import Foreign.C.Types (CInt(..))

foreign import capi "GeneratedCfg.h value CFG_MAGIC_NUM" c_cfg_magic :: CInt

cfgMagicHsc :: Int
cfgMagicHsc = #const CFG_MAGIC_NUM

cfgMagicCapi :: Int
cfgMagicCapi = fromIntegral c_cfg_magic
