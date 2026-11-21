{-# LANGUAGE OverloadedStrings #-}

-- | Dogfooded Hackage lockfile generator for @rules_hs@.
--
-- Built exclusively with GHC boot libraries (@base@, @Cabal-syntax@,
-- @bytestring@, @containers@, @directory@, @filepath@, @process@, @text@).
-- Resolves a transitive dependency closure against a Stackage snapshot,
-- evaluates every @.cabal@ file across supported platforms via @Cabal-syntax@,
-- verifies Hackage tarball SHA-256 digests, and writes a deterministic
-- @hackage.lock.json@.
module Main (main) where

import CabalExtract
import qualified Data.ByteString as BS
import Data.List (isPrefixOf, nub, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Distribution.Types.Version (Version, mkVersion)
import GHC.IO.Encoding (setLocaleEncoding, utf8)
import LockJson
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize, removeFile, renameFile)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), die, exitSuccess)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

data CliOpts = CliOpts
  { optSnapshot :: !Text
  , optSnapshotYaml :: !(Maybe FilePath)
  , optCabalConfig :: !(Maybe FilePath)
  , optCacheDir :: !FilePath
  , optGhcVersion :: !(Maybe Text)
  , optPackages :: ![Text]
  , optFlags :: !(Map Text (Map Text Bool))
  , optBootPkgs :: !(Map Text Text)
  , optOutput :: !FilePath
  }
  deriving (Show)

defaultOpts :: CliOpts
defaultOpts =
  CliOpts
    { optSnapshot = "lts-24.67"
    , optSnapshotYaml = Nothing
    , optCabalConfig = Nothing
    , optCacheDir = "/tmp/rules_hs_lock_cache"
    , optGhcVersion = Nothing
    , optPackages = []
    , optFlags = Map.empty
    , optBootPkgs = Map.empty
    , optOutput = "hackage.lock.json"
    }

usage :: String
usage =
  unlines
    [ "Usage: lock [OPTIONS]"
    , ""
    , "Generate a deterministic hackage.lock.json from a Stackage snapshot using GHC's Cabal-syntax."
    , ""
    , "Options:"
    , "  --snapshot <name>           Stackage snapshot (default: lts-24.67)"
    , "  --snapshot-yaml <path>      Use a local Stackage snapshot YAML instead of fetching"
    , "  --cabal-config <path>       Use a local Stackage cabal.config for boot packages"
    , "  --cache-dir <dir>           Cache directory for .cabal files & tarballs"
    , "  --ghc-version <ver>         Override GHC version (default: from snapshot)"
    , "  --package <name>            Root Hackage package to include (repeatable)"
    , "  --flag <pkg>:<flag>=<bool>  Override a Cabal flag (repeatable)"
    , "  --boot-pkg <pkg>=<ver>      Add/override a GHC boot package version (repeatable)"
    , "  --output <path>             Output lockfile path (default: hackage.lock.json)"
    , "  -h, --help                  Show this help"
    ]

parseArgs :: [String] -> Either String CliOpts
parseArgs = go defaultOpts
  where
    go opts [] =
      if null (optPackages opts)
        then Left "At least one --package <name> is required."
        else Right opts
    go _ ("-h" : _) = Left usage
    go _ ("--help" : _) = Left usage
    go opts ("--snapshot" : v : rest) = go opts {optSnapshot = T.pack v} rest
    go opts ("--snapshot-yaml" : v : rest) = go opts {optSnapshotYaml = Just v} rest
    go opts ("--cabal-config" : v : rest) = go opts {optCabalConfig = Just v} rest
    go opts ("--cache-dir" : v : rest) = go opts {optCacheDir = v} rest
    go opts ("--ghc-version" : v : rest) = go opts {optGhcVersion = Just (T.pack v)} rest
    go opts ("--package" : v : rest) = go opts {optPackages = optPackages opts ++ [T.pack v]} rest
    go opts ("--output" : v : rest) = go opts {optOutput = v} rest
    go opts ("--flag" : spec : rest) =
      case parseFlagSpec (T.pack spec) of
        Left err -> Left err
        Right (pkg, fl, b) ->
          let inner = Map.findWithDefault Map.empty pkg (optFlags opts)
              updated = Map.insert pkg (Map.insert fl b inner) (optFlags opts)
           in go opts {optFlags = updated} rest
    go opts ("--boot-pkg" : spec : rest) =
      case T.breakOn "=" (T.pack spec) of
        (p, eqv)
          | not (T.null p) && "=" `T.isPrefixOf` eqv ->
              go opts {optBootPkgs = Map.insert p (T.drop 1 eqv) (optBootPkgs opts)} rest
        _ -> Left ("Invalid --boot-pkg spec (expected pkg=ver): " ++ spec)
    go _ (arg : _) = Left ("Unknown or incomplete argument: " ++ arg)

