{-# LANGUAGE OverloadedStrings #-}

-- | Core domain types for the @rules_hs@ Hakyll + Pandoc documentation engine.
module Docs.Types
  ( SectionId (..)
  , allSections
  , sectionSlug
  , sectionLabel
  , sectionRank
  , parseSection
  , PageMeta (..)
  , SiteConfig (..)
  , TocEntry (..)
  , SearchDoc (..)
  , SearchHeading (..)
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)
import qualified Data.Text as T

-- | Top-level documentation sections in canonical sidebar order.
data SectionId
  = SecOverview
  | SecGuide
  | SecReference
  | SecInternals
  deriving (Eq, Ord, Show, Bounded, Enum)

allSections :: [SectionId]
allSections = [minBound .. maxBound]

sectionSlug :: SectionId -> Text
sectionSlug SecOverview = "overview"
sectionSlug SecGuide = "guide"
sectionSlug SecReference = "reference"
sectionSlug SecInternals = "internals"

sectionLabel :: SectionId -> Text
sectionLabel SecOverview = "Overview"
sectionLabel SecGuide = "User Guide"
sectionLabel SecReference = "API & CLI Reference"
sectionLabel SecInternals = "Internals & Architecture"

sectionRank :: SectionId -> Int
sectionRank SecOverview = 0
sectionRank SecGuide = 1
sectionRank SecReference = 2
sectionRank SecInternals = 3

parseSection :: Text -> Either String SectionId
parseSection raw =
  case T.toLower (T.strip raw) of
    "overview" -> Right SecOverview
    "guide" -> Right SecGuide
    "reference" -> Right SecReference
    "internals" -> Right SecInternals
    other ->
      Left
        ( "Invalid frontmatter section "
            ++ show (T.unpack other)
            ++ " (expected overview | guide | reference | internals)"
        )

-- | Parsed frontmatter and route metadata for one documentation page.
data PageMeta = PageMeta
  { pmRoute :: !Text
  -- ^ Normalized route without leading slash or extension (e.g. @"guide/quickstart"@, @"index"@)
  , pmUrl :: !Text
  -- ^ Root-relative HTML URL before Hakyll relativization (e.g. @"/guide/quickstart.html"@)
  , pmTitle :: !Text
  , pmNavTitle :: !Text
  , pmDescription :: !Text
  , pmSection :: !SectionId
  , pmOrder :: !Int
  }
  deriving (Eq, Show)

-- | Explicit CLI configuration for hermetic Bazel execution.
data SiteConfig = SiteConfig
  { scContentDir :: !FilePath
  , scTemplatesDir :: !FilePath
  , scStaticDir :: !FilePath
  , scBzlDir :: !FilePath
  , scOutDir :: !FilePath
  , scCacheDir :: !FilePath
  , scStrictLinks :: !Bool
  }
  deriving (Eq, Show)

-- | Per-page heading entry for the right-hand "On this page" table of contents.
data TocEntry = TocEntry
  { teLevel :: !Int
  , teId :: !Text
  , teTitle :: !Text
  }
  deriving (Eq, Show)

-- | Anchor heading within a search index document.
data SearchHeading = SearchHeading
  { shId :: !Text
  , shTitle :: !Text
  }
  deriving (Eq, Show)

instance ToJSON SearchHeading where
  toJSON sh =
    object
      [ "id" .= shId sh
      , "title" .= shTitle sh
      ]

-- | Entry serialized into @search-index.json@ for instant client-side search.
data SearchDoc = SearchDoc
  { sdTitle :: !Text
  , sdNavTitle :: !Text
  , sdSection :: !Text
  , sdUrl :: !Text
  -- ^ Site-root-relative path without leading slash (e.g. @"guide/quickstart.html"@)
  , sdDescription :: !Text
  , sdHeadings :: ![SearchHeading]
  , sdBody :: !Text
  }
  deriving (Eq, Show)

instance ToJSON SearchDoc where
  toJSON sd =
    object
      [ "title" .= sdTitle sd
      , "nav_title" .= sdNavTitle sd
      , "section" .= sdSection sd
      , "url" .= sdUrl sd
      , "description" .= sdDescription sd
      , "headings" .= sdHeadings sd
      , "body" .= sdBody sd
      ]
