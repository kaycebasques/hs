{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent.MVar (modifyMVar, newMVar, readMVar)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Sitemap
  ( CountResult (..)
  , SitemapDocument (..)
  , countPages
  , decodePayload
  , parse
  )
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

testdataPath :: FilePath -> IO FilePath
testdataPath rel = do
  mSrc <- lookupEnv "TEST_SRCDIR"
  mWs <- lookupEnv "TEST_WORKSPACE"
  pure $ case (mSrc, mWs) of
    (Just src, Just ws) | not (null src) && not (null ws) -> src </> ws </> "testdata" </> rel
    _ -> "testdata" </> rel

readFixtureBytes :: FilePath -> IO ByteString
readFixtureBytes rel = testdataPath rel >>= BS.readFile

readFixtureText :: FilePath -> IO Text
readFixtureText rel = do
  bs <- readFixtureBytes rel
  case TE.decodeUtf8' bs of
    Left err -> failTest ("Fixture is not valid UTF-8 (" <> rel <> "): " <> show err)
    Right txt -> pure txt

failTest :: String -> IO a
failTest msg = do
  hPutStrLn stderr ("FAIL: " <> msg)
  exitFailure

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual =
  unless (expected == actual) $
    failTest (label <> "\n  expected: " <> show expected <> "\n  actual:   " <> show actual)

assertTrue :: String -> Bool -> IO ()
assertTrue label cond =
  unless cond $ failTest label

testUrlsetFixture :: IO ()
testUrlsetFixture = do
  xml <- readFixtureText "urlset.xml"
  assertEqual
    "parses canonical namespaced urlset.xml"
    ( Right
        ( UrlSet
            [ "https://docs.example.com/a?x=1&y=2"
            , "https://docs.example.com/b"
            ]
        )
    )
    (parse xml)

testSitemapIndexFixture :: IO ()
testSitemapIndexFixture = do
  xml <- readFixtureText "sitemapindex.xml"
  assertEqual
    "parses canonical sitemapindex.xml"
    ( Right
        ( SitemapIndex
            [ "https://docs.example.com/sitemap-1.xml"
            , "https://docs.example.com/sitemap-2.xml.gz"
            ]
        )
    )
    (parse xml)

testInvalidRootFixture :: IO ()
testInvalidRootFixture = do
  xml <- readFixtureText "invalid_root.xml"
  assertEqual
    "rejects invalid_root.xml with exact message"
    (Left "Unexpected root element <html> (expected <urlset> or <sitemapindex>)")
    (parse xml)

testGzippedFixture :: IO ()
testGzippedFixture = do
  gzBytes <- readFixtureBytes "urlset.xml.gz"
  plainText <- readFixtureText "urlset.xml"
  assertEqual "decodes canonical urlset.xml.gz" (Right plainText) (decodePayload gzBytes)

testRecursiveCrawlFixture :: IO ()
testRecursiveCrawlFixture = do
  sitemapBytes <- readFixtureBytes "crawl/sitemap.xml"
  part1Bytes <- readFixtureBytes "crawl/part1.xml"
  part2Bytes <- readFixtureBytes "crawl/part2.xml.gz"
  let responses =
        Map.fromList
          [ ("https://docs.example.com/sitemap.xml", sitemapBytes)
          , ("https://docs.example.com/part1.xml", part1Bytes)
          , ("https://docs.example.com/part2.xml.gz", part2Bytes)
          ]
      fetcher url =
        pure $ case Map.lookup url responses of
          Just bs -> Right bs
          Nothing -> Left ("HTTP 404 fetching " <> T.unpack url)
  res <- countPages "https://docs.example.com/sitemap.xml" fetcher
  assertEqual
    "recursively crawls sitemap index + gzipped child and deduplicates pages"
    ( Right
        CountResult
          { crRootUrl = "https://docs.example.com/sitemap.xml"
          , crPageCount = 3
          , crSitemapsFetched = 3
          }
    )
    res

testBomStripping :: IO ()
testBomStripping = do
  plainBytes <- readFixtureBytes "urlset.xml"
  plainText <- readFixtureText "urlset.xml"
  let withBom = BS.pack [0xef, 0xbb, 0xbf] <> plainBytes
  assertEqual "strips leading UTF-8 BOM" (Right plainText) (decodePayload withBom)

testCycleAndDuplicateAvoidance :: IO ()
testCycleAndDuplicateAvoidance = do
  fetchCounts <- newMVar (Map.empty :: Map.Map Text Int)
  let fixtures =
        Map.fromList
          [ ( "https://cycle.example.com/root.xml"
            , TE.encodeUtf8
                "<sitemapindex>\
                \<sitemap><loc>https://cycle.example.com/child.xml</loc></sitemap>\
                \<sitemap><loc>https://cycle.example.com/root.xml</loc></sitemap>\
                \<sitemap><loc>https://cycle.example.com/child.xml</loc></sitemap>\
                \</sitemapindex>"
            )
          , ( "https://cycle.example.com/child.xml"
            , TE.encodeUtf8
                "<sitemapindex>\
                \<sitemap><loc>https://cycle.example.com/root.xml</loc></sitemap>\
                \<sitemap><loc>https://cycle.example.com/leaf.xml</loc></sitemap>\
                \</sitemapindex>"
            )
          , ( "https://cycle.example.com/leaf.xml"
            , TE.encodeUtf8
                "<urlset>\
                \<url><loc>https://cycle.example.com/p1</loc></url>\
                \<url><loc>https://cycle.example.com/p2</loc></url>\
                \</urlset>"
            )
          ]
      fetcher url = do
        modifyMVar fetchCounts $ \m -> pure (Map.insertWith (+) url 1 m, ())
        pure $ case Map.lookup url fixtures of
          Just bs -> Right bs
          Nothing -> Left ("HTTP 404 fetching " <> T.unpack url)
  res <- countPages "https://cycle.example.com/root.xml" fetcher
  assertEqual
    "handles sitemap cycles and duplicate references"
    ( Right
        CountResult
          { crRootUrl = "https://cycle.example.com/root.xml"
          , crPageCount = 2
          , crSitemapsFetched = 3
          }
    )
    res
  counts <- readMVar fetchCounts
  assertEqual "each sitemap URL is fetched exactly once" [1, 1, 1] (Map.elems counts)

testBlankLocAndCaseInsensitiveRoot :: IO ()
testBlankLocAndCaseInsensitiveRoot = do
  let xml =
        "<UrlSet xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\
        \<URL><LOC>   </LOC></URL>\
        \<url><lastmod>2026-01-01</lastmod></url>\
        \<URL><Loc>  https://docs.example.com/only-valid  </Loc></URL>\
        \</UrlSet>"
  assertEqual
    "skips blank/missing <loc> and matches root/child tags case-insensitively"
    (Right (UrlSet ["https://docs.example.com/only-valid"]))
    (parse xml)

testCorruptGzipAndErrorPrefix :: IO ()
testCorruptGzipAndErrorPrefix = do
  let corruptGz = BS.pack [0x1f, 0x8b, 0x08, 0x00, 0xff, 0xff]
  case decodePayload corruptGz of
    Right _ -> failTest "expected corrupt gzip payload to return Left"
    Left err -> assertTrue ("expected gunzip error, got: " <> err) ("gunzip" `isInfixOf` err)

  res <- countPages "https://bad.example.com/invalid.xml" (\_ -> pure (Right "<html/>"))
  case res of
    Right _ -> failTest "expected invalid root during crawl to return Left"
    Left err ->
      assertTrue
        ("expected URL-prefixed error, got: " <> err)
        ("https://bad.example.com/invalid.xml: Unexpected root element <html>" `isInfixOf` err)

main :: IO ()
main = do
  testUrlsetFixture
  testSitemapIndexFixture
  testInvalidRootFixture
  testGzippedFixture
  testRecursiveCrawlFixture
  testBomStripping
  testCycleAndDuplicateAvoidance
  testBlankLocAndCaseInsensitiveRoot
  testCorruptGzipAndErrorPrefix
  putStrLn "ALL SITEMAP UNIT TESTS PASSED (9/9)!"