parseFlagSpec :: Text -> Either String (Text, Text, Bool)
parseFlagSpec spec =
  let (pkg, rest1) = T.breakOn ":" spec
      (fl, rest2) = T.breakOn "=" (T.drop 1 rest1)
      val = T.toLower (T.drop 1 rest2)
   in if T.null pkg || T.null rest1 || T.null fl || T.null rest2
        then Left ("Invalid --flag spec (expected pkg:flag=true|false): " ++ T.unpack spec)
        else case val of
          "true" -> Right (pkg, T.toLower fl, True)
          "false" -> Right (pkg, T.toLower fl, False)
          _ -> Left ("Invalid boolean value in --flag: " ++ T.unpack spec)

-- | Exact GHC boot package versions shipped in official bindists.
builtinBootPackages :: Text -> Map Text Text
builtinBootPackages ghcVer
  | "9.10." `T.isPrefixOf` ghcVer =
      Map.fromList
        [ ("Cabal", "3.12.1.0")
        , ("Cabal-syntax", "3.12.1.0")
        , ("array", "0.5.8.0")
        , ("base", "4.20.2.0")
        , ("binary", "0.8.9.3")
        , ("bytestring", "0.12.2.0")
        , ("containers", "0.7")
        , ("deepseq", "1.5.0.0")
        , ("directory", "1.3.8.5")
        , ("exceptions", "0.10.9")
        , ("filepath", "1.5.4.0")
        , ("ghc", ghcVer)
        , ("ghc-bignum", "1.3")
        , ("ghc-boot", ghcVer)
        , ("ghc-boot-th", ghcVer)
        , ("ghc-compact", "0.1.0.0")
        , ("ghc-experimental", "9.1003.0")
        , ("ghc-heap", ghcVer)
        , ("ghc-internal", "9.1003.0")
        , ("ghc-platform", "0.1.0.0")
        , ("ghc-prim", "0.12.0")
        , ("ghc-toolchain", "0.1.0.0")
        , ("ghci", ghcVer)
        , ("haskeline", "0.8.2.1")
        , ("hpc", "0.7.0.2")
        , ("integer-gmp", "1.1")
        , ("mtl", "2.3.1")
        , ("os-string", "2.0.7")
        , ("parsec", "3.1.18.0")
        , ("pretty", "1.1.3.6")
        , ("process", "1.6.26.1")
        , ("rts", "1.0.2")
        , ("semaphore-compat", "1.0.0")
        , ("stm", "2.5.3.1")
        , ("system-cxx-std-lib", "1.0")
        , ("template-haskell", "2.22.0.0")
        , ("terminfo", "0.4.1.7")
        , ("text", "2.1.3")
        , ("time", "1.12.2")
        , ("transformers", "0.6.1.1")
        , ("unix", "2.8.7.0")
        , ("xhtml", "3000.2.2.1")
        ]
  | "9.12." `T.isPrefixOf` ghcVer =
      Map.fromList
        [ ("Cabal", "3.14.1.0")
        , ("Cabal-syntax", "3.14.1.0")
        , ("array", "0.5.8.0")
        , ("base", "4.21.2.0")
        , ("binary", "0.8.9.3")
        , ("bytestring", "0.12.2.0")
        , ("containers", "0.7")
        , ("deepseq", "1.5.1.0")
        , ("directory", "1.3.10.1")
        , ("exceptions", "0.10.9")
        , ("file-io", "0.1.6")
        , ("filepath", "1.5.5.0")
        , ("ghc", ghcVer)
        , ("ghc-bignum", "1.3")
        , ("ghc-boot", ghcVer)
        , ("ghc-boot-th", ghcVer)
        , ("ghc-compact", "0.1.0.0")
        , ("ghc-experimental", "9.1204.0")
        , ("ghc-heap", ghcVer)
        , ("ghc-internal", "9.1204.0")
        , ("ghc-platform", "0.1.0.0")
        , ("ghc-prim", "0.13.0")
        , ("ghc-toolchain", "0.1.0.0")
        , ("ghci", ghcVer)
        , ("haskeline", "0.8.2.1")
        , ("hpc", "0.7.0.2")
        , ("integer-gmp", "1.1")
        , ("mtl", "2.3.2")
        , ("os-string", "2.0.10")
        , ("parsec", "3.1.18.0")
        , ("pretty", "1.1.3.6")
        , ("process", "1.6.26.1")
        , ("rts", "1.0.2")
        , ("semaphore-compat", "1.0.0")
        , ("stm", "2.5.3.1")
        , ("system-cxx-std-lib", "1.0")
        , ("template-haskell", "2.23.0.0")
        , ("terminfo", "0.4.1.7")
        , ("text", "2.1.4")
        , ("time", "1.14")
        , ("transformers", "0.6.3.0")
        , ("unix", "2.8.8.0")
        , ("xhtml", "3000.2.2.1")
        ]
  | otherwise = Map.empty

