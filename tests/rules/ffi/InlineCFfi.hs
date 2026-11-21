{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module InlineCFfi
    ( Accum (..)
    , capiScaledTag
    , inlineHelperTag
    , runAccum
    ) where

import Data.Int (Int32, Int64)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable (..))

data Accum = Accum
    { accumVal :: !Int64
    , accumCount :: !Int32
    }
    deriving (Eq, Show)

-- Matches C layout: int64_t acc (0), int32_t count (8), int32_t pad (12) => 16 bytes, align 8.
instance Storable Accum where
    sizeOf _ = 16
    alignment _ = 8
    peek ptr = do
        acc <- peekByteOff ptr 0
        cnt <- peekByteOff ptr 8
        pure (Accum acc cnt)
    poke ptr (Accum acc cnt) = do
        pokeByteOff ptr 0 acc
        pokeByteOff ptr 8 cnt
        pokeByteOff ptr 12 (0 :: Int32)

foreign import capi "inline_helper.h value INLINE_HELPER_TAG"
    c_inlineHelperTag :: CInt

foreign import capi "inline_helper.h value CAPI_SCALED_TAG"
    c_capiScaledTag :: CInt

foreign import ccall unsafe "accum_reset"
    c_accumReset :: Ptr Accum -> Int64 -> IO ()

foreign import ccall unsafe "accum_push"
    c_accumPush :: Ptr Accum -> Int32 -> IO ()

foreign import ccall unsafe "accum_finish"
    c_accumFinish :: Ptr Accum -> IO Int64

inlineHelperTag :: Int
inlineHelperTag = fromIntegral c_inlineHelperTag

capiScaledTag :: Int
capiScaledTag = fromIntegral c_capiScaledTag

runAccum :: Int64 -> [Int32] -> IO (Accum, Int64)
runAccum initial vals = alloca $ \ptr -> do
    c_accumReset ptr initial
    mapM_ (c_accumPush ptr) vals
    state <- peek ptr
    result <- c_accumFinish ptr
    pure (state, result)
