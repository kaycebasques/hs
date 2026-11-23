{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import NativeInterop
  ( checksumByteString
  , checksumMix
  , checksumSeed
  , inlineAsmBias
  , inlineCConstant
  , inlineCScale
  , inlineCxxMedian3
  , rawAsmMul2
  , zlibCrc32
  , zlibVersionNumber
  )
import System.Exit (exitFailure)

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq label expected actual =
  unless (expected == actual) $ do
    putStrLn ("FAIL [" ++ label ++ "]: expected " ++ show expected ++ ", got " ++ show actual)
    exitFailure

main :: IO ()
main = do
  assertEq "CHECKSUM_SEED" 0x1234 checksumSeed
  assertEq "checksumMix 2 3" 19 (checksumMix 2 3)
  assertEq "checksumByteString \"AB\"" (checksumMix (checksumMix 0x1234 65) 66) (checksumByteString "AB")

  assertEq "INLINE_C_CONSTANT" 40 inlineCConstant
  assertEq "inlineCScale 7" 28 (inlineCScale 7)
  assertEq "inlineCxxMedian3" 7 (inlineCxxMedian3 9 3 7)
  assertEq "inlineAsmBias 30" 42 (inlineAsmBias 30)
  assertEq "rawAsmMul2 21" 42 (rawAsmMul2 21)

  unless (zlibVersionNumber >= 0x1300) $ do
    putStrLn ("Expected ZLIB_VERNUM >= 0x1300, got " ++ show zlibVersionNumber)
    exitFailure
  assertEq "zlibCrc32 123456789" 0xCBF43926 (zlibCrc32 "123456789")
