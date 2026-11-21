{-# LANGUAGE ForeignFunctionInterface #-}
module ExtLibMath (extHypot) where

import Foreign.C.Types (CDouble (..))

foreign import ccall unsafe "hypot"
    c_hypot :: CDouble -> CDouble -> CDouble

extHypot :: Double -> Double -> Double
extHypot x y = realToFrac (c_hypot (realToFrac x) (realToFrac y))
