{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (forever, unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fetch (httpFetcher, newHttpManager)
import Network.Socket
  ( Family (AF_INET)
  , PortNumber
  , SockAddr (SockAddrInet)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , accept
  , bind
  , close
  , defaultProtocol
  , listen
  , setSocketOption
  , socket
  , socketPort
  , tupleToHostAddress
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Sitemap (CountResult (..), countPages)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

data FixtureBodies = FixtureBodies
  { fbSitemap :: !ByteString
  , fbPart1 :: !ByteString
  , fbPart2Gz :: !ByteString
  }

testdataPath :: FilePath -> IO FilePath
testdataPath rel = do
  mSrc <- lookupEnv "TEST_SRCDIR"
  mWs <- lookupEnv "TEST_WORKSPACE"
  pure $ case (mSrc, mWs) of
    (Just src, Just ws) | not (null src) && not (null ws) -> src </> ws </> "testdata" </> rel
    _ -> "testdata" </> rel

readFixtureBytes :: FilePath -> IO ByteString
readFixtureBytes rel = testdataPath rel >>= BS.readFile

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

openLoopbackListener :: IO Socket
openLoopbackListener = do
  sock <- socket AF_INET Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  listen sock 16
  pure sock

-- | Read an HTTP request header block up to @\\r\\n\\r\\n@.
recvHeaders :: Socket -> IO ByteString
recvHeaders conn = go BS.empty
  where
    go acc
      | "\r\n\r\n" `BS.isInfixOf` acc = pure acc
      | BS.length acc >= 65536 = pure acc
      | otherwise = do
          chunk <- recv conn 4096
          if BS.null chunk
            then pure acc
            else go (acc <> chunk)

extractUserAgent :: ByteString -> Maybe ByteString
extractUserAgent raw =
  case filter (BS8.isPrefixOf "user-agent:" . lowerAscii) (BS8.lines (BS8.filter (/= '\r') raw)) of
    (hdr : _) -> Just (BS8.strip (BS8.drop 1 (BS8.dropWhile (/= ':') hdr)))
    [] -> Nothing
  where
    lowerAscii = BS8.map (\c -> if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c)

extractRequestPath :: ByteString -> ByteString
extractRequestPath raw =
  case BS8.lines (BS8.filter (/= '\r') raw) of
    (reqLine : _) ->
      case BS8.words reqLine of
        (_method : path : _) -> path
        _ -> "/"
    [] -> "/"

buildResponse :: ByteString -> [(ByteString, ByteString)] -> ByteString -> ByteString
buildResponse statusLine extraHeaders body =
  BS.concat
    [ "HTTP/1.1 "
    , statusLine
    , "\r\n"
    , BS.concat [k <> ": " <> v <> "\r\n" | (k, v) <- extraHeaders]
    , "Content-Length: "
    , BS8.pack (show (BS.length body))
    , "\r\nConnection: close\r\n\r\n"
    , body
    ]

handleConnection :: PortNumber -> FixtureBodies -> MVar [Maybe ByteString] -> Socket -> IO ()
handleConnection port fixtures uaLog conn =
  ( do
      rawReq <- recvHeaders conn
      unless (BS.null rawReq) $ do
        modifyMVar_ uaLog (\xs -> pure (extractUserAgent rawReq : xs))
        let path = extractRequestPath rawReq
            baseUrl = BS8.pack ("http://127.0.0.1:" <> show port)
            resp = case path of
              "/sitemap.xml" ->
                buildResponse "200 OK" [("Content-Type", "application/xml")] (fbSitemap fixtures)
              "/part1.xml" ->
                buildResponse "200 OK" [("Content-Type", "application/xml")] (fbPart1 fixtures)
              "/part2.xml.gz" ->
                buildResponse "200 OK" [("Content-Type", "application/gzip")] (fbPart2Gz fixtures)
              "/redirect.xml" ->
                buildResponse "302 Found" [("Location", baseUrl <> "/sitemap.xml")] BS.empty
              _ ->
                buildResponse "404 Not Found" [("Content-Type", "text/plain")] "Not Found"
        sendAll conn resp
  )
    `finally` close conn

serveLoop :: Socket -> PortNumber -> FixtureBodies -> MVar [Maybe ByteString] -> IO ()
serveLoop listener port fixtures uaLog = forever $ do
  (conn, _addr) <- accept listener
  void $ forkIO $ void $ try @SomeException (handleConnection port fixtures uaLog conn)

rewriteSitemapBase :: Text -> ByteString -> ByteString
rewriteSitemapBase newBase raw =
  case TE.decodeUtf8' raw of
    Left _ -> raw
    Right txt -> TE.encodeUtf8 (T.replace "https://docs.example.com" newBase txt)

main :: IO ()
main = withSocketsDo $ do
  rawSitemap <- readFixtureBytes "crawl/sitemap.xml"
  part1 <- readFixtureBytes "crawl/part1.xml"
  part2Gz <- readFixtureBytes "crawl/part2.xml.gz"
  uaLog <- newMVar []

  bracket openLoopbackListener close $ \listener -> do
    port <- socketPort listener
    let baseUrl = T.pack ("http://127.0.0.1:" <> show port)
        fixtures =
          FixtureBodies
            { fbSitemap = rewriteSitemapBase baseUrl rawSitemap
            , fbPart1 = part1
            , fbPart2Gz = part2Gz
            }
    withAsync (serveLoop listener port fixtures uaLog) $ \_server -> do
      mgr <- newHttpManager
      let fetcher = httpFetcher mgr

      -- 1. Direct crawl over loopback HTTP (index + XML + .xml.gz + dedup)
      let directUrl = baseUrl <> "/sitemap.xml"
      directRes <- countPages directUrl fetcher
      assertEqual
        "crawls loopback sitemap index including .xml.gz child"
        ( Right
            CountResult
              { crRootUrl = directUrl
              , crPageCount = 3
              , crSitemapsFetched = 3
              }
        )
        directRes

      -- 2. HTTP 302 redirect handling
      let redirectUrl = baseUrl <> "/redirect.xml"
      redirectRes <- countPages redirectUrl fetcher
      assertEqual
        "follows HTTP 302 redirect and crawls target sitemap index"
        ( Right
            CountResult
              { crRootUrl = redirectUrl
              , crPageCount = 3
              , crSitemapsFetched = 3
              }
        )
        redirectRes

      -- 3. HTTP 404 error reporting
      let missingUrl = baseUrl <> "/missing.xml"
      missingRes <- countPages missingUrl fetcher
      case missingRes of
        Right r -> failTest ("expected HTTP 404 error, got: " <> show r)
        Left err ->
          assertTrue
            ("expected HTTP 404 message, got: " <> err)
            ("HTTP 404 fetching " `isInfixOf` err && "/missing.xml" `isInfixOf` err)

      -- 4. Verify custom User-Agent header on every request
      seenUas <- readMVar uaLog
      assertTrue "loopback server received requests" (length seenUas >= 7)
      assertTrue
        ("expected every request to send User-Agent: docs-size-tracker/0.1, got: " <> show seenUas)
        (all (== Just "docs-size-tracker/0.1") seenUas)

  putStrLn "ALL HTTP E2E LOOPBACK TESTS PASSED (4/4)!"
