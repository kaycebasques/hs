{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module MidLib (midSummary, midVersionStr, clibScaled) where

import Data.Version (showVersion)
import Foreign.C.Types (CInt(..))
import MidConsts (clibMagic, testFlag)
import qualified Paths_cabal_mid as Paths

foreign import ccall unsafe "clib_scale" c_clib_scale :: CInt -> CInt

clibScaled :: Int -> Int
clibScaled x = fromIntegral (c_clib_scale (fromIntegral x))

midVersionStr :: String
midVersionStr = showVersion Paths.version

midSummary :: String
midSummary =
#if MIN_VERSION_base(4,18,0) && MIN_VERSION_cabal_c_only(1,2,0)
    "mid-ok:" ++ show clibMagic ++ ":" ++ show testFlag ++ ":" ++ midVersionStr
#else
    "macro-mismatch"
#endif
