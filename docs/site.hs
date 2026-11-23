{-# LANGUAGE OverloadedStrings #-}

-- | Minimal canonical Hakyll site generator for rules_haskell (//docs:docs_gen).
module Main (main) where

import Data.Char (toLower)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Hakyll
import System.Environment (lookupEnv)
import System.FilePath ((</>))

main :: IO ()
main = do
  setLocaleEncoding utf8
  providerDir <- fromMaybe "docs" <$> lookupEnv "DOCS_PROVIDER_DIR"
  outDir <- fromMaybe "_site" <$> lookupEnv "DOCS_OUT_DIR"
  cacheDir <- fromMaybe "_cache" <$> lookupEnv "DOCS_CACHE_DIR"

  let conf =
        defaultConfiguration
          { providerDirectory = providerDir
          , destinationDirectory = outDir
          , storeDirectory = cacheDir </> "store"
          , tmpDirectory = cacheDir </> "tmp"
          }

  hakyllWith conf $ do
    match "templates/*" $ compile templateBodyCompiler

    match "css/*" $ do
      route idRoute
      compile copyFileCompiler

    match "content/**.md" $ do
      route $ gsubRoute "content/" (const "") `composeRoutes` setExtension "html"
      compile $
        pandocCompiler
          >>= loadAndApplyTemplate "templates/default.html" defaultContext
          >>= pure . fmap (withUrls rewriteMdUrl)
          >>= relativizeUrls

rewriteMdUrl :: String -> String
rewriteMdUrl url
  | isExternal url || any (`isPrefixOf` map toLower url) ["mailto:", "tel:", "javascript:", "data:", "#"] =
      url
  | ".md" `isSuffixOf` pathPart && length pathPart > 3 =
      take (length pathPart - 3) pathPart ++ ".html" ++ suffixPart
  | otherwise = url
  where
    (pathPart, suffixPart) = break (\c -> c == '#' || c == '?') url
