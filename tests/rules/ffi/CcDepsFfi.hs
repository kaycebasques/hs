{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
module CcDepsFfi
    ( Vec2 (..)
    , vecMagicVersion
    , readVecGlobalBias
    , initVec2
    , addVec2
    , dotVec2
    , weightedSumVec2
    ) where

import Data.Int (Int32, Int64)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Marshal.Array (withArrayLen)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (Storable (..))

data Vec2 = Vec2
    { vecX :: !Int32
    , vecY :: !Int32
    , vecWeight :: !Double
    }
    deriving (Eq, Show)

-- Matches C layout: int32_t x (0), int32_t y (4), double weight (8) => 16 bytes, align 8.
instance Storable Vec2 where
    sizeOf _ = 16
    alignment _ = 8
    peek ptr = do
        x <- peekByteOff ptr 0
        y <- peekByteOff ptr 4
        w <- peekByteOff ptr 8
        pure (Vec2 x y w)
    poke ptr (Vec2 x y w) = do
        pokeByteOff ptr 0 x
        pokeByteOff ptr 4 y
        pokeByteOff ptr 8 w

foreign import capi "vec.h value VEC_MAGIC_VERSION"
    c_vecMagicVersion :: CInt

foreign import ccall "&vec_global_bias"
    p_vecGlobalBias :: Ptr Int32

foreign import ccall unsafe "vec2_init"
    c_vec2Init :: Ptr Vec2 -> Int32 -> Int32 -> Double -> IO ()

foreign import ccall unsafe "vec2_add"
    c_vec2Add :: Ptr Vec2 -> Ptr Vec2 -> Ptr Vec2 -> IO ()

foreign import ccall unsafe "vec2_dot"
    c_vec2Dot :: Ptr Vec2 -> Ptr Vec2 -> IO Int64

foreign import ccall unsafe "vec2_weighted_sum"
    c_vec2WeightedSum :: Ptr Vec2 -> Int32 -> IO Double

vecMagicVersion :: Int
vecMagicVersion = fromIntegral c_vecMagicVersion

readVecGlobalBias :: IO Int32
readVecGlobalBias = peek (castPtr (plusPtr p_vecGlobalBias 0))

initVec2 :: Int32 -> Int32 -> Double -> IO Vec2
initVec2 x y w = alloca $ \outPtr -> do
    c_vec2Init outPtr x y w
    peek outPtr

addVec2 :: Vec2 -> Vec2 -> IO Vec2
addVec2 a b =
    with a $ \pa ->
        with b $ \pb ->
            alloca $ \pout -> do
                c_vec2Add pa pb pout
                peek pout

dotVec2 :: Vec2 -> Vec2 -> IO Int64
dotVec2 a b =
    with a $ \pa ->
        with b $ \pb ->
            c_vec2Dot pa pb

weightedSumVec2 :: [Vec2] -> IO Double
weightedSumVec2 xs =
    withArrayLen xs $ \len ptr ->
        c_vec2WeightedSum ptr (fromIntegral len)