snapshotYamlUrl :: Text -> String
snapshotYamlUrl snap
  | Just rest <- T.stripPrefix "lts-" snap =
      let (maj, min0) = T.breakOn "." rest
          min' = T.drop 1 min0
       in "https://raw.githubusercontent.com/commercialhaskell/stackage-snapshots/master/lts/"
            ++ T.unpack maj
            ++ "/"
            ++ T.unpack min'
            ++ ".yaml"
  | Just rest <- T.stripPrefix "nightly-" snap =
      let parts = T.splitOn "-" rest
       in "https://raw.githubusercontent.com/commercialhaskell/stackage-snapshots/master/nightly/"
            ++ T.unpack (T.intercalate "/" parts)
            ++ ".yaml"
  | otherwise =
      "https://raw.githubusercontent.com/commercialhaskell/stackage-snapshots/master/" ++ T.unpack snap ++ ".yaml"

cabalConfigUrl :: Text -> String
cabalConfigUrl snap = "https://www.stackage.org/" ++ T.unpack snap ++ "/cabal.config"

fetchUrlToFile :: String -> FilePath -> IO ()
fetchUrlToFile url dest = do
  exists <- doesFileExist dest
  valid <-
    if exists
      then (> 0) <$> getFileSize dest
      else pure False
  if valid
    then pure ()
    else do
      let tmpDest = dest ++ ".tmp"
          curlArgs =
            [ "-fsSL"
            , "--http1.1"
            , "--retry"
            , "5"
            , "--retry-delay"
            , "1"
            , "--retry-all-errors"
            , "-A"
            , "rules_hs-lock/0.1"
            , url
            , "-o"
            , tmpDest
            ]
      (code, _, err) <- readProcessWithExitCode "curl" curlArgs ""
      case code of
        ExitSuccess -> renameFile tmpDest dest
        ExitFailure n -> do
          tmpExists <- doesFileExist tmpDest
          if tmpExists then removeFile tmpDest else pure ()
          die ("curl failed (" ++ show n ++ ") fetching " ++ url ++ ": " ++ err)

computeSha256 :: FilePath -> IO Text
computeSha256 path = do
  (code, out, _) <- readProcessWithExitCode "sha256sum" [path] ""
  case code of
    ExitSuccess -> pure (T.takeWhile (/= ' ') (T.strip (T.pack out)))
    ExitFailure _ -> do
      (code2, out2, err2) <- readProcessWithExitCode "shasum" ["-a", "256", path] ""
      case code2 of
        ExitSuccess -> pure (T.takeWhile (/= ' ') (T.strip (T.pack out2)))
        ExitFailure n -> die ("sha256sum/shasum failed (" ++ show n ++ "): " ++ err2)

-- | List relative file paths inside a Hackage @\<pkg\>-\<ver\>.tar.gz@ tarball.
listTarballFiles :: Text -> FilePath -> IO [Text]
listTarballFiles prefix tbPath = do
  (code, out, err) <- readProcessWithExitCode "tar" ["-tzf", tbPath] ""
  case code of
    ExitSuccess ->
      let pfx = prefix <> "/"
          clean l =
            let t = T.strip l
             in if T.null t || "/" `T.isSuffixOf` t
                  then Nothing
                  else Just (normalizePath (T.unpack (fromMaybe t (T.stripPrefix pfx t))))
       in pure (nub (mapMaybe clean (T.lines (T.pack out))))
    ExitFailure n -> die ("tar -tzf failed (" ++ show n ++ ") on " ++ tbPath ++ ": " ++ err)

