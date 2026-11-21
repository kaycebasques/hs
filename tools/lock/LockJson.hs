{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic JSON representation and encoder for @hackage.lock.json@.
--
-- Uses only GHC boot libraries (@base@, @containers@, @text@) so the lock
-- generator has zero third-party Hackage dependencies.
module LockJson
  ( JValue (..)
  , encodePretty
  , LockFile (..)
  , LockedPackage (..)
  , ComponentSpec (..)
  , PlatformDelta (..)
  , emptyDelta
  , isDeltaEmpty
  , lockFileToJson
  , componentSpecToJson
  , platformDeltaToJson
  ) where

import Data.Char (ord)
import Data.List (intersperse)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)

-- | Minimal JSON AST.
data JValue
  = JNull
  | JBool !Bool
  | JInt !Int
  | JString !Text
  | JArray ![JValue]
  | JObject ![(Text, JValue)]
  deriving (Eq, Show)

-- | Encode a 'JValue' with deterministic 2-space indentation and trailing newline.
encodePretty :: JValue -> Text
encodePretty val = go 0 val <> "\n"
  where
    indent n = T.replicate (n * 2) " "

    go _ JNull = "null"
    go _ (JBool True) = "true"
    go _ (JBool False) = "false"
    go _ (JInt i) = T.pack (show i)
    go _ (JString s) = encodeString s
    go _ (JArray []) = "[]"
    go lvl (JArray xs) =
      "[\n"
        <> T.concat
          ( intersperse
              ",\n"
              [indent (lvl + 1) <> go (lvl + 1) x | x <- xs]
          )
        <> "\n"
        <> indent lvl
        <> "]"
    go _ (JObject []) = "{}"
    go lvl (JObject kvs) =
      "{\n"
        <> T.concat
          ( intersperse
              ",\n"
              [ indent (lvl + 1) <> encodeString k <> ": " <> go (lvl + 1) v
              | (k, v) <- kvs
              ]
          )
        <> "\n"
        <> indent lvl
        <> "}"

encodeString :: Text -> Text
encodeString t = "\"" <> T.concatMap escapeChar t <> "\""
  where
    escapeChar '"' = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\b' = "\\b"
    escapeChar '\f' = "\\f"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c
      | ord c < 0x20 =
          let hex = showHex (ord c) ""
              pad = replicate (4 - length hex) '0' ++ hex
           in "\\u" <> T.pack pad
      | otherwise = T.singleton c

-- | Platform-specific delta fields layered on top of a component's common fields.
data PlatformDelta = PlatformDelta
  { pdExposedModules :: ![Text]
  , pdOtherModules :: ![Text]
  , pdReexportedModules :: ![Text]
  , pdHsSourceDirs :: ![Text]
  , pdDefaultExtensions :: ![Text]
  , pdGhcOpts :: ![Text]
  , pdCSources :: ![Text]
  , pdIncludeDirs :: ![Text]
  , pdInstallIncludes :: ![Text]
  , pdCppOptions :: ![Text]
  , pdCcOptions :: ![Text]
  , pdExtraLibraries :: ![Text]
  , pdDeps :: ![Text]
  , pdSublibDeps :: ![Text]
  }
  deriving (Eq, Show)

emptyDelta :: PlatformDelta
emptyDelta = PlatformDelta [] [] [] [] [] [] [] [] [] [] [] [] [] []

isDeltaEmpty :: PlatformDelta -> Bool
isDeltaEmpty d = d == emptyDelta

-- | Build metadata for a single Cabal library or internal sublibrary component.
data ComponentSpec = ComponentSpec
  { csExposedModules :: ![Text]
  , csOtherModules :: ![Text]
  , csReexportedModules :: ![Text]
  , csHsSourceDirs :: ![Text]
  , csDefaultLanguage :: !Text
  , csDefaultExtensions :: ![Text]
  , csGhcOpts :: ![Text]
  , csCSources :: ![Text]
  , csIncludeDirs :: ![Text]
  , csInstallIncludes :: ![Text]
  , csCppOptions :: ![Text]
  , csCcOptions :: ![Text]
  , csExtraLibraries :: ![Text]
  , csGeneratePathsModule :: !Bool
  , csDeps :: ![Text]
  , csSublibDeps :: ![Text]
  , csSelect :: !(Map Text PlatformDelta)
  }
  deriving (Eq, Show)

-- | A single pinned Hackage package in the lockfile.
data LockedPackage = LockedPackage
  { lpName :: !Text
  , lpVersion :: !Text
  , lpUrl :: !Text
  , lpSha256 :: !Text
  , lpStripPrefix :: !Text
  , lpCabalRevision :: !Int
  , lpBuildType :: !Text
  , lpConfigureScript :: !Text
  , lpConfigureSrcs :: ![Text]
  , lpConfigureOutputs :: ![Text]
  , lpLibrary :: !(Maybe ComponentSpec)
  , lpSublibraries :: !(Map Text ComponentSpec)
  }
  deriving (Eq, Show)

