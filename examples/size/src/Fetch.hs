{-# LANGUAGE OverloadedStrings #-}

-- | HTTP/HTTPS sitemap fetcher backed by @http-client@ and pure-Haskell TLS
-- (@http-client-tls@ / @tls@ / @crypton@ — zero OpenSSL dependency).
module Fetch
  ( newHttpManager
  , httpFetcher
  ) where

import Control.Exception (displayException, try)
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import Network.HTTP.Client
  ( HttpException
  , Manager
  , httpLbs
  , managerResponseTimeout
  , parseRequest
  , requestHeaders
  , responseBody
  , responseStatus
  , responseTimeoutMicro
  )
import Network.HTTP.Client.TLS (newTlsManagerWith, tlsManagerSettings)
import Network.HTTP.Types.Header (hUserAgent)
import Network.HTTP.Types.Status (statusCode, statusIsSuccessful)
import Sitemap (Fetcher)

-- | Create an HTTP/HTTPS 'Manager' with a 30-second response timeout and
-- pure-Haskell TLS.
newHttpManager :: IO Manager
newHttpManager =
  newTlsManagerWith
    tlsManagerSettings
      { managerResponseTimeout = responseTimeoutMicro (30 * 1000 * 1000)
      }

-- | Build a 'Fetcher' that issues HTTP(S) GET requests with
-- @User-Agent: docs-size-tracker/0.1@, follows redirects automatically, and
-- returns @Left "HTTP <code> fetching <url>"@ on non-2xx responses.
httpFetcher :: Manager -> Fetcher
httpFetcher mgr url = do
  outcome <- try @HttpException $ do
    req0 <- parseRequest (T.unpack url)
    let req =
          req0
            { requestHeaders =
                (hUserAgent, "docs-size-tracker/0.1")
                  : filter ((/= hUserAgent) . fst) (requestHeaders req0)
            }
    httpLbs req mgr
  pure $ case outcome of
    Left ex -> Left ("Request failed for " <> T.unpack url <> ": " <> displayException ex)
    Right resp ->
      let st = responseStatus resp
       in if statusIsSuccessful st
            then Right (BL.toStrict (responseBody resp))
            else Left ("HTTP " <> show (statusCode st) <> " fetching " <> T.unpack url)
