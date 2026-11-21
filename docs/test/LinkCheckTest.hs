{-# LANGUAGE OverloadedStrings #-}

-- | Standalone HTML internal link, @#anchor@ fragment, and vanilla-Markdown
-- hygiene test (@//docs:link_check_test@) across the built @//docs:site@ tree
-- (including mounted Haddock documentation at @haddock/lock/@).
module Main (main) where

import Control.Monad (forM, unless, when)
import qualified Data.ByteString as BS
import Data.Char (digitToInt, isHexDigit)
import Data.List (isPrefixOf, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (die, exitSuccess)
import System.FilePath (normalise, splitDirectories, takeDirectory, takeExtension, (</>))
import Text.HTML.TagSoup (Tag (..), parseTags)

data LinkError = LinkError
  { leSource :: !FilePath
  , leHref :: !Text
  , leReason :: !String
  }
  deriving (Eq, Show)

formatLinkError :: LinkError -> String
formatLinkError le =
  leSource le
    ++ ": broken link "
    ++ show (T.unpack (leHref le))
    ++ " ("
    ++ leReason le
    ++ ")"

forbiddenTokens :: [Text]
forbiddenTokens =
  [ "bzl:rule:"
  , "bzl:ext:"
  , "bzl:provider:"
  , "cli:lock"
  , "doc:guide/"
  , "doc:reference/"
  , "doc:internals/"
  , "::: {"
  , "bzl-autodoc"
  ]

main :: IO ()
main = do
  setLocaleEncoding utf8
  args <- getArgs
  siteDir <- case args of
    (d : _) -> pure d
    [] -> die "Usage: link_check_test <site_dir>"

  exists <- doesDirectoryExist siteDir
  unless exists $
    die ("Site directory does not exist: " ++ siteDir)

  htmlFiles <- listHtmlFiles siteDir
  when (null htmlFiles) $
    die ("No .html files found in " ++ siteDir)

  parsed <- forM htmlFiles $ \relFile -> do
    txt <- TE.decodeUtf8Lenient <$> BS.readFile (siteDir </> relFile)
    pure (relFile, txt, extractIdsAndHrefs txt)

  let idMap :: Map FilePath (Set Text)
      idMap = Map.fromList [(f, ids) | (f, _, (ids, _)) <- parsed]
      totalLinks = sum [length hrefs | (_, _, (_, hrefs)) <- parsed]

  linkErrors <- fmap concat . forM parsed $ \(srcRel, _, (_, hrefs)) ->
    fmap concat . forM hrefs $ \href ->
      validateHref siteDir idMap srcRel href

  unless (null linkErrors) $
    die $
      unlines
        ( ("Internal link / #anchor check failed (" ++ show (length linkErrors) ++ " broken):")
            : map (("  - " ++) . formatLinkError) linkErrors
        )

  -- Always enforce zero legacy Sphinx-like tokens on internals/docs-engine.html,
  -- and enforce across all Hakyll pages once content/index.md has been converted.
  let textMap = Map.fromList [(f, txt) | (f, txt, _) <- parsed]
      indexConverted =
        case Map.lookup "index.html" textMap of
          Just idxTxt -> not (any (`T.isInfixOf` idxTxt) forbiddenTokens)
          Nothing -> False
      filesToAudit =
        if indexConverted
          then [f | f <- htmlFiles, not ("haddock/" `isPrefixOf` f)]
          else ["internals/docs-engine.html"]
      tokenErrors =
        [ f ++ ": contains forbidden custom syntax token " ++ show (T.unpack tok)
        | f <- filesToAudit
        , Just txt <- [Map.lookup f textMap]
        , tok <- forbiddenTokens
        , tok `T.isInfixOf` txt
        ]

  unless (null tokenErrors) $
    die $
      unlines
        ( "Unrendered custom Sphinx-like syntax tokens found in HTML:"
            : map ("  - " ++) tokenErrors
        )

  putStrLn $
    "OK: verified "
      ++ show (length htmlFiles)
      ++ " HTML pages (including Haddock) and "
      ++ show totalLinks
      ++ " links/anchors with 0 errors."
  exitSuccess

extractIdsAndHrefs :: Text -> (Set Text, [Text])
extractIdsAndHrefs html =
  let tags = parseTags html
      ids =
        Set.fromList
          [ val
          | TagOpen _ attrs <- tags
          , (k, val) <- attrs
          , let kl = T.toLower k
          , (kl == "id" || kl == "name") && not (T.null val)
          ]
      hrefs =
        [ href
        | TagOpen tagName attrs <- tags
        , T.toLower tagName == "a"
        , (k, href) <- attrs
        , T.toLower k == "href"
        , not (T.null (T.strip href))
        ]
   in (ids, hrefs)

listHtmlFiles :: FilePath -> IO [FilePath]
listHtmlFiles rootDir = sort <$> go ""
  where
    go relDir = do
      let absDir = if null relDir then rootDir else rootDir </> relDir
      entries <- sort <$> listDirectory absDir
      fmap concat . forM entries $ \entry -> do
        let relPath = if null relDir then entry else relDir ++ "/" ++ entry
            absPath = absDir </> entry
        isDir <- doesDirectoryExist absPath
        if isDir
          then go relPath
          else
            if takeExtension entry == ".html"
              then pure [relPath]
              else pure []

validateHref :: FilePath -> Map FilePath (Set Text) -> FilePath -> Text -> IO [LinkError]
validateHref outDir idMap srcRel rawHref =
  let href = T.strip rawHref
   in if isExternalOrSpecialHref href
        then pure []
        else do
          let (pathPart0, fragPart0) = T.breakOn "#" href
              (pathPart, _queryPart) = T.breakOn "?" pathPart0
              frag = T.drop 1 fragPart0
              decodedFrag = T.pack (percentDecode (T.unpack frag))
              isHaddockDerivedMethodSelfLink =
                "haddock/" `isPrefixOf` srcRel
                  && T.null pathPart
                  && "v:" `T.isPrefixOf` frag
              matchesId ids =
                T.null frag
                  || isHaddockDerivedMethodSelfLink
                  || frag `Set.member` ids
                  || decodedFrag `Set.member` ids
              targetRelE =
                if T.null pathPart
                  then Right srcRel
                  else resolveRelativeTarget srcRel (percentDecode (T.unpack pathPart))
          case targetRelE of
            Left reason ->
              pure [LinkError srcRel rawHref reason]
            Right targetRel ->
              case Map.lookup targetRel idMap of
                Just targetIds ->
                  if matchesId targetIds
                    then pure []
                    else
                      pure
                        [ LinkError
                            srcRel
                            rawHref
                            ("anchor #" ++ T.unpack frag ++ " not found in " ++ targetRel)
                        ]
                Nothing -> do
                  fileExists <- doesFileExist (outDir </> targetRel)
                  let idxRel =
                        if null targetRel
                          then "index.html"
                          else targetRel ++ "/index.html"
                  dirIndexExists <- doesFileExist (outDir </> idxRel)
                  if dirIndexExists
                    then case Map.lookup idxRel idMap of
                      Just idxIds
                        | not (matchesId idxIds) ->
                            pure
                              [ LinkError
                                  srcRel
                                  rawHref
                                  ("anchor #" ++ T.unpack frag ++ " not found in " ++ idxRel)
                              ]
                      _ -> pure []
                    else
                      if fileExists
                        then pure []
                        else
                          pure
                            [ LinkError
                                srcRel
                                rawHref
                                ("target file does not exist: " ++ targetRel)
                            ]

resolveRelativeTarget :: FilePath -> FilePath -> Either String FilePath
resolveRelativeTarget srcRel targetPath =
  let combined =
        case targetPath of
          ('/' : rest) -> rest
          rel ->
            let baseDir = takeDirectory srcRel
             in if baseDir == "." || null baseDir
                  then rel
                  else baseDir ++ "/" ++ rel
      segs = splitDirectories (normalise combined)
   in collapse [] segs
  where
    collapse acc [] =
      Right (T.unpack (T.intercalate "/" (map T.pack (reverse acc))))
    collapse acc (s : ss)
      | s == "." || s == "/" || null s = collapse acc ss
      | s == ".." =
          case acc of
            [] -> Left "relative link escapes site root"
            (_ : rest) -> collapse rest ss
      | otherwise = collapse (s : acc) ss

percentDecode :: String -> String
percentDecode [] = []
percentDecode ('%' : h1 : h2 : rest)
  | isHexDigit h1 && isHexDigit h2 =
      toEnum (digitToInt h1 * 16 + digitToInt h2) : percentDecode rest
percentDecode (c : rest) = c : percentDecode rest

isExternalOrSpecialHref :: Text -> Bool
isExternalOrSpecialHref h =
  let low = T.toLower h
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
