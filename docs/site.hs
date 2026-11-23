{-# LANGUAGE OverloadedStrings #-}

-- | Canonical vanilla Hakyll + Pandoc + Skylighting static site generator
-- for @rules_haskell@ (@//docs:docs_gen@).
module Main (main) where

import Control.Applicative ((<|>))
import Control.Monad (filterM)
import Data.Functor.Identity (runIdentity)
import Data.List (elemIndex, isPrefixOf, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Hakyll
  ( Compiler
  , Configuration (..)
  , Context
  , Identifier
  , Item (..)
  , Rules
  , boolField
  , compile
  , composeRoutes
  , constField
  , copyFileCompiler
  , create
  , defaultConfiguration
  , defaultContext
  , defaultHakyllReaderOptions
  , defaultHakyllWriterOptions
  , field
  , fromFilePath
  , fromGlob
  , getMetadata
  , getRoute
  , getUnderlying
  , gsubRoute
  , hakyllWith
  , hasNoVersion
  , hasVersion
  , idRoute
  , listField
  , listFieldWith
  , loadAll
  , loadAndApplyTemplate
  , loadBody
  , lookupString
  , makeItem
  , match
  , pandocCompilerWithTransform
  , relativizeUrls
  , route
  , setExtension
  , setVersion
  , templateBodyCompiler
  , toFilePath
  , version
  , (.&&.)
  )
import Skylighting (breezeDark, kate, styleToCss)
import System.Environment (lookupEnv)
import System.FilePath (takeFileName, (</>))
import Text.Pandoc
  ( Block (..)
  , Extension (..)
  , Format (..)
  , Inline (..)
  , Pandoc (..)
  , ReaderOptions (..)
  , Template
  , WriterOptions (..)
  , compileTemplate
  , disableExtension
  , enableExtension
  )
import Text.Pandoc.Walk (walk)
import Text.Read (readMaybe)

-- | Ordered sidebar navigation sections matching YAML frontmatter @section:@.
sectionsSpec :: [(String, String)]
sectionsSpec =
  [ ("overview", "Overview")
  , ("guide", "User Guide")
  , ("reference", "API & CLI Reference")
  , ("internals", "Internals & Architecture")
  ]

main :: IO ()
main = do
  setLocaleEncoding utf8
  providerDir <- fromMaybe "docs" <$> lookupEnv "DOCS_PROVIDER_DIR"
  outDir <- fromMaybe "_site" <$> lookupEnv "DOCS_OUT_DIR"
  cacheDir <- fromMaybe "_cache" <$> lookupEnv "DOCS_CACHE_DIR"

  let conf =
        defaultConfiguration
          { providerDirectory = providerDir
          , destinationDirectory = outDir
          , storeDirectory = cacheDir </> "store"
          , tmpDirectory = cacheDir </> "tmp"
          , inMemoryCache = True
          , ignoreFile = \p ->
              let fn = takeFileName p
               in "." `isPrefixOf` fn
                    || "#" `isPrefixOf` fn
                    || lastChar fn == Just '~'
                    || take 4 (reverse fn) == reverse ".swp"
          }

  hakyllWith conf siteRules
  where
    lastChar [] = Nothing
    lastChar xs = Just (last xs)

siteRules :: Rules ()
siteRules = do
  match "templates/*" $ compile templateBodyCompiler

  match "static/**" $ do
    route idRoute
    compile copyFileCompiler

  create ["static/syntax.css"] $ do
    route idRoute
    compile $ makeItem skylightingCss

  -- Lightweight metadata items used by sidebar & prev/next navigation (no route).
  match (fromGlob "content/**.md") $ version "nav" $ do
    compile $ makeItem ("" :: String)

  -- Pandoc's native table-of-contents HTML snapshot per Markdown page.
  match (fromGlob "content/**.md") $ version "toc" $ do
    compile $
      pandocCompilerWithTransform
        docsReaderOptions
        docsTocWriterOptions
        transformMarkdownAst

  -- Main Markdown -> HTML5 compilation pipeline.
  match (fromGlob "content/**.md" .&&. hasNoVersion) $ do
    route $ gsubRoute "content/" (const "") `composeRoutes` setExtension "html"
    compile $ do
      ident <- getUnderlying
      navItems <- loadSortedNavItems
      tocHtml <- loadBody (setVersion (Just "toc") ident)
      pageCtx <- buildPageContext ident navItems tocHtml
      pandocCompilerWithTransform docsReaderOptions docsWriterOptions transformMarkdownAst
        >>= loadAndApplyTemplate (fromFilePath "templates/default.html") pageCtx
        >>= relativizeUrls

-- | Standard Pandoc Markdown reader options for GitHub-flavored technical prose.
docsReaderOptions :: ReaderOptions
docsReaderOptions =
  let exts =
        foldr
          enableExtension
          (disableExtension Ext_implicit_figures (readerExtensions defaultHakyllReaderOptions))
          [ Ext_yaml_metadata_block
          , Ext_fenced_code_blocks
          , Ext_fenced_code_attributes
          , Ext_backtick_code_blocks
          , Ext_header_attributes
          , Ext_auto_identifiers
          , Ext_gfm_auto_identifiers
          , Ext_pipe_tables
          , Ext_raw_html
          , Ext_strikeout
          , Ext_footnotes
          ]
   in defaultHakyllReaderOptions {readerExtensions = exts}

docsWriterOptions :: WriterOptions
docsWriterOptions =
  defaultHakyllWriterOptions
    { writerHighlightStyle = Just kate
    , writerSectionDivs = False
    }

docsTocWriterOptions :: WriterOptions
docsTocWriterOptions =
  docsWriterOptions
    { writerTableOfContents = True
    , writerTOCDepth = 3
    , writerTemplate = Just tocOnlyTemplate
    }

tocOnlyTemplate :: Template Text
tocOnlyTemplate =
  case runIdentity (compileTemplate "" "$toc$") of
    Left err -> error ("Failed to compile Pandoc TOC template: " ++ err)
    Right tpl -> tpl

-- | Minimal AST normalization so authors write 100% standard GitHub Markdown:
--
--   1. Rewrites relative @.md@ / @.md#anchor@ links to @.html@ / @.html#anchor@.
--   2. Maps @starlark@/@bzl@/@bazel@ code fences to @python@ for Skylighting,
--      and emits @<pre class="mermaid">@ for @```mermaid@ blocks.
transformMarkdownAst :: Pandoc -> Pandoc
transformMarkdownAst = walk rewriteInline . walk rewriteBlock . stripLeadingH1
  where
    stripLeadingH1 (Pandoc meta (Header 1 _ _ : rest)) = Pandoc meta rest
    stripLeadingH1 doc = doc
    rewriteInline :: Inline -> Inline
    rewriteInline (Link attr inls (url, title)) =
      Link attr inls (rewriteMdHref url, title)
    rewriteInline other = other

    rewriteBlock :: Block -> Block
    rewriteBlock (CodeBlock (_, classes, _) codeTxt)
      | any (\c -> T.toLower c == "mermaid") classes =
          RawBlock
            (Format "html")
            ("<div class=\"mermaid-container\"><pre class=\"mermaid\">" <> escapeHtml codeTxt <> "</pre></div>")
    rewriteBlock (CodeBlock (ident, classes, kvs) codeTxt) =
      CodeBlock (ident, map mapCodeClass classes, kvs) codeTxt
    rewriteBlock other = other

    mapCodeClass :: Text -> Text
    mapCodeClass c =
      case T.toLower c of
        "starlark" -> "python"
        "bzl" -> "python"
        "bazel" -> "python"
        "bazelrc" -> "ini"
        _ -> c

rewriteMdHref :: Text -> Text
rewriteMdHref href
  | any (`T.isPrefixOf` T.toLower href) ["http://", "https://", "mailto:", "tel:", "data:", "#", "//"] =
      href
  | otherwise =
      let (pathPart, fragPart) = T.breakOn "#" href
       in case T.stripSuffix ".md" pathPart of
            Just stem | not (T.null stem) -> stem <> ".html" <> fragPart
            _ -> href

escapeHtml :: Text -> Text
escapeHtml = T.concatMap esc
  where
    esc '&' = "&amp;"
    esc '<' = "&lt;"
    esc '>' = "&gt;"
    esc '"' = "&quot;"
    esc c = T.singleton c

-- | Load and deterministically sort all @version "nav"@ items by @(section, order, path)@.
loadSortedNavItems :: Compiler [Item String]
loadSortedNavItems = do
  items <- loadAll (fromGlob "content/**.md" .&&. hasVersion "nav")
  keyed <- mapM attachSortKey items
  pure (map snd (sortOn fst keyed))
  where
    sectionRanks = zip (map fst sectionsSpec) [0 :: Int ..]
    attachSortKey it = do
      meta <- getMetadata (itemIdentifier it)
      let sec = fromMaybe "guide" (lookupString "section" meta)
          sRank = fromMaybe 99 (lookup sec sectionRanks)
          ordNum :: Int
          ordNum =
            fromMaybe
              100
              (lookupString "order" meta >>= (fmap round . (readMaybe :: String -> Maybe Double)))
      pure ((sRank, ordNum, toFilePath (itemIdentifier it)), it)

buildPageContext :: Identifier -> [Item String] -> String -> Compiler (Context String)
buildPageContext ident navItems tocHtml = do
  meta <- getMetadata ident
  let activePath = toFilePath ident
      isIndex = activePath == "content/index.md"
      secKey = fromMaybe "guide" (lookupString "section" meta)
      secLabel = fromMaybe "Documentation" (lookup secKey sectionsSpec)
      navTitle =
        fromMaybe
          activePath
          (lookupString "nav_title" meta <|> lookupString "title" meta)
      hasToc = not (all (`elem` (" \t\r\n" :: String)) tocHtml)

  sectionItems <-
    filterM
      (\it -> pure (not (null (snd (itemBody it)))))
      =<< mapM (makeSectionGroup navItems) sectionsSpec

  let mIdx = elemIndex activePath (map (toFilePath . itemIdentifier) navItems)
      prevItem = mIdx >>= (\i -> if i > 0 then Just (navItems !! (i - 1)) else Nothing)
      nextItem = mIdx >>= (\i -> if i + 1 < length navItems then Just (navItems !! (i + 1)) else Nothing)

  prevFields <- neighborFields "prev" prevItem
  nextFields <- neighborFields "next" nextItem

  let tocFields = [constField "toc" tocHtml | hasToc]
      sectionListField =
        listField
          "sections"
          ( field "section_title" (pure . fst . itemBody)
              <> listFieldWith "pages" (navItemContext activePath) (pure . snd . itemBody)
          )
          (pure sectionItems)

  pure $
    mconcat
      ( [ constField "section_label" secLabel
        , constField "nav_title" navTitle
        , boolField "is_index" (const isIndex)
        , sectionListField
        ]
          ++ tocFields
          ++ prevFields
          ++ nextFields
          ++ [defaultContext]
      )
  where
    makeSectionGroup :: [Item String] -> (String, String) -> Compiler (Item (String, [Item String]))
    makeSectionGroup allItems (sKey, sTitle) = do
      matched <-
        filterM
          ( \it -> do
              m <- getMetadata (itemIdentifier it)
              pure (fromMaybe "guide" (lookupString "section" m) == sKey)
          )
          allItems
      makeItem (sTitle, matched)

    neighborFields :: String -> Maybe (Item String) -> Compiler [Context String]
    neighborFields _ Nothing = pure []
    neighborFields prefix (Just it) = do
      mRoute <- getRoute (setVersion Nothing (itemIdentifier it))
      mMeta <- getMetadata (itemIdentifier it)
      let label =
            fromMaybe
              (toFilePath (itemIdentifier it))
              (lookupString "nav_title" mMeta <|> lookupString "title" mMeta)
          secKey = fromMaybe "guide" (lookupString "section" mMeta)
          secLbl = fromMaybe "Documentation" (lookup secKey sectionsSpec)
      case mRoute of
        Nothing -> pure []
        Just r ->
          pure
            [ constField (prefix ++ "_url") ("/" ++ r)
            , constField (prefix ++ "_title") label
            , constField (prefix ++ "_section") secLbl
            ]

navItemContext :: FilePath -> Context String
navItemContext activePath =
  mconcat
    [ boolField "is_active" (\it -> toFilePath (itemIdentifier it) == activePath)
    , field
        "nav_label"
        ( \it -> do
            m <- getMetadata (itemIdentifier it)
            pure $
              fromMaybe
                (toFilePath (itemIdentifier it))
                (lookupString "nav_title" m <|> lookupString "title" m)
        )
    , field
        "url"
        ( \it -> do
            mRoute <- getRoute (setVersion Nothing (itemIdentifier it))
            pure ("/" ++ fromMaybe "" mRoute)
        )
    , defaultContext
    ]

-- | Dual light + dark Skylighting CSS generated from 'kate' and 'breezeDark'.
skylightingCss :: String
skylightingCss =
  let lightCss = styleToCss kate
      darkLines = map scopeDark (lines (styleToCss breezeDark))
      scopeDark line =
        let s = dropWhile (== ' ') line
         in if any (`isPrefixOf` s) ["code span.", "pre > code.sourceCode", "div.sourceCode"]
              then "[data-theme=\"dark\"] " ++ s
              else line
   in unlines
        [ "/* Generated hermetically by Skylighting (kate + breezeDark) */"
        , lightCss
        , unlines darkLines
        ]
