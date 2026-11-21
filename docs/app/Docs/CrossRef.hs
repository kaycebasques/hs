{-# LANGUAGE OverloadedStrings #-}

-- | Sphinx-inspired cross-reference roles and relative @.md@ -> @.html@ link
-- rewriting over the Pandoc AST.
--
-- Supported inline code roles:
--
--   * @`bzl:rule:<name>`@ -> @/reference/rules.html#<name>@
--   * @`bzl:ext:<name>`@ -> @/reference/extensions-and-providers.html#<slug>@
--   * @`bzl:provider:<name>`@ -> @/reference/extensions-and-providers.html#<lowercase>@
--   * @`cli:lock`@ -> @/reference/lock-cli.html@
--   * @`doc:<route>`@ -> @/<route>.html@ (displaying target page's @nav_title@ / @title@)
module Docs.CrossRef
  ( resolveCrossRefs
  , rewriteMdHref
  , resolveRoleInline
  , resolveRoleCode
  , formatRouteFallbackTitle
  ) where

import Data.Char (toLower, toUpper)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Docs.Nav (escapeHtml)
import Docs.Types
import Text.Pandoc.Definition
import Text.Pandoc.Walk (walk)

-- | Rewrite both inline cross-reference roles and internal @.md@ links across a Pandoc AST.
--
-- Emits native Pandoc 'Link' nodes (rather than 'RawInline' HTML) so downstream
-- 'Text.Pandoc.Shared.stringify' passes in 'Docs.Toc' and 'Docs.Search' preserve
-- cross-reference labels in right-sidebar TOC headings and @search-index.json@ bodies,
-- while Pandoc's HTML5 writer and Hakyll's 'relativizeUrls' still render and relativize
-- @<a class="xref ..." href="...">@.
resolveCrossRefs :: Map Text PageMeta -> Pandoc -> Pandoc
resolveCrossRefs pageMap = walk stepInline
  where
    stepInline :: Inline -> Inline
    stepInline (Code (ident, classes, kvs) codeTxt)
      | null classes
      , null kvs
      , T.null ident
      , Just linkInline <- resolveRoleInline pageMap codeTxt =
          linkInline
    stepInline (Link attr label (url, title)) =
      Link attr (stripNestedLinks label) (rewriteMdHref url, title)
    stepInline other = other

    stripNestedLinks :: [Inline] -> [Inline]
    stripNestedLinks = concatMap unwrapLink
      where
        unwrapLink (Link _ inner _) = inner
        unwrapLink x = [x]

-- | Resolve a single inline role string (e.g. @"bzl:rule:hs_library"@) into a native Pandoc 'Link' 'Inline'.
-- Metasyntax placeholders containing wildcards or brackets (e.g. @"bzl:rule:<name>"@, @"bzl:rule:*"@)
-- return 'Nothing' so documentation prose explaining role syntax stays literal @<code>@.
resolveRoleInline :: Map Text PageMeta -> Text -> Maybe Inline
resolveRoleInline pageMap raw =
  let trimmed = T.strip raw
   in case () of
        _
          | Just ruleName <- T.stripPrefix "bzl:rule:" trimmed
          , isConcreteTarget ruleName ->
              let r = T.strip ruleName
                  href = "/reference/rules.html#" <> r
               in Just (codeXrefInline "xref-rule" href r)
          | Just extName <- T.stripPrefix "bzl:ext:" trimmed
          , isConcreteTarget extName ->
              let e = T.strip extName
                  slug = T.map (\c -> if c == '.' then '-' else toLower c) e
                  href = "/reference/extensions-and-providers.html#" <> slug
               in Just (codeXrefInline "xref-ext" href e)
          | Just provName <- T.stripPrefix "bzl:provider:" trimmed
          , isConcreteTarget provName ->
              let p = T.strip provName
                  slug = T.map toLower p
                  href = "/reference/extensions-and-providers.html#" <> slug
               in Just (codeXrefInline "xref-provider" href p)
          | trimmed == "cli:lock" ->
              Just (codeXrefInline "xref-cli" "/reference/lock-cli.html" "//tools/lock:lock")
          | Just cliSub <- T.stripPrefix "cli:lock:" trimmed
          , isConcreteTarget cliSub ->
              let s = T.strip cliSub
               in Just (codeXrefInline "xref-cli" "/reference/lock-cli.html#flags" s)
          | Just docRouteRaw <- T.stripPrefix "doc:" trimmed
          , isConcreteTarget docRouteRaw ->
              let (routePart0, fragPart) = T.breakOn "#" (T.strip docRouteRaw)
                  routeClean = normalizeDocRoute routePart0
                  href = "/" <> routeClean <> ".html" <> fragPart
                  labelTxt =
                    case Map.lookup routeClean pageMap of
                      Just pm -> pmNavTitle pm
                      Nothing -> formatRouteFallbackTitle routeClean
               in Just (docXrefInline href labelTxt)
          | otherwise -> Nothing

codeXrefInline :: Text -> Text -> Text -> Inline
codeXrefInline subCls href codeLabel =
  Link ("", ["xref", subCls], []) [Code ("", [], []) codeLabel] (href, "")

docXrefInline :: Text -> Text -> Inline
docXrefInline href labelTxt =
  Link ("", ["xref", "xref-doc"], []) [Str labelTxt] (href, "")

-- | Resolve a single inline role string into its HTML @<a class="xref ...">@ representation.
resolveRoleCode :: Map Text PageMeta -> Text -> Maybe Text
resolveRoleCode pageMap raw =
  case resolveRoleInline pageMap raw of
    Just (Link (_, ["xref", "xref-doc"], _) [Str labelTxt] (href, _)) ->
      Just (renderDocXref href labelTxt)
    Just (Link (_, ["xref", subCls], _) [Code _ codeLabel] (href, _)) ->
      Just (renderCodeXref subCls href codeLabel)
    _ -> Nothing

isConcreteTarget :: Text -> Bool
isConcreteTarget rawTarget =
  let s = T.strip rawTarget
   in not (T.null s)
        && not (T.any (\c -> c `elem` ['*', '<', '>', '{', '}', ' ', '\t']) s)

normalizeDocRoute :: Text -> Text
normalizeDocRoute r0 =
  let r1 = T.dropWhile (== '/') (T.strip r0)
      r2 =
        case T.stripSuffix ".md" r1 of
          Just x -> x
          Nothing ->
            case T.stripSuffix ".html" r1 of
              Just y -> y
              Nothing -> r1
   in if T.null r2 then "index" else r2

-- | Human-readable fallback label when compiling a subset of pages in isolation.
formatRouteFallbackTitle :: Text -> Text
formatRouteFallbackTitle route =
  let leaf = lastNonEmpty (T.splitOn "/" route)
      wordsList = filter (not . T.null) (T.splitOn "-" leaf)
   in if null wordsList
        then route
        else T.unwords (map capitalizeWord wordsList)
  where
    lastNonEmpty [] = route
    lastNonEmpty xs = last xs
    capitalizeWord w =
      case T.uncons w of
        Nothing -> ""
        Just (c, rest)
          | w `elem` ["th", "rts", "ffi", "cli", "os", "ci"] -> T.map toUpper w
          | w == "and" -> "&"
          | otherwise -> T.cons (toUpper c) rest

renderCodeXref :: Text -> Text -> Text -> Text
renderCodeXref subCls href codeLabel =
  T.concat
    [ "<a class=\"xref "
    , escapeHtml subCls
    , "\" href=\""
    , escapeHtml href
    , "\"><code>"
    , escapeHtml codeLabel
    , "</code></a>"
    ]

renderDocXref :: Text -> Text -> Text
renderDocXref href labelTxt =
  T.concat
    [ "<a class=\"xref xref-doc\" href=\""
    , escapeHtml href
    , "\">"
    , escapeHtml labelTxt
    , "</a>"
    ]

-- | Rewrite relative internal @.md@ and @.md#fragment@ links to @.html@ and @.html#fragment@,
-- leaving external @http://@, @https://@, @mailto:@, pure @#anchor@, and non-@/md@ links untouched.
rewriteMdHref :: Text -> Text
rewriteMdHref url
  | isExternalUrl url = url
  | "#" `T.isPrefixOf` url = url
  | otherwise =
      let (pathPart, fragPart) = T.breakOn "#" url
          (cleanPath, queryPart) = T.breakOn "?" pathPart
       in case T.stripSuffix ".md" cleanPath of
            Just stem | not (T.null stem) -> stem <> ".html" <> queryPart <> fragPart
            _ -> url

isExternalUrl :: Text -> Bool
isExternalUrl u =
  let low = T.toLower (T.strip u)
   in any
        (`T.isPrefixOf` low)
        [ "http://"
        , "https://"
        , "mailto:"
        , "tel:"
        , "javascript:"
        , "data:"
        , "//"
        ]
