{-# LANGUAGE OverloadedStrings #-}

-- | Purely functional XML sitemap decoding, parsing, and concurrent recursive
-- page counting.
module Sitemap
  ( SitemapDocument (..)
  , CountResult (..)
  , Fetcher
  , defaultMaxConcurrency
  , decodePayload
  , parse
  , countPages
  , countPagesWithConcurrency
  ) where

import Codec.Compression.GZip qualified as GZip
import Codec.Compression.Zlib.Internal qualified as ZlibInternal
import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_, displayException)
import Control.Monad.ST (runST)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as TL
import Text.XML qualified as XML
import Text.XML.Cursor (Cursor, checkElement, ($/))
import Text.XML.Cursor qualified as Cursor

-- | Parsed representation of a sitemap XML document.
data SitemapDocument
  = UrlSet [Text]
  | SitemapIndex [Text]
  deriving (Eq, Show)

-- | Summary produced by recursively crawling a root sitemap URL.
data CountResult = CountResult
  { crRootUrl :: !Text
  , crPageCount :: !Int
  , crSitemapsFetched :: !Int
  }
  deriving (Eq, Show)

-- | Injectable transport effect used by 'countPages' so crawling logic can be
-- tested hermetically without network I/O.
type Fetcher = Text -> IO (Either String ByteString)

-- | Default upper bound on concurrent child sitemap fetches.
defaultMaxConcurrency :: Int
defaultMaxConcurrency = 4

-- | Monoidal accumulator merged across concurrently crawled subtrees.
data CrawlSummary = CrawlSummary
  { csPages :: !(Set Text)
  , csSitemapsFetched :: !Int
  }

instance Semigroup CrawlSummary where
  CrawlSummary p1 n1 <> CrawlSummary p2 n2 =
    CrawlSummary (Set.union p1 p2) (n1 + n2)

instance Monoid CrawlSummary where
  mempty = CrawlSummary Set.empty 0

-- | Decode raw sitemap bytes, transparently gunzipping payloads that start with
-- the gzip magic header (@0x1f 0x8b@), validating UTF-8 strictly, and stripping
-- an optional leading UTF-8 BOM (@U+FEFF@).
decodePayload :: ByteString -> Either String Text
decodePayload raw = do
  unpacked <-
    if isGzipped raw
      then gunzipPayload raw
      else Right raw
  case TE.decodeUtf8' unpacked of
    Left err -> Left ("Invalid UTF-8 sitemap payload: " <> displayException err)
    Right txt -> Right (stripBom txt)

isGzipped :: ByteString -> Bool
isGzipped bs =
  BS.length bs >= 2
    && BS.index bs 0 == 0x1f
    && BS.index bs 1 == 0x8b

gunzipPayload :: ByteString -> Either String ByteString
gunzipPayload raw =
  fmap BS.concat $
    runST $
      ZlibInternal.foldDecompressStreamWithInput
        (\chunk next -> fmap (chunk :) <$> next)
        (\_trailing -> pure (Right []))
        (\err -> pure (Left ("Failed to gunzip payload: " <> displayException err)))
        (ZlibInternal.decompressST ZlibInternal.gzipFormat GZip.defaultDecompressParams)
        (BL.fromStrict raw)

stripBom :: Text -> Text
stripBom txt = fromMaybe txt (T.stripPrefix "\xFEFF" txt)

-- | Parse a decoded XML sitemap document using @xml-conduit@.
--
-- Handles XML namespaces, prefixed sibling elements (e.g. @\<xhtml:link/\>@),
-- comments, XML entities, and case-insensitive @\<urlset\>@ /
-- @\<sitemapindex\>@ root elements.
parse :: Text -> Either String SitemapDocument
parse xml =
  case XML.parseText XML.def (TL.fromStrict xml) of
    Left err -> Left ("Failed to parse XML: " <> displayException err)
    Right doc ->
      let rootElem = XML.documentRoot doc
          rootName = XML.elementName rootElem
          rootLocal = XML.nameLocalName rootName
          rootNs = XML.nameNamespace rootName
          rootCursor = Cursor.fromDocument doc
       in case T.toLower rootLocal of
            "urlset" -> Right (UrlSet (extractLocs rootNs "url" rootCursor))
            "sitemapindex" -> Right (SitemapIndex (extractLocs rootNs "sitemap" rootCursor))
            _ ->
              Left
                ( "Unexpected root element <"
                    <> T.unpack rootLocal
                    <> "> (expected <urlset> or <sitemapindex>)"
                )

extractLocs :: Maybe Text -> Text -> Cursor -> [Text]
extractLocs rootNs entryTag rootCursor =
  [ loc
  | entry <- rootCursor $/ checkElement (matchesTag rootNs entryTag)
  , locElem <- take 1 (entry $/ checkElement (matchesTag rootNs "loc"))
  , let loc = T.strip (T.concat (locElem $/ Cursor.content))
  , not (T.null loc)
  ]

matchesTag :: Maybe Text -> Text -> XML.Element -> Bool
matchesTag rootNs expectedLocal el =
  let nm = XML.elementName el
      ns = XML.nameNamespace nm
   in T.toLower (XML.nameLocalName nm) == expectedLocal
        && (ns == rootNs || isNothing ns)

-- | Recursively crawl a sitemap (or sitemap index) with up to
-- 'defaultMaxConcurrency' concurrent child fetches, avoiding cycles/duplicate
-- sitemap fetches and deduplicating discovered page URLs.
countPages :: Text -> Fetcher -> IO (Either String CountResult)
countPages = countPagesWithConcurrency defaultMaxConcurrency

-- | Variant of 'countPages' allowing a custom concurrency bound.
countPagesWithConcurrency :: Int -> Text -> Fetcher -> IO (Either String CountResult)
countPagesWithConcurrency maxConcurrency rootUrl fetch = do
  visitedVar <- newMVar Set.empty
  sem <- newQSem (max 1 maxConcurrency)
  result <- walk visitedVar sem rootUrl
  pure (toCountResult <$> result)
  where
    toCountResult :: CrawlSummary -> CountResult
    toCountResult summary =
      CountResult
        { crRootUrl = rootUrl
        , crPageCount = Set.size (csPages summary)
        , crSitemapsFetched = csSitemapsFetched summary
        }

    walk :: MVar (Set Text) -> QSem -> Text -> IO (Either String CrawlSummary)
    walk visitedVar sem url = do
      claimed <- claimUrl visitedVar url
      if not claimed
        then pure (Right mempty)
        else do
          -- Release the semaphore before recursing into child sitemaps so deep
          -- sitemap index hierarchies can never deadlock.
          fetched <- bracket_ (waitQSem sem) (signalQSem sem) (fetch url)
          case fetched of
            Left err -> pure (Left err)
            Right rawBytes ->
              case decodePayload rawBytes >>= parse of
                Left err -> pure (Left (T.unpack url <> ": " <> err))
                Right (UrlSet urls) ->
                  pure (Right (CrawlSummary (Set.fromList urls) 1))
                Right (SitemapIndex children) -> do
                  childResults <- mapConcurrently (walk visitedVar sem) children
                  pure $ case sequenceA childResults of
                    Left err -> Left err
                    Right summaries -> Right (CrawlSummary Set.empty 1 <> mconcat summaries)

claimUrl :: MVar (Set Text) -> Text -> IO Bool
claimUrl visitedVar url =
  modifyMVar visitedVar $ \seen ->
    if Set.member url seen
      then pure (seen, False)
      else pure (Set.insert url seen, True)
