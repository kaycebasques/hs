{-# LANGUAGE OverloadedStrings #-}
module Main where

import AsmFfi (asmAddOffset, asmDouble)
import BcrZlibFfi (bcrZlibCrc32, bcrZlibVernum)
import CcDepsFfi
    ( Vec2 (..)
    , addVec2
    , dotVec2
    , initVec2
    , readVecGlobalBias
    , vecMagicVersion
    , weightedSumVec2
    )
import Control.Monad (unless)
import CxxFfi (cxxSortedWeightedSum)
import ExtLibMath (extHypot)
import InlineCFfi (Accum (..), capiScaledTag, inlineHelperTag, runAccum)
import System.Exit (exitFailure)

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq name expected actual =
    unless (expected == actual) $ do
        putStrLn ("FAIL [" ++ name ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
        exitFailure

main :: IO ()
main = do
    -- 1. cc_library -> cc_deps: CApiFFI header constant, global data symbol, structs, pointers, arrays
    assertEq "VEC_MAGIC_VERSION" 2026 vecMagicVersion
    bias <- readVecGlobalBias
    assertEq "vec_global_bias" 100 bias

    v1 <- initVec2 3 4 1.5
    v2 <- initVec2 10 (-2) 2.5
    assertEq "vec2_init v1" (Vec2 3 4 1.5) v1
    assertEq "vec2_init v2" (Vec2 10 (-2) 2.5) v2

    vSum <- addVec2 v1 v2
    assertEq "vec2_add" (Vec2 13 2 4.0) vSum

    dot <- dotVec2 v1 v2
    assertEq "vec2_dot" 22 dot

    wSum <- weightedSumVec2 [v1, v2]
    -- (3+4)*1.5 + (10-2)*2.5 = 10.5 + 20.0 = 30.5
    assertEq "vec2_weighted_sum" 30.5 wSum

    -- 2. hs_library inline c_sources + hdrs + include_dirs + cc_options (-DINLINE_SCALE=3) + CApiFFI -optc
    assertEq "INLINE_HELPER_TAG" 77 inlineHelperTag
    assertEq "CAPI_SCALED_TAG (-optc -DINLINE_SCALE=3)" 33 capiScaledTag
    (st, finished) <- runAccum 10 [5, 7, 8]
    -- acc = 10 + 5 + 7 + 8 = 30, count = 3; finish = 30 * 3 + 3 = 93
    assertEq "accum state" (Accum 30 3) st
    assertEq "accum_finish" 93 finished

    -- 3. C++ c_sources (.cc) with -std=c++17 and C++ runtime linking
    -- sorted(9, 2, 5) = [2, 5, 9] -> 2*1 + 5*2 + 9*3 + 9 = 48
    assertEq "cxxSortedWeightedSum" 48 (cxxSortedWeightedSum 9 2 5)

    -- 4. Inline assembly c_sources (.S preprocessed with -DASM_OFFSET=22 + .s raw)
    assertEq "asmAddOffset 20" 42 (asmAddOffset 20)
    assertEq "asmDouble 21" 42 (asmDouble 21)

    -- 5. Bazel Central Registry cc_deps (@zlib//:zlib via CApiFFI + ccall)
    unless (bcrZlibVernum >= 0x1300) $ do
        putStrLn ("FAIL [bcrZlibVernum]: expected >= 0x1300, got " ++ show bcrZlibVernum)
        exitFailure
    -- Standard IEEE CRC-32 of "123456789" is 0xCBF43926
    assertEq "bcrZlibCrc32 123456789" 0xCBF43926 (bcrZlibCrc32 "123456789")

    -- 6. hs_cabal_library extra_libraries = ["m"]
    assertEq "extHypot 3 4" 5.0 (extHypot 3.0 4.0)

    putStrLn "C INTEROP FFI TEST PASSED!"
