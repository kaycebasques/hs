{-# LANGUAGE OverloadedStrings #-}

-- | CLI entrypoint for @//docs:docs_gen@ — builds the @rules_hs@ static
-- documentation site hermetically using Hakyll + Pandoc + Skylighting.
module Main (main) where

import Control.Exception (SomeException, bracket, catch)
import Docs.Site (compileDocsSite)
import Docs.Types (SiteConfig (..))
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.Environment (getArgs)
import System.Exit (die, exitSuccess)
import System.FilePath ((</>))
import System.IO (openTempFile, hClose)

data CliFlags = CliFlags
  { cfContentDir :: !(Maybe FilePath)
  , cfTemplatesDir :: !(Maybe FilePath)
  , cfStaticDir :: !(Maybe FilePath)
  , cfBzlDir :: !(Maybe FilePath)
  , cfOutDir :: !(Maybe FilePath)
  , cfCacheDir :: !(Maybe FilePath)
  , cfStrictLinks :: !(Maybe Bool)
  }

emptyFlags :: CliFlags
emptyFlags = CliFlags Nothing Nothing Nothing Nothing Nothing Nothing Nothing

usage :: String
usage =
  unlines
    [ "Usage: docs_gen [OPTIONS]"
    , ""
    , "Compile rules_hs Markdown + Starlark sources into a static HTML documentation site."
    , ""
    , "Options:"
    , "  --content-dir <dir>     Markdown content root (default: docs/content)"
    , "  --templates-dir <dir>   Hakyll HTML templates directory (default: docs/templates)"
    , "  --static-dir <dir>      Static CSS/JS assets directory (default: docs/static)"
    , "  --bzl-dir <dir>         Starlark hs/ source directory for autodoc (default: hs)"
    , "  --out-dir <dir>         Output directory for built static site (required)"
    , "  --cache-dir <dir>       Scratch directory for Hakyll store/provider (default: auto temp dir)"
    , "  --strict-links          Enforce 100% internal link and #anchor checking"
    , "  --no-strict-links       Disable internal link checking"
    , "  -h, --help              Show this help message"
    ]

parseCli :: [String] -> Either String CliFlags
parseCli = go emptyFlags
  where
    go acc [] = Right acc
    go _ ("-h" : _) = Left usage
    go _ ("--help" : _) = Left usage
    go acc ("--content-dir" : v : rest) = go acc {cfContentDir = Just v} rest
    go acc ("--templates-dir" : v : rest) = go acc {cfTemplatesDir = Just v} rest
    go acc ("--static-dir" : v : rest) = go acc {cfStaticDir = Just v} rest
    go acc ("--bzl-dir" : v : rest) = go acc {cfBzlDir = Just v} rest
    go acc ("--out-dir" : v : rest) = go acc {cfOutDir = Just v} rest
    go acc ("--cache-dir" : v : rest) = go acc {cfCacheDir = Just v} rest
    go acc ("--strict-links" : rest) = go acc {cfStrictLinks = Just True} rest
    go acc ("--no-strict-links" : rest) = go acc {cfStrictLinks = Just False} rest
    go _ (arg : _) = Left ("Unknown or incomplete option: " ++ arg ++ "\n\n" ++ usage)

withManagedCacheDir :: Maybe FilePath -> (FilePath -> IO a) -> IO a
withManagedCacheDir (Just explicitDir) action = do
  createDirectoryIfMissing True explicitDir
  action explicitDir
withManagedCacheDir Nothing action = do
  baseTmp <- getTemporaryDirectory
  bracket
    ( do
        (probeFile, h) <- openTempFile baseTmp "rules_hs_docs_cache"
        hClose h
        let dir = probeFile ++ ".d"
        createDirectoryIfMissing True dir
        pure (probeFile, dir)
    )
    ( \(probeFile, dir) -> do
        removeDirectoryRecursive dir `catch` ignoreIO
        removeFile probeFile `catch` ignoreIO
    )
    (\(_, dir) -> action dir)
  where
    ignoreIO :: SomeException -> IO ()
    ignoreIO _ = pure ()

main :: IO ()
main = do
  setLocaleEncoding utf8
  args <- getArgs
  flags <- case parseCli args of
    Left msg
      | take 6 msg == "Usage:" -> putStr msg >> exitSuccess
      | otherwise -> die msg
    Right f -> pure f

  outDir <- case cfOutDir flags of
    Just o -> pure o
    Nothing -> die ("--out-dir <dir> is required.\n\n" ++ usage)

  let contentDir = maybe "docs/content" id (cfContentDir flags)
      templatesDir = maybe "docs/templates" id (cfTemplatesDir flags)
      staticDir = maybe "docs/static" id (cfStaticDir flags)
      bzlDir = maybe "hs" id (cfBzlDir flags)

  -- Enable --strict-links automatically whenever docs/content/index.md is present
  -- unless explicitly overridden on the CLI.
  strictLinks <- case cfStrictLinks flags of
    Just explicit -> pure explicit
    Nothing -> doesFileExist (contentDir </> "index.md")

  withManagedCacheDir (cfCacheDir flags) $ \cacheDir -> do
    let cfg =
          SiteConfig
            { scContentDir = contentDir
            , scTemplatesDir = templatesDir
            , scStaticDir = staticDir
            , scBzlDir = bzlDir
            , scOutDir = outDir
            , scCacheDir = cacheDir
            , scStrictLinks = strictLinks
            }
    res <- compileDocsSite cfg
    case res of
      Left err -> die err
      Right () -> exitSuccess
