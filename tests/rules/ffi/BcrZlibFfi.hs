{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module BcrZlibFfi
    ( bcrZlibVernum
    , bcrZlibCrc32
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Word (Word32)
import Foreign.C.Types (CChar, CInt (..), CUInt (..), CULong (..))
import Foreign.Ptr (Ptr, nullPtr)
import System.IO.Unsafe (unsafePerformIO)

foreign import capi "zlib.h value ZLIB_VERNUM"
    c_zlibVernum :: CInt

foreign import ccall unsafe "zlib.h crc32"
    c_crc32 :: CULong -> Ptr CChar -> CUInt -> IO CULong

bcrZlibVernum :: Int
bcrZlibVernum = fromIntegral c_zlibVernum

bcrZlibCrc32 :: ByteString -> Word32
bcrZlibCrc32 bs = unsafePerformIO $ do
    seed <- c_crc32 0 nullPtr 0
    unsafeUseAsCStringLen bs $ \(ptr, len) ->
        fromIntegral <$> c_crc32 seed ptr (fromIntegral len)
