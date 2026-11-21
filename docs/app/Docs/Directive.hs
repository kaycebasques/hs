{-# LANGUAGE OverloadedStrings #-}

-- | Sphinx-inspired admonition directives and GitHub blockquote alert transforms
-- over the Pandoc AST.
--
-- Supports both:
--
--   1. Pandoc fenced divs: @::: {.note title="Custom Title"} ... :::@
--      for classes @note@, @tip@, @important@, @warning@, @caution@.
--   2. GitHub-style blockquote alerts: @> [!NOTE]@, @> [!TIP]@,
--      @> [!IMPORTANT]@, @> [!WARNING]@, @> [!CAUTION]@.
--
-- Inner blocks remain real Pandoc AST 'Block' nodes so cross-reference roles,
-- link rewriting, syntax highlighting, and search indexing traverse inside
-- admonitions without loss.
module Docs.Directive
  ( AdmonitionKind (..)
  , admonitionSlug
  , defaultAdmonitionTitle
  , parseAdmonitionClass
  , transformDirectives
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Docs.Nav (escapeHtml)
import Text.Pandoc.Definition
import Text.Pandoc.Shared (stringify)
import Text.Pandoc.Walk (walk)

data AdmonitionKind
  = AdmNote
  | AdmTip
  | AdmImportant
  | AdmWarning
  | AdmCaution
  deriving (Eq, Ord, Show, Bounded, Enum)

admonitionSlug :: AdmonitionKind -> Text
admonitionSlug AdmNote = "note"
admonitionSlug AdmTip = "tip"
admonitionSlug AdmImportant = "important"
admonitionSlug AdmWarning = "warning"
admonitionSlug AdmCaution = "caution"

defaultAdmonitionTitle :: AdmonitionKind -> Text
defaultAdmonitionTitle AdmNote = "Note"
defaultAdmonitionTitle AdmTip = "Tip"
defaultAdmonitionTitle AdmImportant = "Important"
defaultAdmonitionTitle AdmWarning = "Warning"
defaultAdmonitionTitle AdmCaution = "Caution"

parseAdmonitionClass :: Text -> Maybe AdmonitionKind
parseAdmonitionClass raw =
  case T.toLower (T.strip raw) of
    "note" -> Just AdmNote
    "tip" -> Just AdmTip
    "important" -> Just AdmImportant
    "warning" -> Just AdmWarning
    "caution" -> Just AdmCaution
    _ -> Nothing

parseGithubAlertMarker :: Text -> Maybe AdmonitionKind
parseGithubAlertMarker raw =
  case T.toUpper (T.strip raw) of
    "[!NOTE]" -> Just AdmNote
    "[!TIP]" -> Just AdmTip
    "[!IMPORTANT]" -> Just AdmImportant
    "[!WARNING]" -> Just AdmWarning
    "[!CAUTION]" -> Just AdmCaution
    _ -> Nothing

-- | Transform Pandoc fenced-div admonitions and GitHub blockquote alerts into
-- semantic @<aside class="admonition admonition-<kind>">@ blocks.
transformDirectives :: Pandoc -> Pandoc
transformDirectives = walk (concatMap stepBlock)

stepBlock :: Block -> [Block]
stepBlock (Div (ident, classes, kvs) innerBlocks)
  | Just kind <- firstMatchingClass classes =
      let customTitle = lookup "title" kvs >>= nonEmptyText
          titleTxt = fromMaybe (defaultAdmonitionTitle kind) customTitle
       in renderAdmonitionBlocks ident kind titleTxt innerBlocks
stepBlock (BlockQuote blocks)
  | Just (kind, titleTxt, bodyBlocks) <- extractGithubAlert blocks =
      renderAdmonitionBlocks "" kind titleTxt bodyBlocks
stepBlock other = [other]

firstMatchingClass :: [Text] -> Maybe AdmonitionKind
firstMatchingClass [] = Nothing
firstMatchingClass (c : cs) =
  case parseAdmonitionClass c of
    Just k -> Just k
    Nothing -> firstMatchingClass cs

nonEmptyText :: Text -> Maybe Text
nonEmptyText t =
  let s = T.strip t
   in if T.null s then Nothing else Just s

renderAdmonitionBlocks :: Text -> AdmonitionKind -> Text -> [Block] -> [Block]
renderAdmonitionBlocks ident kind titleTxt bodyBlocks =
  let slug = admonitionSlug kind
      idAttr =
        if T.null (T.strip ident)
          then ""
          else " id=\"" <> escapeHtml (T.strip ident) <> "\""
      openHtml =
        T.concat
          [ "<aside"
          , idAttr
          , " class=\"admonition admonition-"
          , slug
          , "\" role=\"note\">"
          , "<div class=\"admonition-title\">"
          , escapeHtml titleTxt
          , "</div>"
          , "<div class=\"admonition-body\">"
          ]
      closeHtml = "</div></aside>"
   in [RawBlock (Format "html") openHtml]
        ++ bodyBlocks
        ++ [RawBlock (Format "html") closeHtml]

-- | Detect Pandoc's native @Div ("", ["note"], ...)@ (when @+alerts@ is active)
-- as well as @BlockQuote@ starting with @[!NOTE]@ / @[!TIP]@ / etc.
extractGithubAlert :: [Block] -> Maybe (AdmonitionKind, Text, [Block])
extractGithubAlert [] = Nothing
extractGithubAlert (firstBlk : restBlocks) =
  case blockInlines firstBlk of
    Nothing -> Nothing
    Just inls ->
      let (line1, afterBreak) = splitAtLineBreak inls
       in case stripAlertPrefix line1 of
            Nothing -> Nothing
            Just (kind, remainderOnLine1) ->
              let trimmedRem = trimLeadingSpace remainderOnLine1
                  trimmedAfter = trimLeadingSpace afterBreak
               in case (null trimmedRem, null trimmedAfter, null restBlocks) of
                    -- `> [!NOTE]\n> Body...` or `> [!NOTE]\n>\n> Body...`
                    (True, False, _) ->
                      Just (kind, defaultAdmonitionTitle kind, Para trimmedAfter : restBlocks)
                    (True, True, _) ->
                      Just (kind, defaultAdmonitionTitle kind, restBlocks)
                    -- Single-line alert `> [!NOTE] Body on same line.`
                    (False, True, True) ->
                      Just (kind, defaultAdmonitionTitle kind, [Para trimmedRem])
                    -- `> [!NOTE] Custom Title\n> Body...`
                    (False, False, _) ->
                      let customTitle = T.strip (stringify trimmedRem)
                          effTitle = if T.null customTitle then defaultAdmonitionTitle kind else customTitle
                       in Just (kind, effTitle, Para trimmedAfter : restBlocks)
                    -- `> [!NOTE] First paragraph...\n>\n> Second paragraph...`
                    (False, True, False) ->
                      Just (kind, defaultAdmonitionTitle kind, Para trimmedRem : restBlocks)

blockInlines :: Block -> Maybe [Inline]
blockInlines (Para xs) = Just xs
blockInlines (Plain xs) = Just xs
blockInlines _ = Nothing

splitAtLineBreak :: [Inline] -> ([Inline], [Inline])
splitAtLineBreak [] = ([], [])
splitAtLineBreak (SoftBreak : xs) = ([], xs)
splitAtLineBreak (LineBreak : xs) = ([], xs)
splitAtLineBreak (x : xs) =
  let (before, after) = splitAtLineBreak xs
   in (x : before, after)

trimLeadingSpace :: [Inline] -> [Inline]
trimLeadingSpace (Space : xs) = trimLeadingSpace xs
trimLeadingSpace (SoftBreak : xs) = trimLeadingSpace xs
trimLeadingSpace xs = xs

stripAlertPrefix :: [Inline] -> Maybe (AdmonitionKind, [Inline])
stripAlertPrefix (Str tok : rest)
  | Just k <- parseGithubAlertMarker tok = Just (k, rest)
  -- Handle `[!NOTE]` attached to punctuation or split across Str tokens by Pandoc
  | Just (k, suffix) <- matchAlertPrefixStr tok =
      let rest' = if T.null suffix then rest else Str suffix : rest
       in Just (k, rest')
stripAlertPrefix (Str "[" : Str bangWord : Str "]" : rest)
  | Just k <- parseGithubAlertMarker ("[" <> bangWord <> "]") = Just (k, rest)
stripAlertPrefix _ = Nothing

matchAlertPrefixStr :: Text -> Maybe (AdmonitionKind, Text)
matchAlertPrefixStr txt =
  let upper = T.toUpper txt
      candidates =
        [ ("[!NOTE]", AdmNote)
        , ("[!TIP]", AdmTip)
        , ("[!IMPORTANT]", AdmImportant)
        , ("[!WARNING]", AdmWarning)
        , ("[!CAUTION]", AdmCaution)
        ]
   in foldr
        ( \(pfx, k) acc ->
            if pfx `T.isPrefixOf` upper
              then Just (k, T.drop (T.length pfx) txt)
              else acc
        )
        Nothing
        candidates
