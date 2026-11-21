{-# LANGUAGE OverloadedStrings #-}

-- | Real Hakyll + Pandoc + Skylighting static site compiler for @rules_hs@.
--
-- Stages inputs into a sandbox-local provider directory so Hakyll's provider/store
-- never mutates Bazel source/execroot inputs and never leaks files into @/tmp@.
module Docs.Site
  ( compileDocsSite
  , compileMarkdownPagePure
  , docsReaderOptions
  , docsWriterOptions
  , parseFrontmatterFile
  ) where

import Control.Monad (forM, forM_, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Yaml (Value (..))
import qualified Data.Yaml as Yaml
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import Docs.CrossRef (resolveCrossRefs)
import Docs.Directive (transformDirectives)
import Docs.LinkCheck (checkSiteLinks, formatLinkError)
import Docs.Nav (renderBreadcrumbsHtml, renderPrevNextHtml, renderSidebarHtml, sortPages)
import Docs.Search (buildSearchDoc, encodeSearchIndexJson)
import Docs.Starlark (StarlarkBundle, expandStarlarkAutodoc, loadStarlarkBundle, verifyStarlarkReferenceCoverage)
import Docs.Toc (enrichHeadingsAndExtractToc, prepareCodeAndMermaid, renderTocHtml, skylightingCss, stripDuplicateLeadingH1)
import Docs.Types
import Hakyll
  ( Configuration (..)
  , Context
  , Rules
  , compile
  , constField
  , copyFileCompiler
  , create
  , customRoute
  , defaultConfiguration
  , defaultContext
  , defaultHakyllReaderOptions
  , defaultHakyllWriterOptions
  , fromFilePath
  , fromGlob
  , getUnderlying
  , idRoute
  , loadAndApplyTemplate
  , makeItem
  , match
  , relativizeUrls
  , route
  , templateBodyCompiler
  , toFilePath
  , unsafeCompiler
  )
import Hakyll.Core.Runtime (RunMode (..))
import Hakyll.Main (Command (..), Options (..), hakyllWithExitCodeAndArgs)
import Skylighting (kate)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , listDirectory
  )
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, takeDirectory, takeExtension, takeFileName, (</>))
import Text.Pandoc
  ( Extension (..)
  , ReaderOptions (..)
  , WriterOptions (..)
  , disableExtension
  , enableExtension
  , readMarkdown
  , runPure
  , writeHtml5String
  )

