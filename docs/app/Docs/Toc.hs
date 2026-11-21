{-# LANGUAGE OverloadedStrings #-}

-- | Syntax highlighting normalization, Mermaid diagram blocks, heading anchor
-- permalinks, leading duplicate-H1 stripping, and right-sidebar TOC generation.
module Docs.Toc
  ( stripDuplicateLeadingH1
  , prepareCodeAndMermaid
  , enrichHeadingsAndExtractToc
  , renderTocHtml
  , skylightingCss
  ) where

import Control.Monad.State.Strict (State, evalState, get, put)
import Data.Char (isAlphaNum, toLower)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Docs.Nav (escapeHtml)
import Docs.Types
import Skylighting (Style, breezeDark, kate, styleToCss)
import Text.Pandoc.Definition
import Text.Pandoc.Shared (stringify)
import Text.Pandoc.Walk (walk, walkM)

-- | Strip a leading level-1 heading (@# Page Title@) in the Markdown body if its
-- normalized plain text duplicates the frontmatter @title@.
stripDuplicateLeadingH1 :: Text -> Pandoc -> Pandoc
stripDuplicateLeadingH1 pageTitle (Pandoc meta blocks) =
  case blocks of
    (Header 1 _ inls : rest)
      | normalizeHeadingText (stringify inls) == normalizeHeadingText pageTitle ->
          Pandoc meta rest
    _ -> Pandoc meta blocks
  where
    normalizeHeadingText =
      T.toLower . T.unwords . T.words . T.filter (/= '`')

-- | Normalize code blocks prior to Pandoc HTML rendering:
--
--   1. Convert @```mermaid@ fenced blocks into @<pre class="mermaid">...</pre>@
--      so Mermaid diagrams render client-side and stay readable offline.
--   2. Map @starlark@ / @bzl@ / @bazel@ classes to @python@ (adding a @language-starlark@
--      marker class) so Skylighting highlights Starlark syntax richly.
--   3. Map @ini@ / @bazelrc@ classes cleanly for @.bazelrc@ snippets.
prepareCodeAndMermaid :: Pandoc -> Pandoc
prepareCodeAndMermaid = walk stepBlock
  where
    stepBlock :: Block -> Block
    stepBlock (CodeBlock (_ident, classes, _kvs) codeTxt)
      | any (\c -> T.toLower c == "mermaid") classes =
          RawBlock
            (Format "html")
            ("<div class=\"mermaid-container\"><pre class=\"mermaid\">" <> escapeHtml codeTxt <> "</pre></div>")
    stepBlock (CodeBlock (ident, classes, kvs) codeTxt) =
      CodeBlock (ident, rewriteCodeClasses classes, kvs) codeTxt
    stepBlock other = other

    rewriteCodeClasses :: [Text] -> [Text]
    rewriteCodeClasses [] = []
    rewriteCodeClasses (c : cs) =
      case T.toLower c of
        "starlark" -> "python" : "language-starlark" : cs
        "bzl" -> "python" : "language-starlark" : cs
        "bazel" -> "python" : "language-starlark" : cs
        "bazelrc" -> "ini" : "language-bazelrc" : cs
        _ -> c : cs

-- | Assign deterministic unique IDs to all headings, append `#` permalink
-- anchors to H2/H3/H4 headings, and extract H2/H3 TOC entries for the right sidebar.
enrichHeadingsAndExtractToc :: Pandoc -> (Pandoc, [TocEntry])
enrichHeadingsAndExtractToc doc =
  let (doc', revToc) = evalState (runDoc doc) (Set.empty, [])
   in (doc', reverse revToc)
  where
    runDoc :: Pandoc -> State (Set.Set Text, [TocEntry]) (Pandoc, [TocEntry])
    runDoc p = do
      p' <- walkM stepHeader p
      (_, tocRev) <- get
      pure (p', tocRev)

    stepHeader :: Block -> State (Set.Set Text, [TocEntry]) Block
    stepHeader (Header lvl (existingId, classes, kvs) inls) = do
      (usedIds, tocAcc) <- get
      let plainTxt = T.strip (stringify inls)
          baseId =
            if T.null (T.strip existingId)
              then slugifyHeading plainTxt
              else T.strip existingId
          uniqueId = deduplicateId usedIds baseId
          usedIds' = Set.insert uniqueId usedIds
          tocAcc' =
            if lvl == 2 || lvl == 3
              then TocEntry lvl uniqueId plainTxt : tocAcc
              else tocAcc
      put (usedIds', tocAcc')
      let inls' =
            if lvl >= 2 && lvl <= 4
              then
                inls
                  ++ [ RawInline
                         (Format "html")
                         ( " <a class=\"heading-anchor\" href=\"#"
                             <> escapeHtml uniqueId
                             <> "\" aria-label=\"Permalink to this section\">#</a>"
                         )
                     ]
              else inls
      pure (Header lvl (uniqueId, classes, kvs) inls')
    stepHeader other = pure other

slugifyHeading :: Text -> Text
slugifyHeading raw =
  let lowered = T.map toLower raw
      cleaned =
        T.map
          (\c -> if isAlphaNum c || c == '_' || c == '-' then c else '-')
          lowered
      collapsed =
        T.intercalate
          "-"
          (filter (not . T.null) (T.splitOn "-" cleaned))
   in if T.null collapsed then "section" else collapsed

deduplicateId :: Set.Set Text -> Text -> Text
deduplicateId used base
  | base `Set.notMember` used = base
  | otherwise = go (1 :: Int)
  where
    go n =
      let cand = base <> "-" <> T.pack (show n)
       in if cand `Set.notMember` used then cand else go (n + 1)

-- | Render the per-page "On this page" right-sidebar navigation list.
renderTocHtml :: [TocEntry] -> Text
renderTocHtml [] = ""
renderTocHtml entries =
  T.concat
    [ "<div class=\"toc-inner\">"
    , "<div class=\"toc-heading\">On this page</div>"
    , "<ul class=\"toc-list\">"
    , T.concat (map renderItem entries)
    , "</ul>"
    , "</div>"
    ]
  where
    renderItem (TocEntry lvl hid titleTxt) =
      let cls = if lvl == 3 then "toc-item toc-level-3" else "toc-item toc-level-2"
       in T.concat
            [ "<li class=\""
            , cls
            , "\"><a class=\"toc-link\" href=\"#"
            , escapeHtml hid
            , "\">"
            , escapeHtml titleTxt
            , "</a></li>"
            ]

-- | Adaptive light + dark Skylighting syntax-highlighting CSS generated directly
-- from Skylighting's 'kate' and 'breezeDark' styles.
skylightingCss :: Text
skylightingCss =
  let lightCss = T.pack (styleToCss (kate :: Style))
      darkRaw = T.pack (styleToCss (breezeDark :: Style))
      scopeDarkLine line =
        let s = T.strip line
         in if "code span." `T.isPrefixOf` s || "pre > code.sourceCode" `T.isPrefixOf` s || "div.sourceCode" `T.isPrefixOf` s
              then "[data-theme=\"dark\"] " <> s
              else line
      darkScoped = T.unlines (map scopeDarkLine (T.lines darkRaw))
   in T.unlines
        [ "/* Generated hermetically by Skylighting (kate light + breezeDark dark) */"
        , lightCss
        , darkScoped
        ]