-- | Top-level @hackage.lock.json@ structure.
data LockFile = LockFile
  { lfSchemaVersion :: !Int
  , lfSnapshot :: !Text
  , lfGhcVersion :: !Text
  , lfBootPackages :: !(Map Text Text)
  , lfPackages :: !(Map Text LockedPackage)
  }
  deriving (Eq, Show)

strArray :: [Text] -> JValue
strArray = JArray . map JString

-- | Encode non-empty fields of a 'PlatformDelta' so lockfiles stay compact.
platformDeltaToJson :: PlatformDelta -> JValue
platformDeltaToJson d =
  JObject $
    concat
      [ nonEmpty "exposed_modules" (pdExposedModules d)
      , nonEmpty "other_modules" (pdOtherModules d)
      , nonEmpty "reexported_modules" (pdReexportedModules d)
      , nonEmpty "hs_source_dirs" (pdHsSourceDirs d)
      , nonEmpty "default_extensions" (pdDefaultExtensions d)
      , nonEmpty "ghc_opts" (pdGhcOpts d)
      , nonEmpty "c_sources" (pdCSources d)
      , nonEmpty "include_dirs" (pdIncludeDirs d)
      , nonEmpty "install_includes" (pdInstallIncludes d)
      , nonEmpty "cpp_options" (pdCppOptions d)
      , nonEmpty "cc_options" (pdCcOptions d)
      , nonEmpty "extra_libraries" (pdExtraLibraries d)
      , nonEmpty "deps" (pdDeps d)
      , nonEmpty "sublib_deps" (pdSublibDeps d)
      ]
  where
    nonEmpty _ [] = []
    nonEmpty k xs = [(k, strArray xs)]

componentSpecToJson :: ComponentSpec -> JValue
componentSpecToJson cs =
  JObject $
    [ ("exposed_modules", strArray (csExposedModules cs))
    , ("other_modules", strArray (csOtherModules cs))
    ]
      ++ optArray "reexported_modules" (csReexportedModules cs)
      ++ [ ("hs_source_dirs", strArray (csHsSourceDirs cs))
         , ("default_language", JString (csDefaultLanguage cs))
         ]
      ++ optArray "default_extensions" (csDefaultExtensions cs)
      ++ optArray "ghc_opts" (csGhcOpts cs)
      ++ optArray "c_sources" (csCSources cs)
      ++ optArray "include_dirs" (csIncludeDirs cs)
      ++ optArray "install_includes" (csInstallIncludes cs)
      ++ optArray "cpp_options" (csCppOptions cs)
      ++ optArray "cc_options" (csCcOptions cs)
      ++ optArray "extra_libraries" (csExtraLibraries cs)
      ++ [ ("generate_paths_module", JBool (csGeneratePathsModule cs))
         , ("deps", strArray (csDeps cs))
         ]
      ++ optArray "sublib_deps" (csSublibDeps cs)
      ++ optSelect (csSelect cs)
  where
    optArray _ [] = []
    optArray k xs = [(k, strArray xs)]
    optSelect m
      | Map.null m = []
      | otherwise =
          [ ( "select"
            , JObject [(plat, platformDeltaToJson delta) | (plat, delta) <- Map.toAscList m]
            )
          ]

lockedPackageToJson :: LockedPackage -> JValue
lockedPackageToJson lp =
  JObject $
    [ ("version", JString (lpVersion lp))
    , ("url", JString (lpUrl lp))
    , ("sha256", JString (lpSha256 lp))
    , ("strip_prefix", JString (lpStripPrefix lp))
    , ("cabal_revision", JInt (lpCabalRevision lp))
    , ("build_type", JString (lpBuildType lp))
    ]
      ++ ( if T.null (lpConfigureScript lp)
             then []
             else
               [ ("configure_script", JString (lpConfigureScript lp))
               , ("configure_srcs", strArray (lpConfigureSrcs lp))
               , ("configure_outputs", strArray (lpConfigureOutputs lp))
               ]
         )
      ++ ( case lpLibrary lp of
             Nothing -> []
             Just lib -> [("library", componentSpecToJson lib)]
         )
      ++ ( if Map.null (lpSublibraries lp)
             then []
             else
               [ ( "sublibraries"
                 , JObject [(k, componentSpecToJson v) | (k, v) <- Map.toAscList (lpSublibraries lp)]
                 )
               ]
         )

lockFileToJson :: LockFile -> JValue
lockFileToJson lf =
  JObject
    [ ("schema_version", JInt (lfSchemaVersion lf))
    , ("snapshot", JString (lfSnapshot lf))
    , ("ghc_version", JString (lfGhcVersion lf))
    , ( "boot_packages"
      , JObject [(k, JString v) | (k, v) <- Map.toAscList (lfBootPackages lf)]
      )
    , ( "packages"
      , JObject [(k, lockedPackageToJson v) | (k, v) <- Map.toAscList (lfPackages lf)]
      )
    ]
