{-# LANGUAGE OverloadedStrings #-}

-- | Strict post-build HTML internal link and @#anchor@ checker across @out-dir@.
--
-- Parses every generated @.html@ file using @tagsoup@ and verifies:
--
--   1. Every internal @<a href="...">@ target HTML/asset file exists in @out-dir@.
--   2. Every @#fragment@ (same-page or cross-page) matches an actual @id="..."@
--      or @name="..."@ attribute in the target HTML file.
module Docs.LinkCheck
  ( LinkError (..)
  , formatLinkError
  , checkSiteLinks
  , extractIdsAndHrefs
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as BS
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (normalise, splitDirectories, takeDirectory, takeExtension, (</>))
import Text.HTML.TagSoup (Tag (..), parseTags)

data LinkError = LinkError
  { leSourceFile :: !FilePath
  , leHref :: !Text
  , leReason :: !String
  }
  deriving (Eq, Show)

formatLinkError :: LinkError -> String
formatLinkError le =
  leSourceFile le
    ++ ": broken link "
    ++ show (T.unpack (leHref le))
    ++ " ("
    ++ leReason le
    ++ ")"

-- | Extract @(definedIds, anchorHrefs)@ from an HTML document's tag stream.
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

-- | Recursively discover all @.html@ files under @rootDir@ as normalized
-- paths relative to @rootDir@ (using forward slashes).
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

-- | Validate all internal links and @#id@ anchors across @outDir@.
checkSiteLinks :: FilePath -> IO [LinkError]
checkSiteLinks outDir = do
  htmlFiles <- listHtmlFiles outDir
  parsedPairs <- forM htmlFiles $ \relFile -> do
    txt <- TE.decodeUtf8Lenient <$> BS.readFile (outDir </> relFile)
    pure (relFile, extractIdsAndHrefs txt)
  let idMap :: Map FilePath (Set Text)
      idMap = Map.fromList [(f, ids) | (f, (ids, _)) <- parsedPairs]
  fmap concat . forM parsedPairs $ \(srcRel, (_, hrefs)) ->
    fmap concat . forM hrefs $ \href ->
      validateHref outDir idMap srcRel href

validateHref :: FilePath -> Map FilePath (Set Text) -> FilePath -> Text -> IO [LinkError]
validateHref outDir idMap srcRel rawHref =
  let href = T.strip rawHref
   in if isSkippedHref href
        then pure []
        else do
          let (pathPart0, fragPart0) = T.breakOn "#" href
              (pathPart, _queryPart) = T.breakOn "?" pathPart0
              frag = T.drop 1 fragPart0
          targetRelE <-
            if T.null pathPart
              then pure (Right srcRel)
              else pure (resolveRelativeTarget srcRel (T.unpack pathPart))
          case targetRelE of
            Left escapeReason ->
              pure [LinkError srcRel rawHref escapeReason]
            Right targetRel ->
              case Map.lookup targetRel idMap of
                Just targetIds ->
                  if T.null frag || frag `Set.member` targetIds
                    then pure []
                    else
                      pure
                        [ LinkError
                            srcRel
                            rawHref
                            ("anchor #" ++ T.unpack frag ++ " not found in " ++ targetRel)
                        ]
                Nothing -> do
                  -- May be a non-HTML static file link (e.g. search-index.json or CSS)
                  fileExists <- doesFileExist (outDir </> targetRel)
                  dirIndexExists <- doesFileExist (outDir </> targetRel </> "index.html")
                  if dirIndexExists
                    then
                      let idxRel =
                            if null targetRel
                              then "index.html"
                              else targetRel ++ "/index.html"
                       in case Map.lookup idxRel idMap of
                            Just idxIds
                              | not (T.null frag) && frag `Set.notMember` idxIds ->
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
   in collapseSegments [] segs
  where
    collapseSegments acc [] =
      Right (T.unpack (T.intercalate "/" (map T.pack (reverse acc))))
    collapseSegments acc (s : ss)
      | s == "." || s == "/" || null s = collapseSegments acc ss
      | s == ".." =
          case acc of
            [] -> Left "relative link escapes site root"
            (_ : rest) -> collapseSegments rest ss
      | otherwise = collapseSegments (s : acc) ss

isSkippedHref :: Text -> Bool
isSkippedHref h =
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
