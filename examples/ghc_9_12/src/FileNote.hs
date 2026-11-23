{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | GHC 9.12.4 verification library using the @file-io@ boot package.
module FileNote
  ( compilerMajorMinor
  , roundtripNote
  ) where

import Data.ByteString (ByteString)
import System.File.OsPath qualified as FileIO
import System.OsPath (encodeUtf)

#if __GLASGOW_HASKELL__ != 912
#error "Expected GHC 9.12.x (__GLASGOW_HASKELL__ == 912)"
#endif

-- | Return GHC's numeric @__GLASGOW_HASKELL__@ version (912 on GHC 9.12.4).
compilerMajorMinor :: Int
compilerMajorMinor = __GLASGOW_HASKELL__

-- | Write and read back raw bytes via GHC 9.12's @file-io@ boot library.
roundtripNote :: FilePath -> ByteString -> IO ByteString
roundtripNote path payload = do
  osPath <- encodeUtf path
  FileIO.writeFile' osPath payload
  FileIO.readFile' osPath