-- | Extract a single file from a tarball if present.
readTarballFile :: Text -> FilePath -> Text -> IO (Maybe Text)
readTarballFile prefix tbPath relPath = do
  let fullPath = T.unpack (prefix <> "/" <> relPath)
  (code, out, _) <- readProcessWithExitCode "tar" ["-xOzf", tbPath, fullPath] ""
  case code of
    ExitSuccess -> pure (Just (T.pack out))
    ExitFailure _ -> pure Nothing

-- | Inspect @\<pkg\>.buildinfo@ and @configure.ac@ inside a Configure tarball
-- to discover generated headers added to @install-includes:@ (e.g.
-- @HsNetworkConfig.h@ for @network@, @HsTimeConfig.h@ for @old-time@).
discoverConfigureInstallIncludes :: Text -> Text -> FilePath -> [Text] -> IO [Text]
discoverConfigureInstallIncludes pkgName' prefix tbPath files = do
  let buildinfoFile = pkgName' <> ".buildinfo"
  fromBuildinfo <-
    if buildinfoFile `elem` files
      then maybe [] parseInstallIncludes <$> readTarballFile prefix tbPath buildinfoFile
      else pure []
  fromConfigureAc <-
    if "configure.ac" `elem` files
      then maybe [] parseConfigureAcBuildinfo <$> readTarballFile prefix tbPath "configure.ac"
      else pure []
  pure (sort (nub (fromBuildinfo ++ fromConfigureAc)))
  where
    parseInstallIncludes txt =
      concatMap extractLine (T.lines txt)
    extractLine l =
      case T.stripPrefix "install-includes:" (T.strip l) of
        Just rest -> T.words (T.replace "," " " rest)
        Nothing -> []
    parseConfigureAcBuildinfo txt =
      concat
        [ extractLine (T.strip (T.takeWhile (/= '"') (T.drop 1 afterQuote)))
        | l <- T.lines txt
        , "install-includes:" `T.isInfixOf` l
        , let (_, afterQuote) = T.breakOn "\"" l
        , not (T.null afterQuote)
        ]

parseVersionText :: Text -> Version
parseVersionText t =
  mkVersion $ map parseInt (T.splitOn "." t)
  where
    parseInt s =
      case reads (T.unpack s) of
        [(n, "")] -> n
        _ -> 0

readUtf8File :: FilePath -> IO Text
readUtf8File p = TE.decodeUtf8With TEE.lenientDecode <$> BS.readFile p

writeUtf8File :: FilePath -> Text -> IO ()
writeUtf8File p t = BS.writeFile p (TE.encodeUtf8 t)

removeIfExists :: FilePath -> IO ()
removeIfExists p = do
  ex <- doesFileExist p
  if ex then removeFile p else pure ()

