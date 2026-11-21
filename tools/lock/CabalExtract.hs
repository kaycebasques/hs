{-# LANGUAGE OverloadedStrings #-}

-- | Pure Cabal @.cabal@ parser and cross-platform metadata extractor using
-- GHC's boot @Cabal-syntax@ library.
module CabalExtract
  ( PlatformKey
  , allPlatforms
  , SnapshotData (..)
  , SnapshotPkg (..)
  , parseStackageYaml
  , parseCabalConfigBootPkgs
  , parseCabalBytes
  , sanitizeGhcOpts
  , extractComponentSpecs
  , extractLockedPackage
  , ExtractedPackage (..)
  , normalizePath
  ) where

import Data.ByteString (ByteString)
import Data.Char (isDigit)
import Data.Foldable (toList)
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Distribution.Compat.NonEmptySet as NES
import Distribution.Compiler (AbiTag (NoAbiTag), CompilerFlavor (GHC), CompilerId (..), CompilerInfo, unknownCompilerInfo)
import Distribution.Fields.ParseResult (runParseResult)
import Distribution.PackageDescription
  ( BuildInfo (..)
  , BuildType (..)
  , GenericPackageDescription (..)
  , Library (..)
  , LibraryName (..)
  , PackageDescription (..)
  , SetupBuildInfo (..)
  , buildType
  , unUnqualComponentName
  )
import Distribution.PackageDescription.Configuration (finalizePD)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription)
import Distribution.Pretty (prettyShow)
import Distribution.System (Arch (..), OS (..), Platform (..))
import Distribution.Types.ComponentRequestedSpec (defaultComponentRequestedSpec)
import Distribution.Types.Dependency (Dependency (..))
import Distribution.Types.Flag (FlagAssignment, mkFlagAssignment, mkFlagName)
import Distribution.Types.LibraryVisibility (LibraryVisibility (..))
import Distribution.Types.ModuleReexport (ModuleReexport (..))
import Distribution.Types.PackageId (pkgName, pkgVersion)
import Distribution.Types.PackageName (unPackageName)
import Distribution.Types.Version (Version, mkVersion)
import Distribution.Types.VersionRange (withinRange)
import Distribution.Utils.Path (getSymbolicPath)
import Distribution.Compiler (PerCompilerFlavor (..))
import LockJson

type PlatformKey = Text

-- | Supported Bazel target platforms evaluated per Hackage package.
allPlatforms :: [(PlatformKey, Platform)]
allPlatforms =
  [ ("linux_x86_64", Platform X86_64 Linux)
  , ("linux_arm64", Platform AArch64 Linux)
  , ("macos_arm64", Platform AArch64 OSX)
  , ("macos_x86_64", Platform X86_64 OSX)
  ]

-- | Entry for one Hackage package inside a Stackage snapshot YAML.
data SnapshotPkg = SnapshotPkg
  { spName :: !Text
  , spVersion :: !Text
  , spCabalSha256 :: !Text
  , spCabalSize :: !Int
  }
  deriving (Eq, Show)

-- | Parsed subset of a Stackage snapshot YAML file.
data SnapshotData = SnapshotData
  { sdCompiler :: !(Maybe Text)
  , sdFlags :: !(Map Text (Map Text Bool))
  , sdPackages :: !(Map Text SnapshotPkg)
  }
  deriving (Eq, Show)

