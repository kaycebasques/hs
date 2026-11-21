module Main (main) where

import Data.Text qualified as T
import Fetch (httpFetcher, newHttpManager)
import Sitemap (CountResult (..), Fetcher, countPages)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, hSetEncoding, stderr, stdout, utf8)
import Text.Printf (printf)

main :: IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  args <- getArgs
  case args of
    [] -> do
      hPutStrLn stderr "Usage: size <sitemap-url> [sitemap-url ...]"
      hPutStrLn stderr "Example: bazel run //:size -- https://docs.stripe.com/sitemap.xml"
      exitFailure
    urls -> do
      mgr <- newHttpManager
      let fetch = httpFetcher mgr
      results <- traverse (evaluateOne fetch) urls
      if and results
        then exitSuccess
        else exitFailure

evaluateOne :: Fetcher -> String -> IO Bool
evaluateOne fetch rawUrl = do
  res <- countPages (T.pack rawUrl) fetch
  case res of
    Right CountResult {crRootUrl, crPageCount, crSitemapsFetched} -> do
      printf "%8d pages  (%d sitemap(s))  %s\n" crPageCount crSitemapsFetched (T.unpack crRootUrl)
      pure True
    Left err -> do
      hPutStrLn stderr ("ERROR: " <> err)
      pure False
