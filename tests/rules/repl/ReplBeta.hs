{-# LANGUAGE CApiFFI #-}

module ReplBeta (betaCombined, cMacroConst) where

import Foreign.C.Types (CInt (..))
import ReplAlpha (alphaExported)
import ReplHidden (hiddenBonus)

foreign import capi "repl_c.h repl_c_scale"
    c_repl_c_scale :: CInt -> CInt -> CInt

foreign import capi "repl_c.h value REPL_C_MAGIC"
    c_repl_c_magic :: CInt

cMacroConst :: Int
cMacroConst = fromIntegral c_repl_c_magic

betaCombined :: Int -> Int
betaCombined x =
    alphaExported x
        + hiddenBonus
        + fromIntegral (c_repl_c_scale (fromIntegral x) 3)