-- | Fetch and SHA-256-verify the exact pinned Hackage @.cabal@ revision for @(pkg, ver)@.
--
-- When @cabalSha@ is present in the Stackage snapshot, caches under an immutable
-- content-addressed filename @\<pkg\>-\<ver\>-\<sha256\>.cabal@. If Hackage's mutable
-- @\<pkg\>.cabal@ endpoint has advanced to a newer @x-revision@, walks backwards
-- through @https://hackage.haskell.org/package/\<pkg\>-\<ver\>/revision/\<r\>.cabal@
-- until the exact @cabalSha@ digest is matched.
fetchVerifiedCabal :: FilePath -> Text -> Text -> Text -> IO FilePath
fetchVerifiedCabal cabalsDir pkg pkgVer cabalSha
  | T.null cabalSha = do
      let dest = cabalsDir </> (T.unpack pkgVer ++ ".cabal")
          url = "https://hackage.haskell.org/package/" ++ T.unpack pkgVer ++ "/" ++ T.unpack pkg ++ ".cabal"
      fetchUrlToFile url dest
      pure dest
  | otherwise = do
      let dest = cabalsDir </> (T.unpack pkgVer ++ "-" ++ T.unpack cabalSha ++ ".cabal")
          legacyDest = cabalsDir </> (T.unpack pkgVer ++ ".cabal")
      destExists <- doesFileExist dest
      if destExists
        then do
          actual <- computeSha256 dest
          if actual == cabalSha
            then pure dest
            else removeFile dest >> fetchFresh dest legacyDest
        else fetchFresh dest legacyDest
  where
    latestUrl = "https://hackage.haskell.org/package/" ++ T.unpack pkgVer ++ "/" ++ T.unpack pkg ++ ".cabal"
    revisionUrl r = "https://hackage.haskell.org/package/" ++ T.unpack pkgVer ++ "/revision/" ++ show r ++ ".cabal"

    fetchFresh dest legacyDest = do
      legacyExists <- doesFileExist legacyDest
      legacyMatches <-
        if legacyExists
          then (== cabalSha) <$> computeSha256 legacyDest
          else pure False
      if legacyMatches
        then do
          BS.readFile legacyDest >>= BS.writeFile dest
          pure dest
        else do
          let probe = dest ++ ".probe"
          removeIfExists probe
          fetchUrlToFile latestUrl probe
          probeSha <- computeSha256 probe
          if probeSha == cabalSha
            then renameFile probe dest >> pure dest
            else do
              probeText <- readUtf8File probe
              let latestRev = parseXRevision probeText
                  candidates =
                    if latestRev > 0
                      then [latestRev - 1, latestRev - 2 .. 0]
                      else [0 .. 10]
              removeIfExists probe
              searchRevisions dest probe probeSha candidates

    parseXRevision txt =
      case [ T.strip rest
           | l <- T.lines txt
           , Just rest <- [T.stripPrefix "x-revision:" (T.toLower (T.strip l))]
           ] of
        (rTxt : _) ->
          case reads (T.unpack rTxt) of
            [(n, "")] -> n
            _ -> 0
        [] -> 0

    searchRevisions dest probe lastSha [] = do
      removeIfExists probe
      die
        ( "SHA-256 mismatch for "
            ++ T.unpack pkgVer
            ++ ".cabal: expected "
            ++ T.unpack cabalSha
            ++ ", latest had "
            ++ T.unpack lastSha
        )
    searchRevisions dest probe _ (r : rs) = do
      removeIfExists probe
      fetchUrlToFile (revisionUrl r) probe
      rSha <- computeSha256 probe
      if rSha == cabalSha
        then renameFile probe dest >> pure dest
        else searchRevisions dest probe rSha rs

