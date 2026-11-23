{-# LANGUAGE OverloadedStrings #-}

-- | Minimal static HTTP preview server for //docs:site using wai-app-static + warp.
module Main (main) where

import Data.String (fromString)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Network.Wai.Application.Static (defaultFileServerSettings, staticApp)
import qualified Network.Wai.Handler.Warp as Warp
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die, exitSuccess)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hSetBuffering, stdout)
import Text.Read (readMaybe)

main :: IO ()
main = do
  setLocaleEncoding utf8
  hSetBuffering stdout LineBuffering
  (host, port, mDir) <- parseArgs ("127.0.0.1", 8000, Nothing) =<< getArgs
  siteDir <- maybe findSiteDir pure mDir
  let settings =
        Warp.setHost (fromString host)
          . Warp.setPort port
          . Warp.setBeforeMainLoop
            (putStrLn $ "Serving " ++ siteDir ++ " at http://" ++ host ++ ":" ++ show port ++ "/")
          $ Warp.defaultSettings
  Warp.runSettings settings (staticApp (defaultFileServerSettings siteDir))

parseArgs :: (String, Int, Maybe FilePath) -> [String] -> IO (String, Int, Maybe FilePath)
parseArgs acc [] = pure acc
parseArgs _ (f : _)
  | f `elem` ["-h", "--help"] =
      putStrLn "Usage: serve [--host ADDR] [--port PORT] [--site-dir DIR]" >> exitSuccess
parseArgs (_, p, d) ("--host" : h : rest) = parseArgs (h, p, d) rest
parseArgs (h, _, d) ("--port" : pStr : rest) =
  case readMaybe pStr of
    Just p | p >= 0 && p <= 65535 -> parseArgs (h, p, d) rest
    _ -> die ("Invalid --port: " ++ pStr)
parseArgs (h, p, _) ("--site-dir" : d : rest) = parseArgs (h, p, Just d) rest
parseArgs _ (a : _) = die ("Unknown argument: " ++ a)

findSiteDir :: IO FilePath
findSiteDir = do
  bases <- traverse lookupEnv ["RUNFILES_DIR", "TEST_SRCDIR"]
  let candidates =
        [r </> repo </> "docs/site" | Just r <- bases, repo <- ["_main", "rules_haskell"]]
          ++ ["docs/site", "bazel-bin/docs/site"]
  go candidates
  where
    go [] = die "Could not locate built docs site; pass --site-dir <dir>."
    go (c : cs) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go cs