-- | Pandoc Markdown reader options enabling YAML frontmatter, Pandoc fenced divs,
-- header attributes (@{#custom-id}@), pipe/grid tables, footnotes, strikeout, and Skylighting code attributes.
docsReaderOptions :: ReaderOptions
docsReaderOptions =
  let baseExts = readerExtensions defaultHakyllReaderOptions
      enabled =
        foldr
          enableExtension
          baseExts
          [ Ext_yaml_metadata_block
          , Ext_fenced_divs
          , Ext_fenced_code_blocks
          , Ext_fenced_code_attributes
          , Ext_backtick_code_blocks
          , Ext_inline_code_attributes
          , Ext_header_attributes
          , Ext_auto_identifiers
          , Ext_gfm_auto_identifiers
          , Ext_pipe_tables
          , Ext_raw_html
          , Ext_strikeout
          , Ext_footnotes
          ]
      -- Disable implicit_figures so standalone images don't change block structure unexpectedly
      adjusted = disableExtension Ext_implicit_figures enabled
   in defaultHakyllReaderOptions
        { readerExtensions = adjusted
        }

-- | Pandoc HTML5 writer options configured with Skylighting syntax highlighting.
docsWriterOptions :: WriterOptions
docsWriterOptions =
  defaultHakyllWriterOptions
    { writerHighlightStyle = Just kate
    , writerSectionDivs = False
    }

-- | Pure Pandoc compilation pipeline used both inside Hakyll's 'Compiler' monad
-- and directly in fast unit tests ('//docs:engine_test').
compileMarkdownPagePure
  :: StarlarkBundle
  -> Map Text PageMeta
  -> PageMeta
  -> Text
  -> Either String (Text, [TocEntry], SearchDoc)
compileMarkdownPagePure bzlBundle pageMap pm rawMarkdown = do
  rawDoc <-
    case runPure (readMarkdown docsReaderOptions rawMarkdown) of
      Left err -> Left ("Pandoc Markdown parse error in " ++ T.unpack (pmRoute pm) ++ ": " ++ show err)
      Right d -> Right d
  let doc1 = stripDuplicateLeadingH1 (pmTitle pm) rawDoc
      doc2 = expandStarlarkAutodoc bzlBundle doc1
      doc3 = transformDirectives doc2
      doc4 = resolveCrossRefs pageMap doc3
      doc5 = prepareCodeAndMermaid doc4
      (doc6, tocEntries) = enrichHeadingsAndExtractToc doc5
      searchDoc = buildSearchDoc pm tocEntries doc6
  htmlBody <-
    case runPure (writeHtml5String docsWriterOptions doc6) of
      Left err -> Left ("Pandoc HTML5 writer error in " ++ T.unpack (pmRoute pm) ++ ": " ++ show err)
      Right h -> Right h
  pure (htmlBody, tocEntries, searchDoc)

-- | Parse YAML frontmatter from a Markdown file on disk into a 'PageMeta'.
parseFrontmatterFile :: FilePath -> FilePath -> IO (Either String PageMeta)
parseFrontmatterFile contentRoot absPath = do
  rawBytes <- BS.readFile absPath
  let rawTxt = TE.decodeUtf8Lenient rawBytes
      relPath = toPosixPath (makeRelative contentRoot absPath)
      routeNoExt =
        case T.stripSuffix ".md" (T.pack relPath) of
          Just r -> r
          Nothing -> T.pack relPath
      url = "/" <> routeNoExt <> ".html"
  case extractYamlFrontmatter rawTxt of
    Nothing ->
      pure (Left (relPath ++ ": missing leading `---` YAML frontmatter block"))
    Just yamlTxt ->
      case Yaml.decodeEither' (TE.encodeUtf8 yamlTxt) of
        Left err ->
          pure (Left (relPath ++ ": invalid YAML frontmatter: " ++ Yaml.prettyPrintParseException err))
        Right (Object obj) -> do
          let lookupText k =
                case lookupKey k obj of
                  Just (String s) -> Just (T.strip s)
                  _ -> Nothing
              lookupInt k =
                case lookupKey k obj of
                  Just (Number n) -> Just (round n)
                  _ -> Nothing
          case (lookupText "title", lookupText "section") of
            (Nothing, _) ->
              pure (Left (relPath ++ ": missing required string frontmatter key `title`"))
            (_, Nothing) ->
              pure (Left (relPath ++ ": missing required string frontmatter key `section`"))
            (Just titleTxt, Just secTxt) ->
              case parseSection secTxt of
                Left secErr -> pure (Left (relPath ++ ": " ++ secErr))
                Right sec ->
                  let navTitle = fromMaybe titleTxt (lookupText "nav_title" >>= nonEmpty)
                      desc = fromMaybe "" (lookupText "description")
                      ordVal = fromMaybe 100 (lookupInt "order")
                   in pure $
                        Right
                          PageMeta
                            { pmRoute = routeNoExt
                            , pmUrl = url
                            , pmTitle = titleTxt
                            , pmNavTitle = navTitle
                            , pmDescription = desc
                            , pmSection = sec
                            , pmOrder = ordVal
                            }
        Right _ ->
          pure (Left (relPath ++ ": YAML frontmatter must be a mapping"))
  where
    nonEmpty t = if T.null t then Nothing else Just t
    lookupKey k obj = Yaml.parseMaybe (Yaml..: k) obj

extractYamlFrontmatter :: Text -> Maybe Text
extractYamlFrontmatter txt =
  let ls = T.lines txt
   in case ls of
        (first : rest)
          | T.strip first == "---" ->
              let (yamlLines, after) = break (\l -> T.strip l `elem` ["---", "..."]) rest
               in if null after
                    then Nothing
                    else Just (T.unlines yamlLines)
        _ -> Nothing

toPosixPath :: FilePath -> FilePath
toPosixPath = map (\c -> if c == '\\' then '/' else c)

-- | Discover all @.md@ files recursively under @contentDir@.
discoverMarkdownFiles :: FilePath -> IO [FilePath]
discoverMarkdownFiles rootDir = do
  exists <- doesDirectoryExist rootDir
  if not exists
    then pure []
    else sort <$> go rootDir
  where
    go dir = do
      entries <- sort <$> listDirectory dir
      fmap concat . forM entries $ \e -> do
        let p = dir </> e
        isDir <- doesDirectoryExist p
        if isDir
          then go p
          else
            if takeExtension e == ".md" && not ("." `isPrefixOf` takeFileName e)
              then pure [p]
              else pure []

-- | Copy a directory tree into a clean staging path inside @scCacheDir@.
stageDirectoryTree :: FilePath -> FilePath -> IO ()
stageDirectoryTree srcRoot dstRoot = do
  exists <- doesDirectoryExist srcRoot
  when exists $ do
    createDirectoryIfMissing True dstRoot
    entries <- sort <$> listDirectory srcRoot
    forM_ entries $ \e -> do
      let s = srcRoot </> e
          d = dstRoot </> e
      isDir <- doesDirectoryExist s
      if isDir
        then stageDirectoryTree s d
        else do
          createDirectoryIfMissing True (takeDirectory d)
          copyFile s d

-- | Run the full hermetic Hakyll site compilation, Starlark coverage check,
-- @search-index.json@ emission, and optional strict HTML link + anchor validation.
compileDocsSite :: SiteConfig -> IO (Either String ())
compileDocsSite cfg = do
  setLocaleEncoding utf8
  mdFiles <- discoverMarkdownFiles (scContentDir cfg)
  if null mdFiles
    then pure (Left ("No Markdown files found under --content-dir " ++ scContentDir cfg))
    else do
      metaResults <- mapM (parseFrontmatterFile (scContentDir cfg)) mdFiles
      let metaErrors = [e | Left e <- metaResults]
      if not (null metaErrors)
        then pure (Left (unlines ("Frontmatter validation failed:" : map ("  - " ++) metaErrors)))
        else do
          let pages = sortPages [pm | Right pm <- metaResults]
              pageMap = Map.fromList [(pmRoute pm, pm) | pm <- pages]

          bzlBundle <- loadStarlarkBundle (scBzlDir cfg)

          -- Stage content/, templates/, and static/ into scCacheDir/provider so Hakyll's
          -- providerDirectory sees a clean layout and never mutates input directories.
          let providerDir = scCacheDir cfg </> "provider"
              storeDir = scCacheDir cfg </> "store"
              tmpDir = scCacheDir cfg </> "tmp"
          createDirectoryIfMissing True providerDir
          createDirectoryIfMissing True storeDir
          createDirectoryIfMissing True tmpDir
          createDirectoryIfMissing True (scOutDir cfg)

          stageDirectoryTree (scContentDir cfg) (providerDir </> "content")
          stageDirectoryTree (scTemplatesDir cfg) (providerDir </> "templates")
          stageDirectoryTree (scStaticDir cfg) (providerDir </> "static")

          let hakyllConf =
                defaultConfiguration
                  { destinationDirectory = scOutDir cfg
                  , storeDirectory = storeDir
                  , tmpDirectory = tmpDir
                  , providerDirectory = providerDir
                  , inMemoryCache = True
                  , ignoreFile = \p ->
                      let fn = takeFileName p
                       in "." `isPrefixOf` fn
                            || "#" `isPrefixOf` fn
                            || "~" `isSuffixOf` fn
                            || ".swp" `isSuffixOf` fn
                  }

          searchDocsRef <- newIORef ([] :: [SearchDoc])
          compileErrRef <- newIORef ([] :: [String])

          let rules :: Rules ()
              rules = do
                match "templates/*" $ compile templateBodyCompiler

                match "static/**" $ do
                  route idRoute
                  compile copyFileCompiler

                create ["static/syntax.css"] $ do
                  route idRoute
                  compile $ makeItem (T.unpack skylightingCss)

                match (fromGlob "content/**.md") $ do
                  route $
                    customRoute
                      ( \ident ->
                          let rel = toPosixPath (toFilePath ident)
                              stripped = fromMaybe rel (stripContentPrefix rel)
                           in replaceMdWithHtml stripped
                      )
                  compile $ do
                    ident <- getUnderlying
                    let rel = toPosixPath (toFilePath ident)
                        stripped = fromMaybe rel (stripContentPrefix rel)
                        routeKey =
                          case T.stripSuffix ".md" (T.pack stripped) of
                            Just r -> r
                            Nothing -> T.pack stripped
                    rawMarkdown <- unsafeCompiler (TE.decodeUtf8Lenient <$> BS.readFile (providerDir </> rel))
                    case Map.lookup routeKey pageMap of
                      Nothing -> do
                        unsafeCompiler $ modifyIORef' compileErrRef (++ ["Unknown page route: " ++ T.unpack routeKey])
                        fail ("Unknown page route: " ++ T.unpack routeKey)
                      Just pm ->
                        case compileMarkdownPagePure bzlBundle pageMap pm rawMarkdown of
                          Left err -> do
                            unsafeCompiler $ modifyIORef' compileErrRef (++ [err])
                            fail err
                          Right (bodyHtml, tocEntries, sdoc) -> do
                            unsafeCompiler $ modifyIORef' searchDocsRef (sdoc :)
                            let pageCtx = buildPageContext pm pages tocEntries
                            makeItem (T.unpack bodyHtml)
                              >>= loadAndApplyTemplate (fromFilePath "templates/default.html") pageCtx
                              >>= relativizeUrls

          let hakyllOpts = Options {verbosity = False, optCommand = Build RunModeNormal}
          exitCode <- hakyllWithExitCodeAndArgs hakyllConf hakyllOpts rules
          recordedErrs <- readIORef compileErrRef
          case exitCode of
            ExitFailure n ->
              pure $
                Left $
                  unlines
                    ( ("Hakyll build failed with exit code " ++ show n)
                        : recordedErrs
                    )
            ExitSuccess -> do
              -- Emit deterministic search-index.json sorted matching sidebar page order
              rawSearchDocs <- readIORef searchDocsRef
              let docByUrl = Map.fromList [(sdUrl d, d) | d <- rawSearchDocs]
                  orderedSearchDocs =
                    [ d
                    | pm <- pages
                    , let relU = T.dropWhile (== '/') (pmUrl pm)
                    , Just d <- [Map.lookup relU docByUrl]
                    ]
              BL.writeFile (scOutDir cfg </> "search-index.json") (encodeSearchIndexJson orderedSearchDocs)

              -- Verify public Starlark symbol coverage when reference pages are present
              covErrors <- verifyStarlarkReferenceCoverage bzlBundle (scOutDir cfg)
              if not (null covErrors)
                then pure (Left (unlines ("Starlark reference coverage check failed:" : map ("  - " ++) covErrors)))
                else do
                  if scStrictLinks cfg
                    then do
                      linkErrs <- checkSiteLinks (scOutDir cfg)
                      if null linkErrs
                        then pure (Right ())
                        else
                          pure $
                            Left $
                              unlines
                                ( "Strict link & anchor verification failed:"
                                    : map (("  - " ++) . formatLinkError) linkErrs
                                )
                    else pure (Right ())

stripContentPrefix :: String -> Maybe String
stripContentPrefix s
  | "content/" `isPrefixOf` s = Just (drop (length ("content/" :: String)) s)
  | otherwise = Nothing

replaceMdWithHtml :: String -> String
replaceMdWithHtml p =
  case T.stripSuffix ".md" (T.pack p) of
    Just stem -> T.unpack stem ++ ".html"
    Nothing -> p

buildPageContext :: PageMeta -> [PageMeta] -> [TocEntry] -> Context String
buildPageContext pm allPages tocEntries =
  let tocHtml = renderTocHtml tocEntries
      hasTocCls = if null tocEntries then "layout-no-toc" else "layout-with-toc"
      siteRootHref = computeRelativeRoot (pmRoute pm)
      brandHref =
        if any (\p -> pmRoute p == "index") allPages
          then "/index.html"
          else case allPages of
            (firstP : _) -> T.unpack (pmUrl firstP)
            [] -> "#"
   in mconcat
        [ constField "title" (T.unpack (pmTitle pm))
        , constField "nav_title" (T.unpack (pmNavTitle pm))
        , constField "description" (T.unpack (pmDescription pm))
        , constField "section_label" (T.unpack (sectionLabel (pmSection pm)))
        , constField "section_slug" (T.unpack (sectionSlug (pmSection pm)))
        , constField "sidebar_nav" (T.unpack (renderSidebarHtml (pmRoute pm) allPages))
        , constField "breadcrumbs" (T.unpack (renderBreadcrumbsHtml pm allPages))
        , constField "prev_next" (T.unpack (renderPrevNextHtml (pmRoute pm) allPages))
        , constField "toc_html" (T.unpack tocHtml)
        , constField "layout_class" hasTocCls
        , constField "site_root" siteRootHref
        , constField "brand_href" brandHref
        , defaultContext
        ]
  where
    -- Relative prefix to site root (e.g. "." for index.html, ".." for guide/quickstart.html)
    -- used by docs.js to fetch search-index.json at any mount subpath!
    computeRelativeRoot pageRoute =
      let depth = length (T.splitOn "/" pageRoute) - 1
       in if depth <= 0
            then "."
            else T.unpack (T.intercalate "/" (replicate depth ".."))
