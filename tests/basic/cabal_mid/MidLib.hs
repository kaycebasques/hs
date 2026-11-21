{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module MidLib (midSummary, midVersionStr, clibScaled, midGhcInt, midUcredSize) where

import Data.Version (showVersion)
import Foreign.C.Types (CInt(..))
import MidConsts (clibMagic, ghcIntVersion, testFlag, ucredSize)
import qualified Paths_cabal_mid as Paths

foreign import ccall unsafe "clib_scale" c_clib_scale :: CInt -> CInt

clibScaled :: Int -> Int
clibScaled x = fromIntegral (c_clib_scale (fromIntegral x))

midVersionStr :: String
midVersionStr = showVersion Paths.version

midGhcInt :: Int
midGhcInt = ghcIntVersion

midUcredSize :: Int
midUcredSize = ucredSize

midSummary :: String
midSummary =
#if MIN_VERSION_base(4,18,0) && MIN_VERSION_cabal_c_only(1,2,0)
    "mid-ok:" ++ show clibMagic ++ ":" ++ show testFlag ++ ":" ++ midVersionStr
#else
    "macro-mismatch"
#endif
