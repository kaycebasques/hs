module DataLib
    ( resolveRunfile
    , readRunfileTrimmed
    , readLibData
    ) where

import Data.Maybe (fromMaybe)
import System.Directory (doesFileExist)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath ((</>))

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

readRunfileTrimmed :: FilePath -> IO String
readRunfileTrimmed rel = do
    p <- resolveRunfile rel
    raw <- readFile p
    pure (filter (`notElem` ("\r\n" :: String)) raw)

readLibData :: IO String
readLibData = readRunfileTrimmed "tests/rules/runfiles/lib_data.txt"
