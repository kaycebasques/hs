{-# LANGUAGE TemplateHaskell #-}

module AssetLib
  ( compileTimeAsset
  , resolveRunfile
  , readRuntimeLibAsset
  ) where

import Data.Maybe (fromMaybe)
import Language.Haskell.TH (litE, runIO, stringL)
import Language.Haskell.TH.Syntax (qAddDependentFile)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((</>))

-- Read data = ["lib_asset.txt"] at compile time inside Bazel's sandbox.
compileTimeAsset :: String
compileTimeAsset =
  $( do
      qAddDependentFile "lib_asset.txt"
      txt <- runIO (readFile "lib_asset.txt")
      litE (stringL txt)
   )

-- Resolve a workspace-relative runfile path at runtime.
resolveRunfile :: FilePath -> IO FilePath
resolveRunfile rel = do
  ws <- fromMaybe "_main" <$> lookupEnv "TEST_WORKSPACE"
  mRf <- lookupEnv "RUNFILES_DIR"
  mTs <- lookupEnv "TEST_SRCDIR"
  exe <- getExecutablePath
  let envCandidates =
        [ dir </> ws </> rel
        | Just dir <- [mRf, mTs]
        , not (null dir)
        ]
      candidates = envCandidates ++ [(exe ++ ".runfiles") </> ws </> rel, rel]
  pickExisting candidates
  where
    pickExisting [] = pure rel
    pickExisting [p] = pure p
    pickExisting (p : ps) = do
      exists <- doesFileExist p
      if exists then pure p else pickExisting ps

readRuntimeLibAsset :: IO String
readRuntimeLibAsset = readFile =<< resolveRunfile "runfiles/lib_asset.txt"
