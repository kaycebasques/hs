{-# LANGUAGE OverloadedStrings #-}

-- | Zero-Python, zero-Node pure-Haskell static HTTP preview server (@//docs:serve@)
-- serving the built @//docs:site@ artifact over @127.0.0.1:8000@ (configurable via @--port@).
module Main (main) where

import Control.Concurrent (forkFinally)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forever, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Char (digitToInt, isHexDigit, toLower)
import Network.Socket
  ( AddrInfo (..)
  , AddrInfoFlag (..)
  , Socket
  , SocketOption (..)
  , SocketType (..)
  , accept
  , bind
  , close
  , defaultHints
  , getAddrInfo
  , listen
  , openSocket
  , setSocketOption
  , socketPort
  )
import Network.Socket.ByteString (recv, sendAll)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die, exitSuccess)
import System.FilePath (splitDirectories, takeExtension, (</>))
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)

data ServeOpts = ServeOpts
  { soHost :: !String
  , soPort :: !Int
  , soSiteDir :: !(Maybe FilePath)
  }

defaultServeOpts :: ServeOpts
defaultServeOpts =
  ServeOpts
    { soHost = "127.0.0.1"
    , soPort = 8000
    , soSiteDir = Nothing
    }

usage :: String
usage =
  unlines
    [ "Usage: serve [OPTIONS]"
    , ""
    , "Serve the built rules_haskell documentation site over HTTP."
    , ""
    , "Options:"
    , "  --host <addr>      Bind address (default: 127.0.0.1)"
    , "  --port <port>      TCP port to listen on (default: 8000)"
    , "  --site-dir <dir>   Built site directory (default: auto-resolved from Bazel runfiles)"
    , "  -h, --help         Show this help message"
    ]

parseServeArgs :: [String] -> Either String ServeOpts
parseServeArgs = go defaultServeOpts
  where
    go opts [] = Right opts
    go _ ("-h" : _) = Left usage
    go _ ("--help" : _) = Left usage
    go opts ("--host" : h : rest) = go opts {soHost = h} rest
    go opts ("--port" : pStr : rest) =
      case reads pStr of
        [(p, "")] | p >= 0 && p <= 65535 -> go opts {soPort = p} rest
        _ -> Left ("Invalid --port value: " ++ pStr)
    go opts ("--site-dir" : d : rest) = go opts {soSiteDir = Just d} rest
    go _ (arg : _) = Left ("Unknown or incomplete option: " ++ arg ++ "\n\n" ++ usage)

resolveDefaultSiteDir :: IO (Maybe FilePath)
resolveDefaultSiteDir = do
  mRunfiles <- lookupEnv "RUNFILES_DIR"
  mTestSrc <- lookupEnv "TEST_SRCDIR"
  let bases =
        [ r </> "_main" | Just r <- [mRunfiles, mTestSrc] ]
          ++ [ r </> "rules_haskell" | Just r <- [mRunfiles, mTestSrc] ]
          ++ ["."]
      candidates = [b </> "docs" </> "site" | b <- bases] ++ ["bazel-bin/docs/site"]
  findFirstDir candidates
  where
    findFirstDir [] = pure Nothing
    findFirstDir (c : cs) = do
      ok <- doesDirectoryExist c
      if ok then pure (Just c) else findFirstDir cs

main :: IO ()
main = do
  setLocaleEncoding utf8
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  args <- getArgs
  opts <- case parseServeArgs args of
    Left msg
      | take 6 msg == "Usage:" -> putStr msg >> exitSuccess
      | otherwise -> die msg
    Right o -> pure o

  siteDir <- case soSiteDir opts of
    Just explicit -> do
      ok <- doesDirectoryExist explicit
      if ok
        then pure explicit
        else die ("--site-dir does not exist: " ++ explicit)
    Nothing -> do
      mFound <- resolveDefaultSiteDir
      case mFound of
        Just d -> pure d
        Nothing -> die "Could not locate built docs site directory; pass --site-dir <dir>."

  let hints =
        defaultHints
          { addrFlags = [AI_NUMERICHOST, AI_NUMERICSERV]
          , addrSocketType = Stream
          }
  addrs <- getAddrInfo (Just hints) (Just (soHost opts)) (Just (show (soPort opts)))
  addr <- case addrs of
    (a : _) -> pure a
    [] -> die ("Could not resolve bind address " ++ soHost opts ++ ":" ++ show (soPort opts))

  bracket (openListenSocket addr) close $ \srvSock -> do
    actualPort <- socketPort srvSock
    putStrLn
      ( "Serving rules_haskell docs from "
          ++ siteDir
          ++ " at http://"
          ++ soHost opts
          ++ ":"
          ++ show actualPort
          ++ "/ (Ctrl+C to stop)"
      )
    forever $ do
      (conn, _peer) <- accept srvSock
      void $ forkFinally (handleClient siteDir conn) (\_ -> close conn)

openListenSocket :: AddrInfo -> IO Socket
openListenSocket addr = do
  sock <- openSocket addr
  setSocketOption sock ReuseAddr 1
  bind sock (addrAddress addr)
  listen sock 128
  pure sock

