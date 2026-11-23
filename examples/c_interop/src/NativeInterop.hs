{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module NativeInterop
  ( checksumSeed
  , checksumMix
  , checksumByteString
  , inlineCConstant
  , inlineCScale
  , inlineCxxMedian3
  , inlineAsmBias
  , rawAsmMul2
  , zlibVersionNumber
  , zlibCrc32
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Int (Int32, Int64)
import Data.Word (Word32, Word8)
import Foreign.C.Types (CChar, CInt (..), CSize (..), CUInt (..), CULong (..))
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import System.IO.Unsafe (unsafePerformIO)

-- 1. Repository cc_library via CApiFFI (#define + static inline) and ccall
foreign import capi "checksum.h value CHECKSUM_SEED"
  c_checksumSeed :: CUInt

foreign import capi "checksum.h checksum_mix"
  c_checksumMix :: Word32 -> Word32 -> Word32

foreign import ccall unsafe "checksum_bytes"
  c_checksumBytes :: Ptr Word8 -> CSize -> IO Word32

-- 2. Inline c_sources: C (.c), C++ (.cc), Preprocessed Assembly (.S), Raw Assembly (.s)
foreign import capi "inline_c.h value INLINE_C_CONSTANT"
  c_inlineCConstant :: CInt

foreign import ccall unsafe "inline_c_scale"
  c_inlineCScale :: Int32 -> Int32

foreign import ccall unsafe "inline_cxx_median3"
  c_inlineCxxMedian3 :: Int32 -> Int32 -> Int32 -> Int32

foreign import ccall unsafe "inline_asm_bias"
  c_inlineAsmBias :: Int64 -> Int64

foreign import ccall unsafe "raw_asm_mul2"
  c_rawAsmMul2 :: Int64 -> Int64

-- 3. Bazel Central Registry cc_library (@zlib//:zlib) via CApiFFI and ccall
foreign import capi "zlib.h value ZLIB_VERNUM"
  c_zlibVernum :: CInt

foreign import ccall unsafe "zlib.h crc32"
  c_zlibCrc32 :: CULong -> Ptr CChar -> CUInt -> IO CULong

checksumSeed :: Word32
checksumSeed = fromIntegral c_checksumSeed

checksumMix :: Word32 -> Word32 -> Word32
checksumMix = c_checksumMix

checksumByteString :: ByteString -> Word32
checksumByteString bs = unsafePerformIO $
  unsafeUseAsCStringLen bs $ \(ptr, len) ->
    c_checksumBytes (castPtr ptr) (fromIntegral len)

inlineCConstant :: Int
inlineCConstant = fromIntegral c_inlineCConstant

inlineCScale :: Int32 -> Int32
inlineCScale = c_inlineCScale

inlineCxxMedian3 :: Int32 -> Int32 -> Int32 -> Int32
inlineCxxMedian3 = c_inlineCxxMedian3

inlineAsmBias :: Int64 -> Int64
inlineAsmBias = c_inlineAsmBias

rawAsmMul2 :: Int64 -> Int64
rawAsmMul2 = c_rawAsmMul2

zlibVersionNumber :: Int
zlibVersionNumber = fromIntegral c_zlibVernum

zlibCrc32 :: ByteString -> Word32
zlibCrc32 bs = unsafePerformIO $ do
  seed <- c_zlibCrc32 0 nullPtr 0
  unsafeUseAsCStringLen bs $ \(ptr, len) ->
    fromIntegral <$> c_zlibCrc32 seed ptr (fromIntegral len)
