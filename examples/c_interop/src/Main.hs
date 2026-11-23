{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import NativeInterop (inlineAsmBias, inlineCScale, inlineCxxMedian3, zlibCrc32)
import Numeric (showHex)

main :: IO ()
main =
  putStrLn $
    "c=" <> show (inlineCScale 7)
      <> " cxx=" <> show (inlineCxxMedian3 9 3 7)
      <> " asm=" <> show (inlineAsmBias 30)
      <> " crc32=0x" <> showHex (zlibCrc32 "123456789") ""