main :: IO ()
main = do
  setLocaleEncoding utf8
  args <- getArgs
  opts <- case parseArgs args of
    Left msg
      | "Usage:" `isPrefixOf` msg -> putStrLn msg >> exitSuccess
      | otherwise -> die (msg ++ "\n\n" ++ usage)
    Right o -> pure o

  let cacheDir = optCacheDir opts
      cabalsDir = cacheDir </> "cabals"
      tarballsDir = cacheDir </> "tarballs"
  createDirectoryIfMissing True cabalsDir
  createDirectoryIfMissing True tarballsDir

  -- 1. Load Stackage snapshot YAML
  yamlPath <- case optSnapshotYaml opts of
    Just p -> pure p
    Nothing -> do
      let dest = cacheDir </> (T.unpack (optSnapshot opts) ++ ".yaml")
      hPutStrLn stderr ("Fetching snapshot " ++ T.unpack (optSnapshot opts) ++ "...")
      fetchUrlToFile (snapshotYamlUrl (optSnapshot opts)) dest
      pure dest
  yamlText <- readUtf8File yamlPath
  let snap = parseStackageYaml yamlText

  -- 2. Determine GHC version and boot packages
  let ghcVer = fromMaybe (fromMaybe "9.10.3" (sdCompiler snap)) (optGhcVersion opts)
  cabalCfgBootSet <- case optCabalConfig opts of
    Just p -> parseCabalConfigBootPkgs <$> readUtf8File p
    Nothing -> do
      let dest = cacheDir </> (T.unpack (optSnapshot opts) ++ ".cabal.config")
      exists <- doesFileExist dest
      if exists
        then parseCabalConfigBootPkgs <$> readUtf8File dest
        else do
          fetchUrlToFile (cabalConfigUrl (optSnapshot opts)) dest
          parseCabalConfigBootPkgs <$> readUtf8File dest

  let baseBoots = Map.union (optBootPkgs opts) (builtinBootPackages ghcVer)
      -- Keep all boot packages present in builtinBootPackages or cabal.config
      bootPkgVersions =
        Map.filterWithKey
          (\k _ -> k `Set.member` cabalCfgBootSet || Map.member k (builtinBootPackages ghcVer) || Map.member k (optBootPkgs opts))
          baseBoots
      bootPkgSet = Set.union (Map.keysSet bootPkgVersions) cabalCfgBootSet

      availVersions :: Map Text Version
      availVersions =
        Map.union
          (Map.map parseVersionText bootPkgVersions)
          (Map.map (parseVersionText . spVersion) (sdPackages snap))

  -- 3. Merge Stackage flags with CLI --flag overrides (CLI takes precedence)
  let mergedFlags = Map.unionWith Map.union (optFlags opts) (sdFlags snap)

  -- 4. BFS resolution over the full transitive non-boot dependency closure
  let resolveQueue :: [Text] -> Map Text LockedPackage -> IO (Map Text LockedPackage)
      resolveQueue [] acc = pure acc
      resolveQueue (pkg : queue) acc
        | pkg `Set.member` bootPkgSet || Map.member pkg acc = resolveQueue queue acc
        | otherwise = do
            sp <- case Map.lookup pkg (sdPackages snap) of
              Just x -> pure x
              Nothing -> die ("Package not found in snapshot " ++ T.unpack (optSnapshot opts) ++ ": " ++ T.unpack pkg)
            let ver = spVersion sp
                pkgVer = pkg <> "-" <> ver
                cabalSha = spCabalSha256 sp
                tbUrl = "https://hackage.haskell.org/package/" ++ T.unpack pkgVer ++ "/" ++ T.unpack pkgVer ++ ".tar.gz"
                tbFile = tarballsDir </> (T.unpack pkgVer ++ ".tar.gz")

            cabalFile <- fetchVerifiedCabal cabalsDir pkg pkgVer cabalSha
            fetchUrlToFile tbUrl tbFile

            cabalBytes <- BS.readFile cabalFile
            gpd <- case parseCabalBytes cabalBytes of
              Left err -> die ("Failed to parse " ++ cabalFile ++ ":\n" ++ err)
              Right g -> pure g

            sha <- computeSha256 tbFile
            let pkgFlags = Map.findWithDefault Map.empty pkg mergedFlags

            -- First extract to inspect build-type; for Configure packages also inspect tarball files
            ep0 <- case extractComponentSpecs ghcVer availVersions bootPkgSet pkgFlags [] [] gpd of
              Left err -> die err
              Right x -> pure x

            ep <-
              if epBuildType ep0 == "Configure"
                then do
                  tbFiles <- listTarballFiles pkgVer tbFile
                  extraInst <- discoverConfigureInstallIncludes pkg pkgVer tbFile tbFiles
                  case extractComponentSpecs ghcVer availVersions bootPkgSet pkgFlags tbFiles extraInst gpd of
                    Left err -> die err
                    Right x -> pure x
                else pure ep0

            let locked = extractLockedPackage (T.pack tbUrl) sha ep
                newDeps =
                  [ d
                  | d <- Set.toAscList (epAllNonBootDeps ep)
                  , not (Map.member d acc)
                  , d /= pkg
                  ]
            resolveQueue (queue ++ newDeps) (Map.insert pkg locked acc)

  hPutStrLn stderr ("Resolving closure for " ++ show (map T.unpack (optPackages opts)) ++ " on GHC " ++ T.unpack ghcVer ++ "...")
  lockedPkgs <- resolveQueue (optPackages opts) Map.empty

  let lockFile =
        LockFile
          { lfSchemaVersion = 1
          , lfSnapshot = optSnapshot opts
          , lfGhcVersion = ghcVer
          , lfBootPackages = bootPkgVersions
          , lfPackages = lockedPkgs
          }
      jsonOut = encodePretty (lockFileToJson lockFile)

  writeUtf8File (optOutput opts) jsonOut
  hPutStrLn stderr ("Wrote " ++ optOutput opts ++ " (" ++ show (Map.size lockedPkgs) ++ " Hackage packages, " ++ show (Map.size bootPkgVersions) ++ " boot packages).")
