{-# LANGUAGE OverloadedStrings #-}

-- | Comprehensive unit & integration test suite (@//docs:engine_test@) for the
-- @rules_hs@ Hakyll + Pandoc + Skylighting documentation engine.
module Main (main) where

import Data.Aeson (Value, eitherDecode)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Docs.CrossRef (formatRouteFallbackTitle, resolveRoleCode, rewriteMdHref)
import Docs.Nav (renderBreadcrumbsHtml, renderPrevNextHtml, renderSidebarHtml, sortPages)
import Docs.Search (buildSearchDoc, encodeSearchIndexJson, extractPlainText)
import Docs.Site (compileDocsSite, compileMarkdownPagePure, docsReaderOptions, docsWriterOptions)
import Docs.Starlark
  ( BzlAttr (..)
  , BzlExtension (..)
  , BzlField (..)
  , BzlProvider (..)
  , BzlRule (..)
  , BzlTagClass (..)
  , StarlarkBundle (..)
  , emptyStarlarkBundle
  , expandStarlarkAutodoc
  , loadStarlarkBundle
  )
import Docs.Toc (renderTocHtml, skylightingCss)
import Docs.Types
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.Environment (lookupEnv)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Text.Pandoc (readMarkdown, runPure, writeHtml5String)

type TestResult = Either String ()

assertEq :: (Eq a, Show a) => String -> a -> a -> TestResult
assertEq label expected actual
  | expected == actual = Right ()
  | otherwise =
      Left
        ( label
            ++ "\n  expected: "
            ++ show expected
            ++ "\n  actual:   "
            ++ show actual
        )

assertTrue :: String -> Bool -> TestResult
assertTrue _ True = Right ()
assertTrue label False = Left (label ++ " (expected True, got False)")

assertContains :: String -> Text -> Text -> TestResult
assertContains label needle haystack =
  if needle `T.isInfixOf` haystack
    then Right ()
    else
      Left
        ( label
            ++ "\n  expected substring: "
            ++ show needle
            ++ "\n  in output:          "
            ++ show (T.take 400 haystack)
        )

compileSnippet :: Map Text PageMeta -> Text -> Text -> Either String Text
compileSnippet pageMap title md = do
  let pm =
        PageMeta
          { pmRoute = "guide/sample"
          , pmUrl = "/guide/sample.html"
          , pmTitle = title
          , pmNavTitle = "Sample"
          , pmDescription = "Sample page."
          , pmSection = SecGuide
          , pmOrder = 10
          }
  (html, _, _) <- compileMarkdownPagePure emptyStarlarkBundle pageMap pm md
  pure html

-- 1. Pandoc fenced-div admonitions & GitHub-style blockquote alerts
testDirectivesAndAlerts :: TestResult
testDirectivesAndAlerts = do
  let md =
        T.unlines
          [ "::: {.note}"
          , "Default note body with `bzl:rule:hs_library`."
          , ":::"
          , ""
          , "::: {.warning title=\"Hermetic Guard\"}"
          , "Custom warning body."
          , ":::"
          , ""
          , "> [!TIP]"
          , "> GitHub tip body on next line."
          , ""
          , "> [!CAUTION] Danger Zone"
          , "> Caution body text."
          , ""
          , "> [!IMPORTANT]"
          , ">"
          , "> Multi-paragraph important alert."
          ]
  html <- compileSnippet Map.empty "Directives" md
  assertContains "fenced note aside" "<aside class=\"admonition admonition-note\"" html
  assertContains "default Note title" "<div class=\"admonition-title\">Note</div>" html
  assertContains "xref inside admonition" "href=\"/reference/rules.html#hs_library\"" html
  assertContains "custom warning title" "<div class=\"admonition-title\">Hermetic Guard</div>" html
  assertContains "github tip aside" "<aside class=\"admonition admonition-tip\"" html
  assertContains "github tip body" "GitHub tip body on next line." html
  assertContains "github caution custom title" "<div class=\"admonition-title\">Danger Zone</div>" html
  assertContains "github important aside" "<aside class=\"admonition admonition-important\"" html

-- 2. Sphinx-style cross-reference roles & .md link rewriting
testCrossRefRolesAndMdLinks :: TestResult
testCrossRefRolesAndMdLinks = do
  let targetPm =
        PageMeta
          { pmRoute = "internals/hermeticity"
          , pmUrl = "/internals/hermeticity.html"
          , pmTitle = "Nix-Free Hermeticity"
          , pmNavTitle = "Hermeticity & Toolchain"
          , pmDescription = "Deep dive."
          , pmSection = SecInternals
          , pmOrder = 20
          }
      pmap = Map.singleton "internals/hermeticity" targetPm
  assertEq
    "rewrite relative .md"
    "../internals/hermeticity.html"
    (rewriteMdHref "../internals/hermeticity.md")
  assertEq
    "rewrite relative .md#anchor"
    "rules.html#hs_binary"
    (rewriteMdHref "rules.md#hs_binary")
  assertEq
    "preserve external https .md"
    "https://github.com/example/repo/blob/main/README.md"
    (rewriteMdHref "https://github.com/example/repo/blob/main/README.md")
  assertEq
    "preserve pure #fragment"
    "#local-section"
    (rewriteMdHref "#local-section")

  assertContains
    "bzl:rule role"
    "href=\"/reference/rules.html#hs_cabal_library\""
    (maybe "" id (resolveRoleCode pmap "bzl:rule:hs_cabal_library"))
  assertContains
    "bzl:ext dotted tag role"
    "href=\"/reference/extensions-and-providers.html#hackage-from_lock\""
    (maybe "" id (resolveRoleCode pmap "bzl:ext:hackage.from_lock"))
  assertContains
    "bzl:provider role"
    "href=\"/reference/extensions-and-providers.html#hstoolchaininfo\""
    (maybe "" id (resolveRoleCode pmap "bzl:provider:HsToolchainInfo"))
  assertContains
    "cli:lock role"
    "href=\"/reference/lock-cli.html\""
    (maybe "" id (resolveRoleCode pmap "cli:lock"))
  assertContains
    "doc role resolves nav_title from pageMap"
    ">Hermeticity &amp; Toolchain</a>"
    (maybe "" id (resolveRoleCode pmap "doc:internals/hermeticity"))
  assertContains
    "fallback route title formatting"
    "Quickstart"
    (formatRouteFallbackTitle "guide/quickstart")
  assertEq
    "metasyntax wildcard role stays literal Nothing"
    Nothing
    (resolveRoleCode pmap "bzl:rule:*")
  assertEq
    "metasyntax angle-bracket role stays literal Nothing"
    Nothing
    (resolveRoleCode pmap "bzl:rule:<name>")

-- 3. Duplicate H1 stripping, Starlark syntax highlighting, Mermaid, & TOC permalinks
testTocHighlightingAndMermaid :: TestResult
testTocHighlightingAndMermaid = do
  let md =
        T.unlines
          [ "# Architecture Overview"
          , ""
          , "Introductory paragraph."
          , ""
          , "## First Heading"
          , ""
          , "```starlark"
          , "hs_library(name = \"foo\", srcs = [\"Foo.hs\"])"
          , "```"
          , ""
          , "### Sub Heading {#explicit-sub}"
          , ""
          , "### What `cli:lock` Does Under the Hood"
          , ""
          , "Jump straight to `doc:guide/quickstart` to build `bzl:rule:hs_library`."
          , ""
          , "```mermaid"
          , "flowchart LR"
          , "  A --> B"
          , "```"
          ]
      qsMeta =
        PageMeta
          { pmRoute = "guide/quickstart"
          , pmUrl = "/guide/quickstart.html"
          , pmTitle = "Getting Started"
          , pmNavTitle = "Quickstart"
          , pmDescription = "Quickstart guide."
          , pmSection = SecGuide
          , pmOrder = 10
          }
      pm =
        PageMeta
          { pmRoute = "internals/overview"
          , pmUrl = "/internals/overview.html"
          , pmTitle = "Architecture Overview"
          , pmNavTitle = "Architecture Overview"
          , pmDescription = "Overview."
          , pmSection = SecInternals
          , pmOrder = 10
          }
  (html, toc, sdoc) <- compileMarkdownPagePure emptyStarlarkBundle (Map.singleton "guide/quickstart" qsMeta) pm md
  assertTrue "duplicate H1 stripped" (not ("<h1" `T.isInfixOf` html))
  assertEq
    "TOC entries extracted (including resolved cross-ref role label in heading)"
    [ TocEntry 2 "first-heading" "First Heading"
    , TocEntry 3 "explicit-sub" "Sub Heading"
    , TocEntry 3 "what-clilock-does-under-the-hood" "What //tools/lock:lock Does Under the Hood"
    ]
    toc
  assertContains "SearchDoc body retains doc: cross-ref label" "Jump straight to Quickstart to build" (sdBody sdoc)
  assertContains "SearchDoc body retains bzl:rule: cross-ref label" "hs_library" (sdBody sdoc)
  assertContains "SearchDoc body retains cli:lock cross-ref label" "//tools/lock:lock" (sdBody sdoc)
  assertContains "heading permalink anchor" "class=\"heading-anchor\" href=\"#first-heading\"" html
  assertContains "explicit heading id preserved" "id=\"explicit-sub\"" html
  assertContains "Starlark highlighted via Skylighting" "sourceCode python language-starlark" html
  assertContains "Mermaid pre block emitted" "<pre class=\"mermaid\">flowchart LR" html
  assertContains "TOC HTML rendered" "On this page" (renderTocHtml toc)
  assertContains "Skylighting light+dark CSS generated" "[data-theme=\"dark\"]" skylightingCss

  let jsonBytes = encodeSearchIndexJson [sdoc]
  case eitherDecode jsonBytes :: Either String [Value] of
    Left err -> Left ("search-index.json failed JSON decode: " ++ err)
    Right vals -> assertEq "decoded 1 SearchDoc" 1 (length vals)

-- 4. Search index plain-text extraction
testSearchIndexJson :: TestResult
testSearchIndexJson = do
  rawDoc <-
    case runPure (readMarkdown docsReaderOptions ("Prose mentioning `ghc_cc_wrapper` and `HsPackageInfo`.\n\n```haskell\nmain = putStrLn \"ok\"\n```\n" :: Text)) of
      Left e -> Left (show e)
      Right d -> Right d
  let pm =
        PageMeta
          { pmRoute = "internals/hermeticity"
          , pmUrl = "/internals/hermeticity.html"
          , pmTitle = "Hermeticity"
          , pmNavTitle = "Hermeticity"
          , pmDescription = "Zero Nix."
          , pmSection = SecInternals
          , pmOrder = 20
          }
      plain = extractPlainText rawDoc
      sdoc = buildSearchDoc pm [TocEntry 2 "wrapper" "Wrapper"] rawDoc
      encoded = encodeSearchIndexJson [sdoc]
  assertContains "plain text includes inline code" "ghc_cc_wrapper" plain
  assertContains "plain text includes code block" "putStrLn" plain
  case eitherDecode encoded :: Either String [Value] of
    Left err -> Left err
    Right vals -> assertEq "encoded search array length" 1 (length vals)

-- 5. Navigation ordering, breadcrumbs, and Prev/Next cards
testNavigationAndOrdering :: TestResult
testNavigationAndOrdering = do
  let pInternals = PageMeta "internals/a" "/internals/a.html" "Internals A" "Internals A" "" SecInternals 10
      pOverview = PageMeta "index" "/index.html" "rules_hs" "Overview" "" SecOverview 1
      pGuide2 = PageMeta "guide/b" "/guide/b.html" "Guide B" "Guide B" "" SecGuide 20
      pGuide1 = PageMeta "guide/a" "/guide/a.html" "Guide A" "Guide A" "" SecGuide 10
      ordered = sortPages [pInternals, pGuide2, pOverview, pGuide1]
  assertEq
    "canonical section + order sort"
    ["index", "guide/a", "guide/b", "internals/a"]
    (map pmRoute ordered)
  let sidebar = renderSidebarHtml "guide/a" ordered
      crumbs = renderBreadcrumbsHtml pGuide1 ordered
      prevNext = renderPrevNextHtml "guide/a" ordered
  assertContains "active nav class" "class=\"nav-link active\" href=\"/guide/a.html\"" sidebar
  assertContains "breadcrumb root link" "href=\"/index.html\">rules_hs</a>" crumbs
  assertContains "prev card points to Overview" "href=\"/index.html\"" prevNext
  assertContains "next card points to Guide B" "href=\"/guide/b.html\"" prevNext

-- 6. Starlark parser & autodoc introspection against real hs/*.bzl files
testStarlarkIntrospection :: FilePath -> IO TestResult
testStarlarkIntrospection bzlDir = do
  bundle <- loadStarlarkBundle bzlDir
  pure $ do
    assertEq
      "public rules in hs/defs.bzl"
      ["hs_library", "hs_binary", "hs_test", "hs_toolchain_library", "hs_cabal_library"]
      (sbPublicRules bundle)
    hsBin <- maybe (Left "hs_binary missing") Right (Map.lookup "hs_binary" (sbRules bundle))
    let binAttrNames = map baName (brAttrs hsBin)
    assertTrue "hs_binary inherits _EXECUTABLE_ATTRS main_module" ("main_module" `elem` binAttrNames)
    assertTrue "hs_binary inherits _EXECUTABLE_ATTRS threaded" ("threaded" `elem` binAttrNames)

    hsPkg <- maybe (Left "HsPackageInfo missing") Right (Map.lookup "HsPackageInfo" (sbProviders bundle))
    assertTrue "HsPackageInfo has unit_id field" ("unit_id" `elem` map bfName (bpFields hsPkg))

    hackExt <- maybe (Left "hackage extension missing") Right (Map.lookup "hackage" (sbExtensions bundle))
    assertEq "hackage tag classes" ["from_lock", "override"] (map btcName (beTags hackExt))

    rawDoc <-
      case runPure (readMarkdown docsReaderOptions ("::: {.bzl-autodoc source=\"hs/providers.bzl\"}\n:::\n" :: Text)) of
        Left e -> Left (show e)
        Right d -> Right d
    let expanded = expandStarlarkAutodoc bundle rawDoc
    html <-
      case runPure (writeHtml5String docsWriterOptions expanded) of
        Left e -> Left (show e)
        Right h -> Right h
    assertContains "autodoc renders HsPackageInfo" "HsPackageInfo" html
    assertContains "autodoc renders HsLinkInfo" "HsLinkInfo" html
    assertContains "autodoc renders HsToolchainInfo" "HsToolchainInfo" html

writeUtf8File :: FilePath -> Text -> IO ()
writeUtf8File p t = BS.writeFile p (TE.encodeUtf8 t)

-- 7. End-to-end Hakyll multi-page build + strict link/anchor validation (pass & broken rejection)
testFullHakyllAndStrictLinks :: FilePath -> FilePath -> FilePath -> IO TestResult
testFullHakyllAndStrictLinks templatesDir staticDir bzlDir = do
  baseTmp <- getTemporaryDirectory
  (probe, h) <- openTempFile baseTmp "engine_test"
  hClose h
  let work = probe ++ ".work"
      contentOk = work </> "content_ok"
      outOk = work </> "out_ok"
      cacheOk = work </> "cache_ok"
  createDirectoryIfMissing True (contentOk </> "guide")
  createDirectoryIfMissing True (contentOk </> "reference")

  writeUtf8File
    (contentOk </> "index.md")
    ( T.unlines
        [ "---"
        , "title: \"Overview\""
        , "description: \"Home page.\""
        , "section: overview"
        , "nav_title: \"Overview\""
        , "order: 1"
        , "---"
        , ""
        , "Welcome! Start with [Quickstart](guide/quickstart.md#install) or `bzl:rule:hs_library`."
        ]
    )

  writeUtf8File
    (contentOk </> "guide" </> "quickstart.md")
    ( T.unlines
        [ "---"
        , "title: \"Quickstart\""
        , "description: \"Get started.\""
        , "section: guide"
        , "nav_title: \"Quickstart\""
        , "order: 10"
        , "---"
        , ""
        , "## Install {#install}"
        , ""
        , "See `doc:index` and `bzl:rule:hs_binary`."
        ]
    )

  writeUtf8File
    (contentOk </> "reference" </> "rules.md")
    ( T.unlines
        [ "---"
        , "title: \"Rules Reference\""
        , "description: \"All Starlark rules.\""
        , "section: reference"
        , "nav_title: \"Rules Reference\""
        , "order: 10"
        , "---"
        , ""
        , "## `hs_library` {#hs_library}"
        , "## `hs_binary` {#hs_binary}"
        , "## `hs_test` {#hs_test}"
        , "## `hs_toolchain_library` {#hs_toolchain_library}"
        , "## `hs_cabal_library` {#hs_cabal_library}"
        ]
    )

  writeUtf8File
    (contentOk </> "reference" </> "extensions-and-providers.md")
    ( T.unlines
        [ "---"
        , "title: \"Extensions & Providers\""
        , "description: \"Bzlmod extensions and providers.\""
        , "section: reference"
        , "nav_title: \"Extensions & Providers\""
        , "order: 20"
        , "---"
        , ""
        , "## `hs` {#hs}"
        , "### `hs.toolchain` {#hs-toolchain}"
        , "## `hackage` {#hackage}"
        , "### `hackage.from_lock` {#hackage-from_lock}"
        , "### `hackage.override` {#hackage-override}"
        , "## `HsPackageInfo` {#hspackageinfo}"
        , "## `HsLinkInfo` {#hslinkinfo}"
        , "## `HsToolchainInfo` {#hstoolchaininfo}"
        ]
    )

  let cfgOk =
        SiteConfig
          { scContentDir = contentOk
          , scTemplatesDir = templatesDir
          , scStaticDir = staticDir
          , scBzlDir = bzlDir
          , scOutDir = outOk
          , scCacheDir = cacheOk
          , scStrictLinks = True
          }
  resOk <- compileDocsSite cfgOk

  let contentBad = work </> "content_bad"
      outBad = work </> "out_bad"
      cacheBad = work </> "cache_bad"
  createDirectoryIfMissing True contentBad
  writeUtf8File
    (contentBad </> "index.md")
    ( T.unlines
        [ "---"
        , "title: \"Broken Site\""
        , "description: \"Has broken anchor.\""
        , "section: overview"
        , "order: 1"
        , "---"
        , ""
        , "## Existing {#existing}"
        , ""
        , "Broken anchor [here](#nonexistent-anchor) and [missing page](missing.md)."
        ]
    )
  let cfgBad =
        SiteConfig
          { scContentDir = contentBad
          , scTemplatesDir = templatesDir
          , scStaticDir = staticDir
          , scBzlDir = bzlDir
          , scOutDir = outBad
          , scCacheDir = cacheBad
          , scStrictLinks = True
          }
  resBad <- compileDocsSite cfgBad

  hasSearchIdx <- doesFileExist (outOk </> "search-index.json")
  hasSyntaxCss <- doesFileExist (outOk </> "static" </> "syntax.css")
  removeDirectoryRecursive work
  removeFile probe

  pure $ do
    case resOk of
      Left err -> Left ("Valid multi-page strict-links site failed unexpectedly:\n" ++ err)
      Right () -> Right ()
    assertTrue "search-index.json generated" hasSearchIdx
    assertTrue "static/syntax.css generated" hasSyntaxCss
    case resBad of
      Right () -> Left "Expected --strict-links to reject broken anchor and missing page, but it succeeded!"
      Left errMsg -> do
        assertContains "reports nonexistent-anchor" "nonexistent-anchor" (T.pack errMsg)
        assertContains "reports missing.html" "missing.html" (T.pack errMsg)

resolveDataDir :: FilePath -> IO FilePath
resolveDataDir rel = do
  mRunfiles <- lookupEnv "RUNFILES_DIR"
  mTestSrc <- lookupEnv "TEST_SRCDIR"
  let candidates =
        [ r </> "_main" </> rel | Just r <- [mRunfiles, mTestSrc] ]
          ++ [ r </> "rules_hs" </> rel | Just r <- [mRunfiles, mTestSrc] ]
          ++ [rel]
  go candidates
  where
    go [] = pure rel
    go (c : cs) = do
      ok <- doesDirectoryExist c
      if ok then pure c else go cs

main :: IO ()
main = do
  setLocaleEncoding utf8
  bzlDir <- resolveDataDir "hs"
  templatesDir <- resolveDataDir "docs/templates"
  staticDir <- resolveDataDir "docs/static"

  starlarkRes <- testStarlarkIntrospection bzlDir
  hakyllRes <- testFullHakyllAndStrictLinks templatesDir staticDir bzlDir

  let results =
        [ ("directives_and_github_alerts", testDirectivesAndAlerts)
        , ("crossref_roles_and_md_links", testCrossRefRolesAndMdLinks)
        , ("toc_highlighting_and_mermaid", testTocHighlightingAndMermaid)
        , ("search_index_json", testSearchIndexJson)
        , ("navigation_and_ordering", testNavigationAndOrdering)
        , ("starlark_introspection_and_autodoc", starlarkRes)
        , ("hakyll_e2e_and_strict_link_check", hakyllRes)
        ]
      failures = [(n, e) | (n, Left e) <- results]

  mapM_ (\(n, _) -> putStrLn ("PASS: " ++ n)) [(n, ()) | (n, Right ()) <- results]
  mapM_ (\(n, e) -> putStrLn ("FAIL: " ++ n ++ "\n  " ++ e)) failures
  putStrLn ("Ran " ++ show (length results) ++ " test suites, " ++ show (length failures) ++ " failed.")
  if null failures then exitSuccess else exitFailure
