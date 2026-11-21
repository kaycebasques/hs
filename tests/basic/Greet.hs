{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
module Greet (greetWithNative, sIfregConst) where

import Data.Int (Int64)
import qualified Data.Text as T
import Foreign.C.Types (CInt(..))
import Math.Core (computeValue)

foreign import ccall unsafe "native_add" c_native_add :: Int64 -> Int64 -> Int64
foreign import capi "sys/stat.h value S_IFREG" c_S_IFREG :: CInt

greetWithNative :: T.Text -> Int -> T.Text
greetWithNative who x =
    let total = c_native_add (fromIntegral (computeValue x)) 5
     in "Hello, " <> who <> " (" <> T.pack (show total) <> ")"

sIfregConst :: Int
sIfregConst = fromIntegral c_S_IFREG
