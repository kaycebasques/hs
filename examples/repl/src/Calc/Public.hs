{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TemplateHaskell #-}

module Calc.Public
  ( calcMagic
  , calcTotal
  , splicedBonus
  , readReplBanner
  ) where

import Calc.Secret (secretStep)
import Calc.ThTag (mkBonusExp)
import Data.Int (Int32)
import Foreign.C.Types (CInt (..))
import System.Environment (lookupEnv)

foreign import capi "calc_c.h value CALC_C_MAGIC"
  c_calcMagic :: CInt

foreign import ccall unsafe "calc_c_scale"
  c_calcScale :: Int32 -> Int32

calcMagic :: Int
calcMagic = fromIntegral c_calcMagic

splicedBonus :: Int
splicedBonus = $(mkBonusExp 15)

calcTotal :: Int -> Int
calcTotal x =
  let scaled = fromIntegral (c_calcScale (fromIntegral x))
   in secretStep scaled + splicedBonus

readReplBanner :: IO String
readReplBanner = do
  mDir <- lookupEnv "RUNFILES_DIR"
  let base = maybe "." id mDir
  raw <- readFile (base ++ "/_main/data/banner.txt")
  pure $ case lines raw of
    (firstLine : _) -> firstLine
    [] -> ""
