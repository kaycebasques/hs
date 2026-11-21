{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module TopLib (topValue, topSummary) where

import Foreign.C.Types (CInt(..))
import MidLib (midSummary)

foreign import ccall unsafe "top_helper_fn" c_top_helper_fn :: CInt -> CInt

topValue :: Int -> Int
topValue x = fromIntegral (c_top_helper_fn (fromIntegral x))

topSummary :: String
topSummary =
#if MIN_VERSION_cabal_mid(0,4,0)
    midSummary ++ "|top=" ++ show (topValue 5)
#else
    "top-macro-mismatch"
#endif
