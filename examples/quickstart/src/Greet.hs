{-# LANGUAGE OverloadedStrings #-}

module Greet
  ( greetingFor
  , uniqueSortedTags
  ) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

greetingFor :: Text -> Text
greetingFor who = "Hello, " <> T.strip who <> ", from rules_hs."

uniqueSortedTags :: [Text] -> [Text]
uniqueSortedTags = Set.toAscList . Set.fromList . map T.strip
