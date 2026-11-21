{-# LANGUAGE OverloadedStrings #-}

-- | Client-side instant-search index extraction and JSON serialization (@search-index.json@).
module Docs.Search
  ( buildSearchDoc
  , extractPlainText
  , encodeSearchIndexJson
  ) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Docs.Types
import Text.Pandoc.Definition
import Text.Pandoc.Shared (stringify)
import Text.Pandoc.Walk (query)

-- | Construct a 'SearchDoc' from a page's metadata, extracted TOC headings, and Pandoc AST.
buildSearchDoc :: PageMeta -> [TocEntry] -> Pandoc -> SearchDoc
buildSearchDoc pm tocEntries doc =
  let relUrl = T.dropWhile (== '/') (pmUrl pm)
      headings = [SearchHeading (teId t) (teTitle t) | t <- tocEntries]
      plain = T.take 12000 (extractPlainText doc)
   in SearchDoc
        { sdTitle = pmTitle pm
        , sdNavTitle = pmNavTitle pm
        , sdSection = sectionLabel (pmSection pm)
        , sdUrl = relUrl
        , sdDescription = pmDescription pm
        , sdHeadings = headings
        , sdBody = plain
        }

-- | Extract normalized searchable plain text from a Pandoc AST (including prose,
-- code blocks, inline code, tables, and admonition bodies, excluding raw HTML tags).
extractPlainText :: Pandoc -> Text
extractPlainText (Pandoc _ blocks) =
  collapseWhitespace (T.intercalate " " (query blockText blocks))
  where
    blockText :: Block -> [Text]
    blockText (Para inls) = [stringify inls]
    blockText (Plain inls) = [stringify inls]
    blockText (Header _ _ inls) = [stringify inls]
    blockText (CodeBlock _ code) = [code]
    blockText _ = []

    collapseWhitespace :: Text -> Text
    collapseWhitespace = T.unwords . T.words

-- | Serialize the ordered list of 'SearchDoc's to UTF-8 JSON bytes.
encodeSearchIndexJson :: [SearchDoc] -> BL.ByteString
encodeSearchIndexJson = encode