-- | Parse Stackage snapshot YAML (@flags:@, @packages:@, @resolver:@).
--
-- Stackage snapshot YAMLs have a completely regular indentation structure, so
-- this pure parser handles them without needing any external YAML library.
parseStackageYaml :: Text -> SnapshotData
parseStackageYaml content = go "" Nothing (SnapshotData Nothing Map.empty Map.empty) (T.lines content)
  where
    go _ _ acc [] = acc
    go section curPkg acc (rawLine : rest) =
      let line = T.stripEnd rawLine
       in case () of
            _
              | T.null (T.strip line) || "#" `T.isPrefixOf` T.stripStart line ->
                  go section curPkg acc rest
              | not (" " `T.isPrefixOf` line) && not ("-" `T.isPrefixOf` line) && ":" `T.isInfixOf` line ->
                  let (k, v0) = T.breakOn ":" line
                      v = T.strip (T.drop 1 v0)
                   in if k == "resolver" && not (T.null v)
                        then go k Nothing acc {sdCompiler = extractCompiler v} rest
                        else go k Nothing acc rest
              | section == "resolver" ->
                  let stripped = T.strip line
                   in if "compiler:" `T.isPrefixOf` stripped
                        then
                          let comp = T.strip (T.drop (T.length "compiler:") stripped)
                           in go section curPkg acc {sdCompiler = extractCompiler comp} rest
                        else go section curPkg acc rest
              | section == "flags" ->
                  case parseFlagLine line curPkg of
                    Just (Left pkgName') ->
                      go section (Just pkgName') acc rest
                    Just (Right (pkgName', flagName', flagVal')) ->
                      let inner = Map.findWithDefault Map.empty pkgName' (sdFlags acc)
                          updated = Map.insert pkgName' (Map.insert flagName' flagVal' inner) (sdFlags acc)
                       in go section curPkg acc {sdFlags = updated} rest
                    Nothing ->
                      go section curPkg acc rest
              | section == "packages" ->
                  case parseHackageLine line of
                    Just sp ->
                      go section Nothing acc {sdPackages = Map.insert (spName sp) sp (sdPackages acc)} rest
                    Nothing ->
                      go section curPkg acc rest
              | otherwise ->
                  go section curPkg acc rest

    extractCompiler t =
      let cleaned = T.strip (T.filter (/= '"') (T.filter (/= '\'') t))
       in T.stripPrefix "ghc-" cleaned

    parseFlagLine line curPkg
      | "    " `T.isPrefixOf` line =
          case curPkg of
            Nothing -> Nothing
            Just p ->
              let (fk, fv0) = T.breakOn ":" (T.strip line)
                  fv = T.toLower (T.strip (T.drop 1 fv0))
               in case fv of
                    "true" -> Just (Right (p, T.toLower (T.strip fk), True))
                    "false" -> Just (Right (p, T.toLower (T.strip fk), False))
                    _ -> Nothing
      | "  " `T.isPrefixOf` line && ":" `T.isSuffixOf` T.stripEnd line =
          let p = T.dropEnd 1 (T.strip line)
           in Just (Left p)
      | otherwise = Nothing

    parseHackageLine line =
      let stripped = T.strip line
       in case T.stripPrefix "- hackage:" stripped of
            Nothing ->
              case T.stripPrefix "hackage:" stripped of
                Nothing -> Nothing
                Just rest' -> parseHackageSpec (T.strip rest')
            Just rest' -> parseHackageSpec (T.strip rest')

    -- Format: "<pkg>-<ver>@sha256:<hex>,<size>"
    parseHackageSpec spec =
      let (pkgVer, hashPart) = T.breakOn "@sha256:" spec
       in if T.null hashPart
            then Nothing
            else
              let afterHash = T.drop (T.length "@sha256:") hashPart
                  (sha, sizePart) = T.breakOn "," afterHash
                  sz = maybe 0 id (readMaybeInt (T.drop 1 sizePart))
               in case splitPkgVersion pkgVer of
                    Just (pn, pv) -> Just (SnapshotPkg pn pv sha sz)
                    Nothing -> Nothing

-- | Split @"http-client-tls-0.3.6.4"@ into @("http-client-tls", "0.3.6.4")@.
splitPkgVersion :: Text -> Maybe (Text, Text)
splitPkgVersion t =
  let parts = T.splitOn "-" t
   in case reverse parts of
        (v : revName)
          | not (null revName) && isVersionToken v ->
              Just (T.intercalate "-" (reverse revName), v)
        _ -> Nothing
  where
    isVersionToken s =
      not (T.null s) && T.all (\c -> isDigit c || c == '.') s && isDigit (T.head s)

readMaybeInt :: Text -> Maybe Int
readMaybeInt t =
  let s = T.unpack (T.strip t)
   in case reads s of
        [(n, "")] -> Just n
        _ -> Nothing

-- | Parse @"<pkg> installed"@ entries from a Stackage @cabal.config@.
parseCabalConfigBootPkgs :: Text -> Set Text
parseCabalConfigBootPkgs content =
  Set.fromList $
    "rts" : mapMaybe parseLine (T.lines content)
  where
    parseLine raw =
      let trimmed = T.strip (T.dropWhile (== ',') (T.strip raw))
          noComma = T.dropWhileEnd (== ',') trimmed
       in case T.words noComma of
            ["constraints:", p, "installed"] -> Just p
            [p, "installed"] -> Just p
            _ -> Nothing

-- | Parse raw @.cabal@ bytes using @Cabal-syntax@.
parseCabalBytes :: ByteString -> Either String GenericPackageDescription
parseCabalBytes bs =
  case runParseResult (parseGenericPackageDescription bs) of
    (_, Left (_, errs)) -> Left (unlines (map show (toList errs)))
    (_, Right gpd) -> Right gpd

-- | Parse a dotted version string into a Cabal 'Version'.
parseVersionText :: Text -> Version
parseVersionText t =
  mkVersion $ map (fromMaybe 0 . readMaybeInt) (T.splitOn "." t)

-- | Normalize a relative file path (strip leading @"./"@, collapse redundant slashes).
normalizePath :: FilePath -> Text
normalizePath p =
  let t0 = T.replace "\\" "/" (T.pack p)
      t1 = stripDotSlash t0
   in if T.null t1 then "." else t1
  where
    stripDotSlash s =
      case T.stripPrefix "./" s of
        Just s' -> stripDotSlash s'
        Nothing -> s

-- | Sanitize @ghc-options@ for third-party Hackage builds.
--
-- Strips warning flags (including @-Werror@ and @-Wall@) and link-only flags
-- like @-threaded@ while preserving optimization and semantic codegen flags
-- (@-O2@, @-funbox-strict-fields@, @-fno-cse@, @-optc-O3@, etc.).
sanitizeGhcOpts :: [Text] -> [Text]
sanitizeGhcOpts = filter keepOpt
  where
    keepOpt opt
      | opt == "-Werror" || "-Werror=" `T.isPrefixOf` opt = False
      | "-W" `T.isPrefixOf` opt = False
      | "-fwarn-" `T.isPrefixOf` opt || "-fno-warn-" `T.isPrefixOf` opt = False
      | opt `elem` ["-w", "-threaded", "-rtsopts", "-fllvm", "-ferror-spans"] = False
      | "-with-rtsopts=" `T.isPrefixOf` opt = False
      | otherwise = True

-- | Intermediate extraction result before URL/SHA-256 enrichment.
data ExtractedPackage = ExtractedPackage
  { epName :: !Text
  , epVersion :: !Text
  , epCabalRevision :: !Int
  , epBuildType :: !Text
  , epConfigureScript :: !Text
  , epConfigureSrcs :: ![Text]
  , epConfigureOutputs :: ![Text]
  , epLibrary :: !(Maybe ComponentSpec)
  , epSublibraries :: !(Map Text ComponentSpec)
  , epAllNonBootDeps :: !(Set Text)
  }
  deriving (Eq, Show)

-- | Raw per-platform extracted fields for a single library/sublibrary component.
data RawComp = RawComp
  { rcExposedModules :: ![Text]
  , rcOtherModules :: ![Text]
  , rcReexportedModules :: ![Text]
  , rcHsSourceDirs :: ![Text]
  , rcDefaultLanguage :: !Text
  , rcDefaultExtensions :: ![Text]
  , rcGhcOpts :: ![Text]
  , rcCSources :: ![Text]
  , rcIncludeDirs :: ![Text]
  , rcInstallIncludes :: ![Text]
  , rcCppOptions :: ![Text]
  , rcCcOptions :: ![Text]
  , rcExtraLibraries :: ![Text]
  , rcGeneratePaths :: !Bool
  , rcDeps :: ![Text]
  , rcSublibDeps :: ![Text]
  }
  deriving (Eq, Show)

-- | Extract cross-platform 'ComponentSpec's and Configure/Custom metadata
-- from a parsed 'GenericPackageDescription'.
extractComponentSpecs
  :: Text
  -- ^ GHC version string (e.g. @"9.10.3"@)
  -> Map Text Version
  -- ^ All available package versions (snapshot + boot)
  -> Set Text
  -- ^ Boot package names
  -> Map Text Bool
  -- ^ Explicit flag overrides for this package
  -> [Text]
  -- ^ Optional extra tarball file paths (for Configure discovery; empty in pure tests)
  -> [Text]
  -- ^ Optional extra @install-includes@ discovered from @.buildinfo@ / @configure.ac@
  -> GenericPackageDescription
  -> Either String ExtractedPackage
extractComponentSpecs ghcVerText availVersions bootPkgs flagOverrides tarballFiles extraInstIncludes gpd = do
  let pkgId = package (packageDescription gpd)
      pName = T.pack (unPackageName (pkgName pkgId))
      pVer = T.pack (prettyShow (pkgVersion pkgId))
      pIdent = T.replace "-" "_" pName
      pathsModName = "Paths_" <> pIdent
      compilerInfo = unknownCompilerInfo (CompilerId GHC (parseVersionText ghcVerText)) NoAbiTag
      explicitFlags =
        mkFlagAssignment
          [(mkFlagName (T.unpack k), v) | (k, v) <- Map.toList flagOverrides]

      evalForPlatform (pkey, plat) = do
        pd <- finalizeForPlatform explicitFlags availVersions plat compilerInfo gpd
        pure (pkey, pd)

  perPlat <- mapM evalForPlatform allPlatforms

  repPd <- case perPlat of
    ((_, pd) : _) -> Right pd
    [] -> Left "allPlatforms is empty"
  let cabalRev = extractRevision gpd
      (btText, cfgScript, cfgSrcs, cfgOutputs, cfgExtraInst) =
        classifyBuildType repPd tarballFiles extraInstIncludes

      -- Determine sublibrary names declared in the package
      sublibNames =
        sort . nub $
          [ T.pack (unUnqualComponentName uq)
          | (_, pd) <- perPlat
          , lib <- subLibraries pd
          , LSubLibName uq <- [libName lib]
          ]
      sublibNameSet = Set.fromList sublibNames

      -- Extract main library across all 4 platforms
      mainPerPlat =
        [ (pk, extractRawComp pName pathsModName sublibNameSet cfgExtraInst lib)
        | (pk, pd) <- perPlat
        , Just lib <- [library pd]
        , buildable (libBuildInfo lib)
        ]
      mainSpec =
        if null mainPerPlat
          then Nothing
          else Just (mergeRawComps mainPerPlat)

      -- Collect public sublibraries and internal sublibraries referenced by the main library (transitively)
      publicSublibs =
        Set.fromList
          [ T.pack (unUnqualComponentName uq)
          | (_, pd) <- perPlat
          , lib <- subLibraries pd
          , LSubLibName uq <- [libName lib]
          , libVisibility lib == LibraryVisibilityPublic
          , buildable (libBuildInfo lib)
          ]
      referencedSublibs =
        let directRefs = case mainSpec of
              Nothing -> publicSublibs
              Just ms ->
                publicSublibs
                  `Set.union` Set.fromList (csSublibDeps ms)
                  `Set.union` Set.unions [Set.fromList (pdSublibDeps d) | d <- Map.elems (csSelect ms)]
         in expandSublibs (Set.intersection directRefs sublibNameSet) perPlat pName pathsModName sublibNameSet

      sublibSpecs =
        Map.fromList
          [ (sname, mergeRawComps comps)
          | sname <- Set.toAscList referencedSublibs
          , let comps =
                  [ (pk, extractRawComp pName pathsModName sublibNameSet [] lib)
                  | (pk, pd) <- perPlat
                  , lib <- subLibraries pd
                  , LSubLibName uq <- [libName lib]
                  , T.pack (unUnqualComponentName uq) == sname
                  , buildable (libBuildInfo lib)
                  ]
          , not (null comps)
          ]

      allDeps =
        Set.unions $
          maybe [] (collectComponentDeps bootPkgs pName) mainSpec
            ++ concatMap (collectComponentDeps bootPkgs pName) (Map.elems sublibSpecs)

  pure
    ExtractedPackage
      { epName = pName
      , epVersion = pVer
      , epCabalRevision = cabalRev
      , epBuildType = btText
      , epConfigureScript = cfgScript
      , epConfigureSrcs = cfgSrcs
      , epConfigureOutputs = cfgOutputs
      , epLibrary = mainSpec
      , epSublibraries = sublibSpecs
      , epAllNonBootDeps = allDeps
      }

extractRevision :: GenericPackageDescription -> Int
extractRevision gpd =
  case lookup "x-revision" (customFieldsPD (packageDescription gpd)) of
    Just s -> fromMaybe 0 (readMaybeInt (T.pack s))
    Nothing -> 0

finalizeForPlatform
  :: FlagAssignment
  -> Map Text Version
  -> Platform
  -> CompilerInfo
  -> GenericPackageDescription
  -> Either String PackageDescription
finalizeForPlatform explicitFlags availVersions plat compInfo gpd =
  -- Pass 1: strict version-range matching against available snapshot/boot packages.
  -- Pass 2 (fallback for Stackage allow-newer bounds): accept any package present in
  -- availVersions while still rejecting absent packages and pre-0.10 bytestring checks.
  case finalizePD explicitFlags defaultComponentRequestedSpec strictCheck plat compInfo [] gpd of
    Right (pd, _) -> Right pd
    Left _ ->
      case finalizePD explicitFlags defaultComponentRequestedSpec relaxedCheck plat compInfo [] gpd of
        Right (pd, _) -> Right pd
        Left missing ->
          Left $
            "finalizePD failed for "
              ++ prettyShow (pkgName (package (packageDescription gpd)))
              ++ " on "
              ++ prettyShow plat
              ++ ": missing "
              ++ show (map prettyShow missing)
  where
    strictCheck (Dependency pn vr _) =
      case Map.lookup (T.pack (unPackageName pn)) availVersions of
        Just v -> withinRange v vr
        Nothing -> False
    relaxedCheck (Dependency pn vr _) =
      let name = T.pack (unPackageName pn)
       in case Map.lookup name availVersions of
            Just v
              | name == "bytestring" -> withinRange v vr
              | otherwise -> True
            Nothing -> False

classifyBuildType :: PackageDescription -> [Text] -> [Text] -> (Text, Text, [Text], [Text], [Text])
classifyBuildType pd tarballFiles extraInstIncludes =
  case buildType pd of
    Configure ->
      let extraTmp = map normalizePath (extraTmpFiles pd)
          extraSrc = map normalizePath (extraSrcFiles pd)
          allKnown =
            if null tarballFiles
              then filter (not . ("*" `T.isInfixOf`)) extraSrc
              else tarballFiles
          -- Outputs: .h files in extra-tmp-files, or *.h.in stripped of ".in"
          tmpHeaders = filter (".h" `T.isSuffixOf`) extraTmp
          inHeaders = mapMaybe (T.stripSuffix ".in") (filter (".h.in" `T.isSuffixOf`) allKnown)
          outputs = sort (nub (if null tmpHeaders then inHeaders else tmpHeaders))
          -- Configure inputs: autoconf helper scripts, *.h.in, *.buildinfo, plus headers/cbits referenced by AC_INIT/AC_CONFIG_SRCDIR
          isCfgSrc f =
            f `elem` ["configure", "config.guess", "config.sub", "install-sh", "aclocal.m4", "configure.ac"]
              || ".h.in" `T.isSuffixOf` f
              || ".buildinfo" `T.isSuffixOf` f
              || (".h" `T.isSuffixOf` f && ("include/" `T.isPrefixOf` f || "cbits/" `T.isPrefixOf` f))
              || f `elem` ["cbits/conv.c"]
          srcs = sort (nub (filter isCfgSrc allKnown))
          script = if "configure" `elem` allKnown || null tarballFiles then "configure" else "configure"
       in ("Configure", script, srcs, outputs, sort (nub extraInstIncludes))
    Custom ->
      let setupDeps =
            case setupBuildInfo pd of
              Nothing -> []
              Just sbi -> [T.pack (unPackageName pn) | Dependency pn _ _ <- setupDepends sbi]
          isDoctestOnly =
            not (null setupDeps)
              && all (`elem` ["base", "Cabal", "Cabal-syntax", "cabal-doctest", "filepath", "directory"]) setupDeps
       in if isDoctestOnly
            then ("Simple", "", [], [], [])
            else ("Custom", "", [], [], [])
    _ -> ("Simple", "", [], [], [])

extractRawComp :: Text -> Text -> Set Text -> [Text] -> Library -> RawComp
extractRawComp selfPkg pathsModName selfSublibs extraInst lib =
  let bi = libBuildInfo lib
      exposed = sort . nub $ map (T.pack . prettyShow) (exposedModules lib)
      otherAll = map (T.pack . prettyShow) (otherModules bi)
      autogenAll = map (T.pack . prettyShow) (autogenModules bi)
      genPaths = pathsModName `elem` (otherAll ++ autogenAll)
      -- Keep non-Paths other_modules sorted & deduplicated; Paths_<pkg> is generated by generate_paths_module
      otherClean = sort . nub $ filter (/= pathsModName) (otherAll ++ autogenAll)
      reexported = sort . nub $ map formatReexport (reexportedModules lib)
      srcDirs0 = map (normalizePath . getSymbolicPath) (hsSourceDirs bi)
      srcDirs = if null srcDirs0 then ["."] else nub srcDirs0
      defLang = maybe "Haskell98" (T.pack . prettyShow) (defaultLanguage bi)
      defExts = sort . nub $ map (T.pack . prettyShow) (defaultExtensions bi ++ oldExtensions bi)
      PerCompilerFlavor ghcOptsRaw _ = options bi
      ghcOpts = sanitizeGhcOpts (map T.pack ghcOptsRaw)
      cSrcs = nub $ map normalizePath (cSources bi ++ cxxSources bi ++ asmSources bi)
      incDirs = nub $ map normalizePath (includeDirs bi)
      instIncs = sort . nub $ map normalizePath (installIncludes bi) ++ extraInst
      cppOpts = map T.pack (cppOptions bi)
      ccOpts = map T.pack (ccOptions bi ++ cxxOptions bi)
      extLibs = map T.pack (extraLibs bi)
      (deps, subDeps) = extractDeps selfPkg selfSublibs (targetBuildDepends bi)
   in RawComp
        { rcExposedModules = exposed
        , rcOtherModules = otherClean
        , rcReexportedModules = reexported
        , rcHsSourceDirs = srcDirs
        , rcDefaultLanguage = defLang
        , rcDefaultExtensions = defExts
        , rcGhcOpts = ghcOpts
        , rcCSources = cSrcs
        , rcIncludeDirs = incDirs
        , rcInstallIncludes = instIncs
        , rcCppOptions = cppOpts
        , rcCcOptions = ccOpts
        , rcExtraLibraries = extLibs
        , rcGeneratePaths = genPaths
        , rcDeps = sort (nub deps)
        , rcSublibDeps = sort (nub subDeps)
        }

formatReexport :: ModuleReexport -> Text
formatReexport mr =
  let origMod = T.pack (prettyShow (moduleReexportOriginalName mr))
      newMod = T.pack (prettyShow (moduleReexportName mr))
      origRef =
        case moduleReexportOriginalPackage mr of
          Nothing -> origMod
          Just pn -> T.pack (unPackageName pn) <> ":" <> origMod
   in if origMod == newMod && moduleReexportOriginalPackage mr == Nothing
        then newMod
        else origRef <> " as " <> newMod

extractDeps :: Text -> Set Text -> [Dependency] -> ([Text], [Text])
extractDeps selfPkg selfSublibs = foldl' step ([], [])
  where
    step (ds, ss) (Dependency pn _ libNames) =
      let p = T.pack (unPackageName pn)
          lns = NES.toList libNames
       in if p == selfPkg
            then
              let subs =
                    [ case ln of
                        LSubLibName uq -> T.pack (unUnqualComponentName uq)
                        LMainLibName -> selfPkg
                    | ln <- lns
                    ]
               in (ds, ss ++ subs)
            else
              -- Handle Cabal 2.0 unqualified internal sublib syntax where a dep name matches a local sublib
              if p `Set.member` selfSublibs && lns == [LMainLibName]
                then (ds, ss ++ [p])
                else
                  let extTargets =
                        [ case ln of
                            LSubLibName uq -> p <> "__" <> T.pack (unUnqualComponentName uq)
                            LMainLibName -> p
                        | ln <- lns
                        ]
                   in (ds ++ extTargets, ss)

expandSublibs
  :: Set Text
  -> [(PlatformKey, PackageDescription)]
  -> Text
  -> Text
  -> Set Text
  -> Set Text
expandSublibs initial perPlat selfPkg pathsMod selfSublibs = go initial initial
  where
    go seen frontier
      | Set.null frontier = seen
      | otherwise =
          let next =
                Set.fromList
                  [ subDep
                  | (_, pd) <- perPlat
                  , lib <- subLibraries pd
                  , LSubLibName uq <- [libName lib]
                  , T.pack (unUnqualComponentName uq) `Set.member` frontier
                  , let rc = extractRawComp selfPkg pathsMod selfSublibs [] lib
                  , subDep <- rcSublibDeps rc
                  , subDep `Set.member` selfSublibs
                  , not (subDep `Set.member` seen)
                  ]
           in go (seen `Set.union` next) next

-- | Merge per-platform 'RawComp's into common base fields + minimal per-platform deltas.
mergeRawComps :: [(PlatformKey, RawComp)] -> ComponentSpec
mergeRawComps perPlat =
  let (expBase, expDelta) = splitField rcExposedModules
      (othBase, othDelta) = splitField rcOtherModules
      (reexBase, reexDelta) = splitField rcReexportedModules
      (dirBase, dirDelta) = splitField rcHsSourceDirs
      (extBase, extDelta) = splitField rcDefaultExtensions
      (ghcBase, ghcDelta) = splitOrderedFlags rcGhcOpts
      (csrcBase, csrcDelta) = splitField rcCSources
      (incBase, incDelta) = splitField rcIncludeDirs
      (instBase, instDelta) = splitField rcInstallIncludes
      (cppBase, cppDelta) = splitOrderedFlags rcCppOptions
      (ccBase, ccDelta) = splitOrderedFlags rcCcOptions
      (elibBase, elibDelta) = splitField rcExtraLibraries
      (depBase, depDelta) = splitField rcDeps
      (subBase, subDelta) = splitField rcSublibDeps

      defLang = case perPlat of
        ((_, rc) : _) -> rcDefaultLanguage rc
        [] -> "Haskell98"
      genPaths = any (rcGeneratePaths . snd) perPlat

      rawSelect =
        Map.fromList
          [ (pk, delta)
          | (pk, _) <- perPlat
          , let delta =
                  PlatformDelta
                    { pdExposedModules = Map.findWithDefault [] pk expDelta
                    , pdOtherModules = Map.findWithDefault [] pk othDelta
                    , pdReexportedModules = Map.findWithDefault [] pk reexDelta
                    , pdHsSourceDirs = Map.findWithDefault [] pk dirDelta
                    , pdDefaultExtensions = Map.findWithDefault [] pk extDelta
                    , pdGhcOpts = Map.findWithDefault [] pk ghcDelta
                    , pdCSources = Map.findWithDefault [] pk csrcDelta
                    , pdIncludeDirs = Map.findWithDefault [] pk incDelta
                    , pdInstallIncludes = Map.findWithDefault [] pk instDelta
                    , pdCppOptions = Map.findWithDefault [] pk cppDelta
                    , pdCcOptions = Map.findWithDefault [] pk ccDelta
                    , pdExtraLibraries = Map.findWithDefault [] pk elibDelta
                    , pdDeps = Map.findWithDefault [] pk depDelta
                    , pdSublibDeps = Map.findWithDefault [] pk subDelta
                    }
          ]
      selectMap =
        if all isDeltaEmpty (Map.elems rawSelect)
          then Map.empty
          else rawSelect
   in ComponentSpec
        { csExposedModules = expBase
        , csOtherModules = othBase
        , csReexportedModules = reexBase
        , csHsSourceDirs = dirBase
        , csDefaultLanguage = defLang
        , csDefaultExtensions = extBase
        , csGhcOpts = ghcBase
        , csCSources = csrcBase
        , csIncludeDirs = incBase
        , csInstallIncludes = instBase
        , csCppOptions = cppBase
        , csCcOptions = ccBase
        , csExtraLibraries = elibBase
        , csGeneratePathsModule = genPaths
        , csDeps = depBase
        , csSublibDeps = subBase
        , csSelect = selectMap
        }
  where
    splitField :: (RawComp -> [Text]) -> ([Text], Map PlatformKey [Text])
    splitField getter =
      let lists = [(pk, getter rc) | (pk, rc) <- perPlat]
          sets = [Set.fromList xs | (_, xs) <- lists]
          commonSet =
            case sets of
              [] -> Set.empty
              (s : ss) -> foldl' Set.intersection s ss
          -- Preserve deterministic order from first platform
          firstList = case lists of
            ((_, xs) : _) -> xs
            [] -> []
          base = filter (`Set.member` commonSet) firstList
          deltas =
            Map.fromList
              [ (pk, filter (`Set.notMember` commonSet) xs)
              | (pk, xs) <- lists
              ]
       in (base, deltas)

    -- Preserve exact token order and multi-token flag pairs (e.g. -include foo.h)
    -- across base + select({...}) for compiler option lists.
    splitOrderedFlags :: (RawComp -> [Text]) -> ([Text], Map PlatformKey [Text])
    splitOrderedFlags getter =
      let lists = [(pk, getter rc) | (pk, rc) <- perPlat]
          allLists = map snd lists
          rawPrefix =
            case allLists of
              [] -> []
              (xs0 : rest) -> foldl' commonPrefix xs0 rest
          maxLen = maximum (0 : map length allLists)
          base =
            if length rawPrefix < maxLen && not (null rawPrefix) && isTwoTokenFlag (last rawPrefix)
              then init rawPrefix
              else rawPrefix
          baseLen = length base
          deltas = Map.fromList [(pk, drop baseLen xs) | (pk, xs) <- lists]
       in (base, deltas)

    commonPrefix :: Eq a => [a] -> [a] -> [a]
    commonPrefix (x : xs) (y : ys)
      | x == y = x : commonPrefix xs ys
    commonPrefix _ _ = []

    isTwoTokenFlag :: Text -> Bool
    isTwoTokenFlag tok =
      tok
        `elem` [ "-include"
               , "-imacros"
               , "-isystem"
               , "-iquote"
               , "-idirafter"
               , "-iprefix"
               , "-iwithprefix"
               , "-I"
               , "-D"
               , "-U"
               , "-L"
               , "-l"
               , "-x"
               , "-o"
               , "-MF"
               , "-MT"
               , "-MQ"
               , "-framework"
               , "-arch"
               , "-isysroot"
               , "-Xlinker"
               , "-Xpreprocessor"
               , "-Xclang"
               , "-optc"
               , "-optP"
               , "-optl"
               , "-opta"
               , "-package"
               , "-package-id"
               , "-main-is"
               , "-pgmP"
               , "-pgmc"
               , "-pgml"
               ]

collectComponentDeps :: Set Text -> Text -> ComponentSpec -> [Set Text]
collectComponentDeps bootPkgs selfPkg cs =
  [ Set.fromList (filter isExt (map basePkgName (csDeps cs)))
  , Set.unions [Set.fromList (filter isExt (map basePkgName (pdDeps d))) | d <- Map.elems (csSelect cs)]
  ]
  where
    basePkgName d = fst (T.breakOn "__" d)
    isExt p = p /= selfPkg && not (p `Set.member` bootPkgs) && p /= "Win32"

-- | Enrich an 'ExtractedPackage' with tarball URL and verified SHA-256 into a 'LockedPackage'.
extractLockedPackage :: Text -> Text -> ExtractedPackage -> LockedPackage
extractLockedPackage url sha ep =
  LockedPackage
    { lpName = epName ep
    , lpVersion = epVersion ep
    , lpUrl = url
    , lpSha256 = sha
    , lpStripPrefix = epName ep <> "-" <> epVersion ep
    , lpCabalRevision = epCabalRevision ep
    , lpBuildType = epBuildType ep
    , lpConfigureScript = epConfigureScript ep
    , lpConfigureSrcs = epConfigureSrcs ep
    , lpConfigureOutputs = epConfigureOutputs ep
    , lpLibrary = epLibrary ep
    , lpSublibraries = epSublibraries ep
    }
