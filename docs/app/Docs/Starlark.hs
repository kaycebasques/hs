{-# LANGUAGE OverloadedStrings #-}

-- | Sphinx @autodoc@-style Starlark (@.bzl@) introspection, directive expansion,
-- and public API symbol-coverage verification for @rules_hs@.
module Docs.Starlark
  ( BzlAttr (..)
  , BzlRule (..)
  , BzlField (..)
  , BzlProvider (..)
  , BzlTagClass (..)
  , BzlExtension (..)
  , StarlarkBundle (..)
  , emptyStarlarkBundle
  , parseStarlarkFile
  , loadStarlarkBundle
  , expandStarlarkAutodoc
  , verifyStarlarkReferenceCoverage
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum, isSpace, toLower)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Docs.Nav (escapeHtml)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Text.Pandoc.Definition
import Text.Pandoc.Walk (walk)

readUtf8File :: FilePath -> IO Text
readUtf8File path = TE.decodeUtf8Lenient <$> BS.readFile path

data BzlAttr = BzlAttr
  { baName :: !Text
  , baType :: !Text
  , baDefault :: !(Maybe Text)
  , baMandatory :: !Bool
  , baDoc :: !Text
  }
  deriving (Eq, Show)

data BzlRule = BzlRule
  { brName :: !Text
  , brSource :: !Text
  , brDoc :: !Text
  , brAttrs :: ![BzlAttr]
  }
  deriving (Eq, Show)

data BzlField = BzlField
  { bfName :: !Text
  , bfDoc :: !Text
  }
  deriving (Eq, Show)

data BzlProvider = BzlProvider
  { bpName :: !Text
  , bpSource :: !Text
  , bpDoc :: !Text
  , bpFields :: ![BzlField]
  }
  deriving (Eq, Show)

data BzlTagClass = BzlTagClass
  { btcName :: !Text
  , btcDoc :: !Text
  , btcAttrs :: ![BzlAttr]
  }
  deriving (Eq, Show)

data BzlExtension = BzlExtension
  { beName :: !Text
  , beSource :: !Text
  , beDoc :: !Text
  , beTags :: ![BzlTagClass]
  }
  deriving (Eq, Show)

data StarlarkBundle = StarlarkBundle
  { sbRules :: !(Map Text BzlRule)
  , sbPublicRules :: ![Text]
  , sbProviders :: !(Map Text BzlProvider)
  , sbExtensions :: !(Map Text BzlExtension)
  }
  deriving (Eq, Show)

emptyStarlarkBundle :: StarlarkBundle
emptyStarlarkBundle = StarlarkBundle Map.empty [] Map.empty Map.empty

-- | Load and introspect all @rules_hs@ Starlark files under @--bzl-dir@ (i.e. @hs/@).
loadStarlarkBundle :: FilePath -> IO StarlarkBundle
loadStarlarkBundle bzlDir = do
  setLocaleEncoding utf8
  let relFiles =
        [ ("hs/private/rules.bzl", bzlDir </> "private" </> "rules.bzl")
        , ("hs/private/cabal_library.bzl", bzlDir </> "private" </> "cabal_library.bzl")
        , ("hs/private/hackage.bzl", bzlDir </> "private" </> "hackage.bzl")
        , ("hs/providers.bzl", bzlDir </> "providers.bzl")
        , ("hs/toolchain.bzl", bzlDir </> "toolchain.bzl")
        , ("hs/extensions.bzl", bzlDir </> "extensions.bzl")
        , ("hs/defs.bzl", bzlDir </> "defs.bzl")
        ]
  parsedList <- forM relFiles $ \(srcLabel, path) -> do
    exists <- doesFileExist path
    if exists
      then parseStarlarkFile srcLabel <$> readUtf8File path
      else pure emptyParsedFile

  let merged = foldl' mergeParsed emptyParsedFile parsedList
      pubRules =
        case Map.lookup "hs/defs.bzl" (pfExportsBySource merged) of
          Just exps | not (null exps) -> exps
          _ -> Map.keys (pfRules merged)
      -- Promote source labels for public rules/extensions re-exported in defs.bzl / extensions.bzl
      rulesWithPub =
        Map.mapWithKey
          ( \k r ->
              if k `elem` pubRules
                then r {brSource = "hs/defs.bzl"}
                else r
          )
          (pfRules merged)
      extsWithPub =
        Map.map
          (\e -> e {beSource = "hs/extensions.bzl"})
          (pfExtensions merged)
   in pure
        StarlarkBundle
          { sbRules = rulesWithPub
          , sbPublicRules = pubRules
          , sbProviders = pfProviders merged
          , sbExtensions = extsWithPub
          }

data ParsedFile = ParsedFile
  { pfRules :: !(Map Text BzlRule)
  , pfProviders :: !(Map Text BzlProvider)
  , pfExtensions :: !(Map Text BzlExtension)
  , pfExportsBySource :: !(Map Text [Text])
  }

emptyParsedFile :: ParsedFile
emptyParsedFile = ParsedFile Map.empty Map.empty Map.empty Map.empty

mergeParsed :: ParsedFile -> ParsedFile -> ParsedFile
mergeParsed a b =
  ParsedFile
    { pfRules = Map.union (pfRules b) (pfRules a)
    , pfProviders = Map.union (pfProviders b) (pfProviders a)
    , pfExtensions = Map.union (pfExtensions b) (pfExtensions a)
    , pfExportsBySource = Map.unionWith (\x y -> nub (x ++ y)) (pfExportsBySource a) (pfExportsBySource b)
    }

-- | Parse a single Starlark @.bzl@ file into rules, providers, tag classes,
-- module extensions, and public re-export aliases.
parseStarlarkFile :: Text -> Text -> ParsedFile
parseStarlarkFile srcLabel rawContent =
  let cleanContent = stripCommentsPreserveStrings rawContent
      stmts = topLevelAssignments cleanContent
      -- Pass 1: collect reusable attr dicts (e.g. `_EXECUTABLE_ATTRS = {...}`) and `tag_class(...)`
      attrDicts =
        Map.fromList
          [ (lhs, parseAttrsBlock rhs)
          | (lhs, rhs) <- stmts
          , "{" `T.isPrefixOf` T.stripStart rhs
          ]
      tagClasses =
        Map.fromList
          [ (lhs, parseTagClass lhs attrDicts argsTxt)
          | (lhs, rhs) <- stmts
          , Just argsTxt <- [extractCallBody "tag_class" rhs]
          ]
      -- Pass 2: collect `rule(...)`, `provider(...)`, `module_extension(...)`, and aliases
      rules =
        Map.fromList
          [ (lhs, parseRule lhs srcLabel attrDicts argsTxt)
          | (lhs, rhs) <- stmts
          , not ("_" `T.isPrefixOf` lhs)
          , Just argsTxt <- [extractCallBody "rule" rhs]
          ]
      providers =
        Map.fromList
          [ (lhs, parseProvider lhs srcLabel argsTxt)
          | (lhs, rhs) <- stmts
          , not ("_" `T.isPrefixOf` lhs)
          , Just argsTxt <- [extractCallBody "provider" rhs]
          ]
      extensions =
        Map.fromList
          [ (lhs, parseExtension lhs srcLabel tagClasses argsTxt)
          | (lhs, rhs) <- stmts
          , not ("_" `T.isPrefixOf` lhs)
          , Just argsTxt <- [extractCallBody "module_extension" rhs]
          ]
      exports =
        [ lhs
        | (lhs, rhs) <- stmts
        , not ("_" `T.isPrefixOf` lhs)
        , isIdent (T.strip rhs)
        ]
   in ParsedFile
        { pfRules = rules
        , pfProviders = providers
        , pfExtensions = extensions
        , pfExportsBySource =
            if null exports
              then Map.empty
              else Map.singleton srcLabel exports
        }

isIdent :: Text -> Bool
isIdent t =
  not (T.null t) && T.all (\c -> isAlphaNum c || c == '_') t

-- | Strip `#` line comments outside single/double/triple-quoted string literals.
stripCommentsPreserveStrings :: Text -> Text
stripCommentsPreserveStrings = goNormal
  where
    goNormal txt =
      case T.uncons txt of
        Nothing -> ""
        Just ('#', rest) ->
          let (_, afterNl) = T.breakOn "\n" rest
           in goNormal afterNl
        Just ('"', rest)
          | "\"\"" `T.isPrefixOf` rest ->
              "\"\"\"" <> goTriple '"' (T.drop 2 rest)
          | otherwise ->
              "\"" <> goQuoted '"' rest
        Just ('\'', rest)
          | "''" `T.isPrefixOf` rest ->
              "'''" <> goTriple '\'' (T.drop 2 rest)
          | otherwise ->
              "'" <> goQuoted '\'' rest
        Just (c, rest) ->
          T.singleton c <> goNormal rest

    goQuoted q txt =
      case T.uncons txt of
        Nothing -> ""
        Just ('\\', rest) ->
          case T.uncons rest of
            Nothing -> "\\"
            Just (c2, rest2) -> "\\" <> T.singleton c2 <> goQuoted q rest2
        Just (c, rest)
          | c == q -> T.singleton c <> goNormal rest
          | otherwise -> T.singleton c <> goQuoted q rest

    goTriple q txt =
      let delim = T.replicate 3 (T.singleton q)
       in if delim `T.isPrefixOf` txt
            then delim <> goNormal (T.drop 3 txt)
            else case T.uncons txt of
              Nothing -> ""
              Just (c, rest) -> T.singleton c <> goTriple q rest

-- | Split top-level @ident = expr@ assignments respecting balanced @()@, @[]@, @{}@, and strings.
topLevelAssignments :: Text -> [(Text, Text)]
topLevelAssignments src =
  mapMaybe parseAssignment (splitTopLevelStatements src)
  where
    parseAssignment stmt =
      let s = T.strip stmt
          (lhs0, rest0) = T.span (\c -> isAlphaNum c || c == '_') s
          rest1 = T.stripStart rest0
       in if not (T.null lhs0)
            && "=" `T.isPrefixOf` rest1
            && not ("==" `T.isPrefixOf` rest1)
            then Just (lhs0, T.strip (T.drop 1 rest1))
            else Nothing

splitTopLevelStatements :: Text -> [Text]
splitTopLevelStatements = go (0 :: Int) [] ""
  where
    go _ acc cur txt
      | T.null txt =
          reverse (if T.null (T.strip cur) then acc else cur : acc)
    go depth acc cur txt
      | "\"\"\"" `T.isPrefixOf` txt =
          let (lit, rest) = consumeTriple '"' (T.drop 3 txt)
           in go depth acc (cur <> "\"\"\"" <> lit) rest
      | "'''" `T.isPrefixOf` txt =
          let (lit, rest) = consumeTriple '\'' (T.drop 3 txt)
           in go depth acc (cur <> "'''" <> lit) rest
      | "\"" `T.isPrefixOf` txt =
          let (lit, rest) = consumeSingle '"' (T.drop 1 txt)
           in go depth acc (cur <> "\"" <> lit) rest
      | "'" `T.isPrefixOf` txt =
          let (lit, rest) = consumeSingle '\'' (T.drop 1 txt)
           in go depth acc (cur <> "'" <> lit) rest
      | otherwise =
          case T.uncons txt of
            Nothing -> reverse (cur : acc)
            Just (c, rest)
              | c `elem` ("([{" :: String) ->
                  go (depth + 1) acc (cur <> T.singleton c) rest
              | c `elem` (")]}" :: String) ->
                  go (max 0 (depth - 1)) acc (cur <> T.singleton c) rest
              | c == '\n' && depth == 0 ->
                  if T.null (T.strip cur)
                    then go 0 acc "" rest
                    else go 0 (cur : acc) "" rest
              | otherwise ->
                  go depth acc (cur <> T.singleton c) rest

consumeSingle :: Char -> Text -> (Text, Text)
consumeSingle q = go ""
  where
    go acc txt =
      case T.uncons txt of
        Nothing -> (acc, "")
        Just ('\\', rest) ->
          case T.uncons rest of
            Nothing -> (acc <> "\\", "")
            Just (c2, rest2) -> go (acc <> "\\" <> T.singleton c2) rest2
        Just (c, rest)
          | c == q -> (acc <> T.singleton c, rest)
          | otherwise -> go (acc <> T.singleton c) rest

consumeTriple :: Char -> Text -> (Text, Text)
consumeTriple q = go ""
  where
    delim = T.replicate 3 (T.singleton q)
    go acc txt
      | delim `T.isPrefixOf` txt = (acc <> delim, T.drop 3 txt)
      | otherwise =
          case T.uncons txt of
            Nothing -> (acc, "")
            Just (c, rest) -> go (acc <> T.singleton c) rest

-- | Split comma-separated items at nesting depth 0.
splitTopLevelCommas :: Text -> [Text]
splitTopLevelCommas = go (0 :: Int) [] ""
  where
    go _ acc cur txt
      | T.null txt =
          reverse [x | x <- cur : acc, not (T.null (T.strip x))]
    go depth acc cur txt
      | "\"\"\"" `T.isPrefixOf` txt =
          let (lit, rest) = consumeTriple '"' (T.drop 3 txt)
           in go depth acc (cur <> "\"\"\"" <> lit) rest
      | "'''" `T.isPrefixOf` txt =
          let (lit, rest) = consumeTriple '\'' (T.drop 3 txt)
           in go depth acc (cur <> "'''" <> lit) rest
      | "\"" `T.isPrefixOf` txt =
          let (lit, rest) = consumeSingle '"' (T.drop 1 txt)
           in go depth acc (cur <> "\"" <> lit) rest
      | "'" `T.isPrefixOf` txt =
          let (lit, rest) = consumeSingle '\'' (T.drop 1 txt)
           in go depth acc (cur <> "'" <> lit) rest
      | otherwise =
          case T.uncons txt of
            Nothing -> reverse (cur : acc)
            Just (c, rest)
              | c `elem` ("([{" :: String) ->
                  go (depth + 1) acc (cur <> T.singleton c) rest
              | c `elem` (")]}" :: String) ->
                  go (max 0 (depth - 1)) acc (cur <> T.singleton c) rest
              | c == ',' && depth == 0 ->
                  go 0 (cur : acc) "" rest
              | otherwise ->
                  go depth acc (cur <> T.singleton c) rest

extractCallBody :: Text -> Text -> Maybe Text
extractCallBody fnName expr =
  let s = T.strip expr
   in case T.stripPrefix fnName s of
        Nothing -> Nothing
        Just afterName ->
          let s1 = T.stripStart afterName
           in if "(" `T.isPrefixOf` s1 && ")" `T.isSuffixOf` s1
                then Just (T.dropEnd 1 (T.drop 1 s1))
                else Nothing

extractBracesBody :: Text -> Maybe Text
extractBracesBody expr =
  let s = T.strip expr
   in if "{" `T.isPrefixOf` s && "}" `T.isSuffixOf` s
        then Just (T.dropEnd 1 (T.drop 1 s))
        else Nothing

parseKwargs :: Text -> Map Text Text
parseKwargs body =
  Map.fromList (mapMaybe parseOne (splitTopLevelCommas body))
  where
    parseOne item =
      let s = T.strip item
          (k, rest0) = T.span (\c -> isAlphaNum c || c == '_') s
          rest1 = T.stripStart rest0
       in if not (T.null k) && "=" `T.isPrefixOf` rest1 && not ("==" `T.isPrefixOf` rest1)
            then Just (k, T.strip (T.drop 1 rest1))
            else Nothing

parseDictEntries :: Text -> [(Text, Text)]
parseDictEntries expr =
  case extractBracesBody expr of
    Nothing -> []
    Just inner -> mapMaybe parseKV (splitTopLevelCommas inner)
  where
    parseKV item =
      let (kRaw, rest0) = breakTopLevelColon item
       in if T.null rest0
            then Nothing
            else Just (unquoteString (T.strip kRaw), T.strip (T.drop 1 rest0))

breakTopLevelColon :: Text -> (Text, Text)
breakTopLevelColon = go (0 :: Int) ""
  where
    go _ cur txt | T.null txt = (cur, "")
    go depth cur txt
      | "\"" `T.isPrefixOf` txt =
          let (lit, rest) = consumeSingle '"' (T.drop 1 txt)
           in go depth (cur <> "\"" <> lit) rest
      | "'" `T.isPrefixOf` txt =
          let (lit, rest) = consumeSingle '\'' (T.drop 1 txt)
           in go depth (cur <> "'" <> lit) rest
      | otherwise =
          case T.uncons txt of
            Nothing -> (cur, "")
            Just (c, rest)
              | c `elem` ("([{" :: String) -> go (depth + 1) (cur <> T.singleton c) rest
              | c `elem` (")]}" :: String) -> go (max 0 (depth - 1)) (cur <> T.singleton c) rest
              | c == ':' && depth == 0 -> (cur, txt)
              | otherwise -> go depth (cur <> T.singleton c) rest

unquoteString :: Text -> Text
unquoteString raw =
  let s = T.strip raw
   in case () of
        _
          | "\"\"\"" `T.isPrefixOf` s && "\"\"\"" `T.isSuffixOf` s && T.length s >= 6 ->
              unescape (T.dropEnd 3 (T.drop 3 s))
          | "'''" `T.isPrefixOf` s && "'''" `T.isSuffixOf` s && T.length s >= 6 ->
              unescape (T.dropEnd 3 (T.drop 3 s))
          | "\"" `T.isPrefixOf` s && "\"" `T.isSuffixOf` s && T.length s >= 2 ->
              unescape (T.dropEnd 1 (T.drop 1 s))
          | "'" `T.isPrefixOf` s && "'" `T.isSuffixOf` s && T.length s >= 2 ->
              unescape (T.dropEnd 1 (T.drop 1 s))
          | otherwise -> s
  where
    unescape =
      T.replace "\\\"" "\""
        . T.replace "\\'" "'"
        . T.replace "\\n" "\n"
        . T.replace "\\\\" "\\"

parseRule :: Text -> Text -> Map Text [BzlAttr] -> Text -> BzlRule
parseRule name srcLabel attrDicts argsTxt =
  let kws = parseKwargs argsTxt
      docTxt = maybe "" unquoteString (Map.lookup "doc" kws)
      attrs =
        case Map.lookup "attrs" kws of
          Nothing -> []
          Just attrExpr ->
            let trimmed = T.strip attrExpr
             in if "{" `T.isPrefixOf` trimmed
                  then parseAttrsBlock trimmed
                  else Map.findWithDefault [] trimmed attrDicts
   in BzlRule
        { brName = name
        , brSource = srcLabel
        , brDoc = docTxt
        , brAttrs = attrs
        }

parseAttrsBlock :: Text -> [BzlAttr]
parseAttrsBlock dictExpr =
  [ parseSingleAttr attrName rhs
  | (attrName, rhs) <- parseDictEntries dictExpr
  , not ("_" `T.isPrefixOf` attrName)
  ]

parseSingleAttr :: Text -> Text -> BzlAttr
parseSingleAttr name rhs =
  let s = T.strip rhs
      (callPrefix, rest) = T.breakOn "(" s
      attrKind = fromMaybe (T.strip callPrefix) (T.stripPrefix "attr." (T.strip callPrefix))
      innerArgs =
        if "(" `T.isPrefixOf` rest && ")" `T.isSuffixOf` rest
          then T.dropEnd 1 (T.drop 1 rest)
          else ""
      kws = parseKwargs innerArgs
      mandatory =
        case Map.lookup "mandatory" kws of
          Just v -> T.strip v == "True"
          Nothing -> False
      defVal =
        case Map.lookup "default" kws of
          Just v -> Just (T.strip v)
          Nothing -> if mandatory then Nothing else defaultImplicitForKind attrKind
      docTxt = maybe "" unquoteString (Map.lookup "doc" kws)
   in BzlAttr
        { baName = name
        , baType = attrKind
        , baDefault = defVal
        , baMandatory = mandatory
        , baDoc = docTxt
        }

defaultImplicitForKind :: Text -> Maybe Text
defaultImplicitForKind "string" = Just "\"\""
defaultImplicitForKind "bool" = Just "False"
defaultImplicitForKind "string_list" = Just "[]"
defaultImplicitForKind "label_list" = Just "[]"
defaultImplicitForKind "string_dict" = Just "{}"
defaultImplicitForKind "label" = Just "None"
defaultImplicitForKind _ = Nothing

parseProvider :: Text -> Text -> Text -> BzlProvider
parseProvider name srcLabel argsTxt =
  let kws = parseKwargs argsTxt
      docTxt = maybe "" unquoteString (Map.lookup "doc" kws)
      fields =
        case Map.lookup "fields" kws of
          Nothing -> []
          Just fExpr ->
            [ BzlField fname (unquoteString fdoc)
            | (fname, fdoc) <- parseDictEntries fExpr
            ]
   in BzlProvider
        { bpName = name
        , bpSource = srcLabel
        , bpDoc = docTxt
        , bpFields = fields
        }

parseTagClass :: Text -> Map Text [BzlAttr] -> Text -> BzlTagClass
parseTagClass varName attrDicts argsTxt =
  let kws = parseKwargs argsTxt
      docTxt = maybe "" unquoteString (Map.lookup "doc" kws)
      attrs =
        case Map.lookup "attrs" kws of
          Nothing -> []
          Just aExpr ->
            if "{" `T.isPrefixOf` T.strip aExpr
              then parseAttrsBlock aExpr
              else Map.findWithDefault [] (T.strip aExpr) attrDicts
   in BzlTagClass
        { btcName = varName
        , btcDoc = docTxt
        , btcAttrs = attrs
        }

parseExtension :: Text -> Text -> Map Text BzlTagClass -> Text -> BzlExtension
parseExtension name srcLabel tagMap argsTxt =
  let kws = parseKwargs argsTxt
      docTxt = maybe "" unquoteString (Map.lookup "doc" kws)
      tags =
        case Map.lookup "tag_classes" kws of
          Nothing -> []
          Just tcExpr ->
            [ case Map.lookup (T.strip rhs) tagMap of
                Just tc -> tc {btcName = tagName}
                Nothing ->
                  case extractCallBody "tag_class" rhs of
                    Just inlineArgs ->
                      (parseTagClass tagName Map.empty inlineArgs) {btcName = tagName}
                    Nothing -> BzlTagClass tagName "" []
            | (tagName, rhs) <- parseDictEntries tcExpr
            ]
   in BzlExtension
        { beName = name
        , beSource = srcLabel
        , beDoc = docTxt
        , beTags = tags
        }

-- | Expand @::: {.bzl-autodoc source="hs/..."}@ fenced divs into generated
-- HTML API documentation tables.
expandStarlarkAutodoc :: StarlarkBundle -> Pandoc -> Pandoc
expandStarlarkAutodoc bundle = walk stepBlock
  where
    stepBlock :: Block -> Block
    stepBlock (Div (_ident, classes, kvs) _inner)
      | "bzl-autodoc" `elem` classes =
          let srcFilter = lookup "source" kvs
              symFilter = lookup "symbol" kvs
              rendered = renderAutodocHtml bundle srcFilter symFilter
           in RawBlock (Format "html") rendered
    stepBlock other = other

renderAutodocHtml :: StarlarkBundle -> Maybe Text -> Maybe Text -> Text
renderAutodocHtml bundle srcFilter symFilter =
  let matchSrc actual =
        case srcFilter of
          Nothing -> True
          Just sf ->
            let s = T.strip sf
             in s == actual
                  || (s == "hs/defs.bzl" && actual `elem` ["hs/defs.bzl", "hs/private/rules.bzl", "hs/private/cabal_library.bzl"])
      matchSym name =
        case symFilter of
          Nothing -> True
          Just sym -> T.strip sym == name

      orderedRuleNames =
        let pub = sbPublicRules bundle
            extra = [k | k <- Map.keys (sbRules bundle), k `notElem` pub]
         in pub ++ extra
      matchedRules =
        [ r
        | rname <- orderedRuleNames
        , Just r <- [Map.lookup rname (sbRules bundle)]
        , matchSrc (brSource r) || (srcFilter == Just "hs/private/rules.bzl" && rname /= "hs_cabal_library" && rname /= "hs_toolchain")
        , matchSym (brName r)
        ]
      matchedProviders =
        [ p
        | p <- Map.elems (sbProviders bundle)
        , matchSrc (bpSource p)
        , matchSym (bpName p)
        ]
      matchedExts =
        [ e
        | e <- Map.elems (sbExtensions bundle)
        , matchSrc (beSource e)
        , matchSym (beName e)
        ]
   in T.concat $
        ["<div class=\"bzl-autodoc-block\">"]
          ++ map renderRuleHtml matchedRules
          ++ map renderExtensionHtml matchedExts
          ++ map renderProviderHtml matchedProviders
          ++ ["</div>"]

renderRuleHtml :: BzlRule -> Text
renderRuleHtml r =
  T.concat
    [ "<section class=\"autodoc-symbol\" id=\"autodoc-"
    , escapeHtml (brName r)
    , "\">"
    , "<div class=\"autodoc-signature\"><code>"
    , escapeHtml (brName r)
    , "(name, ...)</code><span class=\"autodoc-badge\">rule</span></div>"
    , if T.null (brDoc r)
        then ""
        else "<p class=\"autodoc-doc\">" <> escapeHtml (brDoc r) <> "</p>"
    , renderAttrsTable (brAttrs r)
    , "</section>"
    ]

renderExtensionHtml :: BzlExtension -> Text
renderExtensionHtml e =
  T.concat
    [ "<section class=\"autodoc-symbol\" id=\"autodoc-"
    , escapeHtml (beName e)
    , "\">"
    , "<div class=\"autodoc-signature\"><code>"
    , escapeHtml (beName e)
    , "</code><span class=\"autodoc-badge\">module_extension</span></div>"
    , if T.null (beDoc e)
        then ""
        else "<p class=\"autodoc-doc\">" <> escapeHtml (beDoc e) <> "</p>"
    , T.concat (map (renderTagHtml (beName e)) (beTags e))
    , "</section>"
    ]

renderTagHtml :: Text -> BzlTagClass -> Text
renderTagHtml extName tc =
  let fullTag = extName <> "." <> btcName tc
   in T.concat
        [ "<div class=\"autodoc-subtag\">"
        , "<div class=\"autodoc-signature\"><code>"
        , escapeHtml fullTag
        , "(...)</code><span class=\"autodoc-badge\">tag_class</span></div>"
        , if T.null (btcDoc tc)
            then ""
            else "<p class=\"autodoc-doc\">" <> escapeHtml (btcDoc tc) <> "</p>"
        , renderAttrsTable (btcAttrs tc)
        , "</div>"
        ]

renderProviderHtml :: BzlProvider -> Text
renderProviderHtml p =
  T.concat
    [ "<section class=\"autodoc-symbol\" id=\"autodoc-"
    , escapeHtml (T.map toLower (bpName p))
    , "\">"
    , "<div class=\"autodoc-signature\"><code>"
    , escapeHtml (bpName p)
    , "</code><span class=\"autodoc-badge\">provider</span></div>"
    , if T.null (bpDoc p)
        then ""
        else "<p class=\"autodoc-doc\">" <> escapeHtml (bpDoc p) <> "</p>"
    , "<table class=\"autodoc-table\"><thead><tr><th>Field</th><th>Type &amp; Description</th></tr></thead><tbody>"
    , T.concat
        [ "<tr><td><code>"
            <> escapeHtml (bfName f)
            <> "</code></td><td>"
            <> escapeHtml (bfDoc f)
            <> "</td></tr>"
        | f <- bpFields p
        ]
    , "</tbody></table></section>"
    ]

renderAttrsTable :: [BzlAttr] -> Text
renderAttrsTable [] = ""
renderAttrsTable attrs =
  T.concat
    [ "<table class=\"autodoc-table\"><thead><tr><th>Attribute</th><th>Type</th><th>Default</th><th>Description</th></tr></thead><tbody>"
    , T.concat (map renderAttrRow attrs)
    , "</tbody></table>"
    ]
  where
    renderAttrRow a =
      let defCell
            | baMandatory a = "<span class=\"autodoc-required\">required</span>"
            | Just d <- baDefault a = "<code>" <> escapeHtml d <> "</code>"
            | otherwise = "&mdash;"
       in T.concat
            [ "<tr><td><code>"
            , escapeHtml (baName a)
            , "</code></td><td><code>"
            , escapeHtml (baType a)
            , "</code></td><td>"
            , defCell
            , "</td><td>"
            , escapeHtml (baDoc a)
            , "</td></tr>"
            ]

-- | Verify that every public Starlark rule (from @hs/defs.bzl@), public provider
-- (from @hs/providers.bzl@), and module extension + tag class (from @hs/extensions.bzl@)
-- is documented with its canonical heading anchor in the generated reference HTML pages.
verifyStarlarkReferenceCoverage :: StarlarkBundle -> FilePath -> IO [String]
verifyStarlarkReferenceCoverage bundle outDir = do
  let rulesHtmlPath = outDir </> "reference" </> "rules.html"
      extProvHtmlPath = outDir </> "reference" </> "extensions-and-providers.html"
  hasRulesPage <- doesFileExist rulesHtmlPath
  hasExtProvPage <- doesFileExist extProvHtmlPath
  if not (hasRulesPage && hasExtProvPage)
    then pure []
    else do
      rulesHtml <- readUtf8File rulesHtmlPath
      extProvHtml <- readUtf8File extProvHtmlPath
      let missingRules =
            [ "Missing public rule #" ++ T.unpack r ++ " in reference/rules.html"
            | r <- sbPublicRules bundle
            , not (("id=\"" <> r <> "\"") `T.isInfixOf` rulesHtml)
            ]
          missingProviders =
            [ "Missing public provider #" ++ T.unpack slug ++ " (" ++ T.unpack pName ++ ") in reference/extensions-and-providers.html"
            | pName <- Map.keys (sbProviders bundle)
            , let slug = T.map toLower pName
            , not (("id=\"" <> slug <> "\"") `T.isInfixOf` extProvHtml)
            ]
          missingExts =
            concat
              [ ( if ("id=\"" <> extName <> "\"") `T.isInfixOf` extProvHtml
                    then []
                    else ["Missing module extension #" ++ T.unpack extName ++ " in reference/extensions-and-providers.html"]
                )
                  ++ [ "Missing extension tag #" ++ T.unpack tagSlug ++ " in reference/extensions-and-providers.html"
                     | tc <- beTags ext
                     , let tagSlug = T.map toLower extName <> "-" <> T.map toLower (btcName tc)
                     , not (("id=\"" <> tagSlug <> "\"") `T.isInfixOf` extProvHtml)
                     ]
              | (extName, ext) <- Map.toAscList (sbExtensions bundle)
              ]
      pure (missingRules ++ missingProviders ++ missingExts)
      where
        _unused = isSpace ' '