handleClient :: FilePath -> Socket -> IO ()
handleClient siteDir conn = do
  reqE <- try (readRequestHeaders conn BS.empty) :: IO (Either SomeException ByteString)
  case reqE of
    Left _ -> pure ()
    Right reqBytes
      | BS.null reqBytes -> pure ()
      | otherwise ->
          case parseRequestLine reqBytes of
            Nothing ->
              sendResponse conn "400 Bad Request" "text/plain; charset=utf-8" True "Bad Request\n"
            Just (method, rawTarget)
              | method /= "GET" && method /= "HEAD" ->
                  sendResponse conn "405 Method Not Allowed" "text/plain; charset=utf-8" True "Method Not Allowed\n"
              | otherwise -> do
                  let isHead = method == "HEAD"
                      cleanPath = sanitizeUrlPath (percentDecode (stripQueryAndFragment rawTarget))
                  serveStaticPath siteDir conn isHead cleanPath

readRequestHeaders :: Socket -> ByteString -> IO ByteString
readRequestHeaders conn acc
  | "\r\n\r\n" `BS.isInfixOf` acc || "\n\n" `BS.isInfixOf` acc || BS.length acc > 16384 =
      pure acc
  | otherwise = do
      chunk <- recv conn 4096
      if BS.null chunk
        then pure acc
        else readRequestHeaders conn (acc <> chunk)

parseRequestLine :: ByteString -> Maybe (ByteString, String)
parseRequestLine raw =
  case BS8.lines raw of
    [] -> Nothing
    (firstLine : _) ->
      let stripped = BS8.takeWhile (/= '\r') firstLine
       in case BS8.words stripped of
            (method : target : _) -> Just (method, BS8.unpack target)
            _ -> Nothing

stripQueryAndFragment :: String -> String
stripQueryAndFragment = takeWhile (\c -> c /= '?' && c /= '#')

percentDecode :: String -> String
percentDecode [] = []
percentDecode ('%' : h1 : h2 : rest)
  | isHexDigit h1 && isHexDigit h2 =
      toEnum (digitToInt h1 * 16 + digitToInt h2) : percentDecode rest
percentDecode (c : rest) = c : percentDecode rest

-- | Reject @..@ traversal segments and return clean relative segments.
sanitizeUrlPath :: String -> Maybe [String]
sanitizeUrlPath raw =
  let segs = filter (\s -> not (null s) && s /= "/" && s /= ".") (splitDirectories raw)
   in if any (\s -> s == ".." || elem '\0' s) segs
        then Nothing
        else Just segs

serveStaticPath :: FilePath -> Socket -> Bool -> Maybe [String] -> IO ()
serveStaticPath _ conn _ Nothing =
  sendResponse conn "400 Bad Request" "text/plain; charset=utf-8" False "Invalid URL path\n"
serveStaticPath siteDir conn isHead (Just segs) = do
  let relCandidate = foldl (</>) siteDir segs
  isDir <- doesDirectoryExist relCandidate
  let targetPath = if isDir then relCandidate </> "index.html" else relCandidate
  exists <- doesFileExist targetPath
  if exists
    then do
      body <- if isHead then pure BS.empty else BS.readFile targetPath
      lenBytes <- if isHead then BS.length <$> BS.readFile targetPath else pure (BS.length body)
      sendResponseWithLen conn "200 OK" (mimeTypeFor targetPath) isHead lenBytes body
    else do
      -- Helpful fallback when viewing single-page isolated build at `/`
      fallbackEngine <-
        if null segs
          then doesFileExist (siteDir </> "internals" </> "docs-engine.html")
          else pure False
      if fallbackEngine
        then sendRedirect conn "/internals/docs-engine.html"
        else sendResponse conn "404 Not Found" "text/plain; charset=utf-8" isHead "404 Not Found\n"

sendRedirect :: Socket -> ByteString -> IO ()
sendRedirect conn loc = do
  let hdrs =
        BS.concat
          [ "HTTP/1.1 302 Found\r\n"
          , "Location: " <> loc <> "\r\n"
          , "Content-Length: 0\r\n"
          , "Connection: close\r\n\r\n"
          ]
  sendAll conn hdrs

sendResponse :: Socket -> ByteString -> ByteString -> Bool -> ByteString -> IO ()
sendResponse conn status contentType isHead body =
  sendResponseWithLen conn status contentType isHead (BS.length body) body

sendResponseWithLen :: Socket -> ByteString -> ByteString -> Bool -> Int -> ByteString -> IO ()
sendResponseWithLen conn status contentType isHead lenBytes body = do
  let hdrs =
        BS.concat
          [ "HTTP/1.1 " <> status <> "\r\n"
          , "Content-Type: " <> contentType <> "\r\n"
          , "Content-Length: " <> BS8.pack (show lenBytes) <> "\r\n"
          , "Cache-Control: no-cache\r\n"
          , "Connection: close\r\n\r\n"
          ]
  sendAll conn (if isHead then hdrs else hdrs <> body)

mimeTypeFor :: FilePath -> ByteString
mimeTypeFor path =
  case map toLower (takeExtension path) of
    ".html" -> "text/html; charset=utf-8"
    ".css" -> "text/css; charset=utf-8"
    ".js" -> "application/javascript; charset=utf-8"
    ".json" -> "application/json; charset=utf-8"
    ".svg" -> "image/svg+xml"
    ".png" -> "image/png"
    ".ico" -> "image/x-icon"
    ".txt" -> "text/plain; charset=utf-8"
    _ -> "application/octet-stream"
