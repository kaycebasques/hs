{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Codec.Compression.GZip qualified as GZip
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List.Split (chunksOf)

main :: IO ()
main = do
  let raw = BL8.pack "rules_haskell-hackage-override-ok"
      roundtrip = GZip.decompress (GZip.compress raw)
  putStrLn $
    "chunks=" <> show (chunksOf 2 [1 :: Int, 2, 3, 4])
      <> " gzip_ok=" <> show (roundtrip == raw)
