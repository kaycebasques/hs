{-# LANGUAGE OverloadedStrings #-}

-- | Self-contained unit tests for @tools/lock@ (zero network, boot libs only).
module Main (main) where

import CabalExtract
import qualified Data.ByteString.Char8 as BS8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Distribution.Types.Version (Version, mkVersion)
import LockJson
import System.Exit (exitFailure, exitSuccess)

type TestResult = Either String ()

assertEq :: (Eq a, Show a) => String -> a -> a -> TestResult
assertEq label expected actual
  | expected == actual = Right ()
  | otherwise =
      Left $
        label
          ++ "\n  expected: "
          ++ show expected
          ++ "\n  actual:   "
          ++ show actual

assertTrue :: String -> Bool -> TestResult
assertTrue _ True = Right ()
assertTrue label False = Left (label ++ " (expected True, got False)")

availBase :: Map Text Version
availBase =
  Map.fromList
    [ ("base", mkVersion [4, 20, 2, 0])
    , ("bytestring", mkVersion [0, 12, 2, 0])
    , ("containers", mkVersion [0, 7])
    , ("text", mkVersion [2, 1, 3])
    , ("integer-gmp", mkVersion [1, 1])
    , ("zlib-clib", mkVersion [1, 3, 2])
    , ("attoparsec", mkVersion [0, 14, 4])
    , ("crypton-asn1-types", mkVersion [0, 4, 1])
    , ("foo-simple", mkVersion [1, 0, 0])
    ]

bootBase :: Set.Set Text
bootBase = Set.fromList ["base", "bytestring", "containers", "text", "integer-gmp"]

testSimpleAndDefaults :: TestResult
testSimpleAndDefaults = do
  let cabal =
        BS8.unlines
          [ "cabal-version: >= 1.6"
          , "name: foo-simple"
          , "version: 1.0.0"
          , "build-type: Simple"
          , "library"
          , "  exposed-modules: Foo.Bar, Foo.Baz"
          , "  other-modules: Foo.Internal"
          , "  build-depends: base >= 4 && < 5, text"
          , "  default-extensions: OverloadedStrings"
          , "  ghc-options: -Wall -Werror -Werror=missing-fields -O2 -funbox-strict-fields -threaded"
          ]
  gpd <- parseCabalBytes cabal
  ep <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty [] [] gpd
  assertEq "build_type" "Simple" (epBuildType ep)
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  assertEq "default_language fallback" "Haskell98" (csDefaultLanguage lib)
  assertEq "exposed_modules" ["Foo.Bar", "Foo.Baz"] (csExposedModules lib)
  assertEq "other_modules" ["Foo.Internal"] (csOtherModules lib)
  assertEq "hs_source_dirs default" ["."] (csHsSourceDirs lib)
  assertEq "sanitized ghc_opts" ["-O2", "-funbox-strict-fields"] (csGhcOpts lib)
  assertEq "deps" ["base", "text"] (csDeps lib)
  assertTrue "no platform select" (Map.null (csSelect lib))

testFlagOverridesZlib :: TestResult
testFlagOverridesZlib = do
  let cabal =
        BS8.unlines
          [ "cabal-version: >= 1.10"
          , "name: zlib"
          , "version: 0.7.1.1"
          , "build-type: Simple"
          , "flag bundled-c-zlib"
          , "  default: False"
          , "  manual: True"
          , "flag pkg-config"
          , "  default: True"
          , "  manual: False"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: Codec.Compression.GZip"
          , "  include-dirs: cbits-extra"
          , "  c-sources: cbits-extra/hs-zlib.c"
          , "  cpp-options: -DNON_BLOCKING_FFI"
          , "  build-depends: base >= 4.9, bytestring"
          , "  if flag(bundled-c-zlib)"
          , "    build-depends: zlib-clib < 2"
          , "  else"
          , "    extra-libraries: z"
          ]
  gpd <- parseCabalBytes cabal
  let flags = Map.fromList [("bundled-c-zlib", True), ("pkg-config", False)]
  ep <- extractComponentSpecs "9.10.3" availBase bootBase flags [] [] gpd
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  assertEq "deps with bundled-c-zlib" ["base", "bytestring", "zlib-clib"] (csDeps lib)
  assertEq "extra_libraries empty" [] (csExtraLibraries lib)
  assertEq "c_sources" ["cbits-extra/hs-zlib.c"] (csCSources lib)
  assertEq "cpp_options" ["-DNON_BLOCKING_FFI"] (csCppOptions lib)
  assertEq "non-boot deps" (Set.singleton "zlib-clib") (epAllNonBootDeps ep)

testArchAndOsSelect :: TestResult
testArchAndOsSelect = do
  let cabal =
        BS8.unlines
          [ "cabal-version: >= 1.10"
          , "name: crypton-sample"
          , "version: 1.0.6"
          , "build-type: Simple"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: Crypto.Cipher"
          , "  build-depends: base"
          , "  c-sources: cbits/common.c"
          , "  cc-options: -std=gnu99"
          , "  if arch(x86_64)"
          , "    cpp-options: -DARCH_X86_64"
          , "    c-sources: cbits/aes_x86ni.c"
          , "    cc-options: -DWITH_AESNI"
          , "  if os(osx)"
          , "    cpp-options: -DMACOSX"
          ]
  gpd <- parseCabalBytes cabal
  ep <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty [] [] gpd
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  assertEq "common c_sources" ["cbits/common.c"] (csCSources lib)
  assertEq "common cc_options" ["-std=gnu99"] (csCcOptions lib)
  assertEq "common cpp_options" [] (csCppOptions lib)
  let sel = csSelect lib
  lx64 <- maybe (Left "missing linux_x86_64") Right (Map.lookup "linux_x86_64" sel)
  larm <- maybe (Left "missing linux_arm64") Right (Map.lookup "linux_arm64" sel)
  marm <- maybe (Left "missing macos_arm64") Right (Map.lookup "macos_arm64" sel)
  mx64 <- maybe (Left "missing macos_x86_64") Right (Map.lookup "macos_x86_64" sel)
  assertEq "linux_x86_64 c_sources" ["cbits/aes_x86ni.c"] (pdCSources lx64)
  assertEq "linux_x86_64 cpp_options" ["-DARCH_X86_64"] (pdCppOptions lx64)
  assertEq "linux_arm64 c_sources" [] (pdCSources larm)
  assertEq "linux_arm64 cpp_options" [] (pdCppOptions larm)
  assertEq "macos_arm64 cpp_options" ["-DMACOSX"] (pdCppOptions marm)
  assertEq "macos_x86_64 cpp_options" ["-DARCH_X86_64", "-DMACOSX"] (pdCppOptions mx64)

testInternalSublibrary :: TestResult
testInternalSublibrary = do
  let cabal =
        BS8.unlines
          [ "cabal-version: 2.0"
          , "name: attoparsec"
          , "version: 0.14.4"
          , "build-type: Simple"
          , "library attoparsec-internal"
          , "  hs-source-dirs: internal"
          , "  default-language: Haskell2010"
          , "  exposed-modules: Data.Attoparsec.Internal.Buffer"
          , "  build-depends: base, bytestring"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: Data.Attoparsec"
          , "  build-depends: base, bytestring, attoparsec-internal"
          ]
  gpd <- parseCabalBytes cabal
  ep <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty [] [] gpd
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  assertEq "main sublib_deps" ["attoparsec-internal"] (csSublibDeps lib)
  assertEq "main deps excludes internal sublib" ["base", "bytestring"] (csDeps lib)
  sub <- maybe (Left "missing attoparsec-internal") Right (Map.lookup "attoparsec-internal" (epSublibraries ep))
  assertEq "sublib hs_source_dirs" ["internal"] (csHsSourceDirs sub)
  assertEq "sublib exposed" ["Data.Attoparsec.Internal.Buffer"] (csExposedModules sub)

testPathsAndCustomDoctest :: TestResult
testPathsAndCustomDoctest = do
  let cabal =
        BS8.unlines
          [ "cabal-version: 2.0"
          , "name: xml-conduit"
          , "version: 1.10.1.0"
          , "build-type: Custom"
          , "custom-setup"
          , "  setup-depends: base >= 4 && < 5, Cabal < 4, cabal-doctest >= 1 && < 1.1"
          , "library"
          , "  default-language: Haskell2010"
          , "  hs-source-dirs: src"
          , "  exposed-modules: Text.XML"
          , "  other-modules: Paths_xml_conduit, Text.XML.Stream.Token"
          , "  autogen-modules: Paths_xml_conduit"
          , "  build-depends: base, text"
          ]
  gpd <- parseCabalBytes cabal
  ep <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty [] [] gpd
  assertEq "doctest Custom normalized to Simple" "Simple" (epBuildType ep)
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  assertTrue "generate_paths_module" (csGeneratePathsModule lib)
  assertEq "other_modules excludes Paths_" ["Text.XML.Stream.Token"] (csOtherModules lib)

testConfigurePackage :: TestResult
testConfigurePackage = do
  let cabal =
        BS8.unlines
          [ "cabal-version: 1.18"
          , "name: network"
          , "version: 3.2.14.0"
          , "build-type: Configure"
          , "extra-source-files: configure config.guess config.sub install-sh include/HsNetworkConfig.h.in include/HsNet.h"
          , "extra-tmp-files: include/HsNetworkConfig.h network.buildinfo"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: Network.Socket"
          , "  c-sources: cbits/HsNet.c"
          , "  include-dirs: include"
          , "  install-includes: HsNet.h"
          , "  build-depends: base"
          ]
  gpd <- parseCabalBytes cabal
  let tbFiles =
        [ "configure"
        , "config.guess"
        , "config.sub"
        , "install-sh"
        , "include/HsNet.h"
        , "include/HsNetworkConfig.h.in"
        , "cbits/HsNet.c"
        ]
  ep <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty tbFiles ["HsNetworkConfig.h"] gpd
  assertEq "build_type" "Configure" (epBuildType ep)
  assertEq "configure_script" "configure" (epConfigureScript ep)
  assertEq "configure_outputs" ["include/HsNetworkConfig.h"] (epConfigureOutputs ep)
  assertTrue "configure_srcs includes config.sub" ("config.sub" `elem` epConfigureSrcs ep)
  assertTrue "configure_srcs includes HsNetworkConfig.h.in" ("include/HsNetworkConfig.h.in" `elem` epConfigureSrcs ep)
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  assertEq "install_includes includes generated header" ["HsNet.h", "HsNetworkConfig.h"] (csInstallIncludes lib)

testReexportedModules :: TestResult
testReexportedModules = do
  let cabal =
        BS8.unlines
          [ "cabal-version: 1.22"
          , "name: crypton-asn1-encoding"
          , "version: 0.10.0"
          , "build-type: Simple"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: Data.ASN1.Encoding"
          , "  reexported-modules: Data.ASN1.Stream, Data.ASN1.Types"
          , "  build-depends: base, crypton-asn1-types"
          ]
  gpd <- parseCabalBytes cabal
  ep <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty [] [] gpd
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  assertEq "reexported_modules" ["Data.ASN1.Stream", "Data.ASN1.Types"] (csReexportedModules lib)

testStackageYamlParser :: TestResult
testStackageYamlParser = do
  let sample =
        T.unlines
          [ "flags:"
          , "  hashable:"
          , "    arch-native: false"
          , "  zlib:"
          , "    pkg-config: false"
          , "packages:"
          , "- hackage: xml-conduit-1.10.1.0@sha256:0e2416a214a326298df596f255c16acd6da69a9b14d5726c2b8fb7b8156765fe,3058"
          , "- hackage: http-client-tls-0.3.6.4@sha256:bf10c46aa55a41013da7092ce1f6073afa874693d70a5f6e62e977523d13c7d7,2141"
          , "resolver:"
          , "  compiler: ghc-9.10.3"
          ]
      sd = parseStackageYaml sample
  assertEq "compiler" (Just "9.10.3") (sdCompiler sd)
  assertEq "hashable flag" (Just (Map.singleton "arch-native" False)) (Map.lookup "hashable" (sdFlags sd))
  assertEq "zlib flag" (Just (Map.singleton "pkg-config" False)) (Map.lookup "zlib" (sdFlags sd))
  assertEq "xml-conduit version" (Just "1.10.1.0") (spVersion <$> Map.lookup "xml-conduit" (sdPackages sd))
  assertEq "http-client-tls version" (Just "0.3.6.4") (spVersion <$> Map.lookup "http-client-tls" (sdPackages sd))

testJsonEncoding :: TestResult
testJsonEncoding = do
  let obj =
        JObject
          [ ("schema_version", JInt 1)
          , ("escaped", JString "a\"b\\c\nd")
          , ("empty_arr", JArray [])
          , ("flag", JBool True)
          ]
      rendered = encodePretty obj
  assertTrue "contains escaped quotes" ("\"a\\\"b\\\\c\\nd\"" `T.isInfixOf` rendered)
  assertTrue "trailing newline" ("\n" `T.isSuffixOf` rendered)
  assertTrue "compact empty array" ("\"empty_arr\": []" `T.isInfixOf` rendered)

testCxxSourcesAndOldExtensions :: TestResult
testCxxSourcesAndOldExtensions = do
  let cabal =
        BS8.unlines
          [ "cabal-version: 2.2"
          , "name: digest-sample"
          , "version: 0.0.2"
          , "build-type: Simple"
          , "library"
          , "  exposed-modules: Data.Digest.CRC32C"
          , "  extensions: FlexibleInstances"
          , "  cxx-options: -std=c++11"
          , "  cxx-sources: external/crc32c/src/crc32c.cc"
          , "  build-depends: base, bytestring"
          ]
  gpd <- parseCabalBytes cabal
  ep <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty [] [] gpd
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  assertEq "legacy extensions extracted" ["FlexibleInstances"] (csDefaultExtensions lib)
  assertEq "cxx-sources extracted into c_sources" ["external/crc32c/src/crc32c.cc"] (csCSources lib)
  assertEq "cxx-options extracted into cc_options" ["-std=c++11"] (csCcOptions lib)

testCmmSources :: TestResult
testCmmSources = do
  let cabal =
        BS8.unlines
          [ "cabal-version: 3.0"
          , "name: atomic-counter-sample"
          , "version: 0.1.2.4"
          , "build-type: Simple"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: Control.Concurrent.Counter"
          , "  cmm-sources: Counter.cmm"
          , "  build-depends: base"
          ]
  gpd <- parseCabalBytes cabal
  ep <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty [] [] gpd
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  assertEq "cmm-sources extracted into c_sources" ["Counter.cmm"] (csCSources lib)

testMultiTokenFlagsPreserved :: TestResult
testMultiTokenFlagsPreserved = do
  let cabal =
        BS8.unlines
          [ "cabal-version: 2.2"
          , "name: flag-order-pkg"
          , "version: 0.1.0"
          , "build-type: Simple"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: FlagOrder"
          , "  build-depends: base"
          , "  cc-options: -include a.h -include b.h"
          , "  if os(linux)"
          , "    cc-options: -include linux.h -DFOO=1"
          , "  if os(osx)"
          , "    cc-options: -DFOO=1 -include macos.h"
          ]
  gpd <- parseCabalBytes cabal
  ep <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty [] [] gpd
  lib <- maybe (Left "missing library") Right (epLibrary ep)
  -- Repeated "-include" in common prefix must NOT be collapsed by nub, and
  -- per-OS "-include <hdr>" pairs must stay intact in their exact order.
  assertEq "common multi-token cc_options" ["-include", "a.h", "-include", "b.h"] (csCcOptions lib)
  lx64 <- maybe (Left "missing linux_x86_64") Right (Map.lookup "linux_x86_64" (csSelect lib))
  marm <- maybe (Left "missing macos_arm64") Right (Map.lookup "macos_arm64" (csSelect lib))
  assertEq "linux_x86_64 cc_options delta" ["-include", "linux.h", "-DFOO=1"] (pdCcOptions lx64)
  assertEq "macos_arm64 cc_options delta" ["-DFOO=1", "-include", "macos.h"] (pdCcOptions marm)

  -- Also verify trailing two-token flag guard when platforms share "-include" with distinct headers:
  let cabal2 =
        BS8.unlines
          [ "cabal-version: 2.2"
          , "name: flag-guard-pkg"
          , "version: 0.1.0"
          , "build-type: Simple"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: FlagGuard"
          , "  build-depends: base"
          , "  if os(linux)"
          , "    cc-options: -include linux.h"
          , "  if os(osx)"
          , "    cc-options: -include macos.h"
          ]
  gpd2 <- parseCabalBytes cabal2
  ep2 <- extractComponentSpecs "9.10.3" availBase bootBase Map.empty [] [] gpd2
  lib2 <- maybe (Left "missing library") Right (epLibrary ep2)
  assertEq "two-token flag not split into base" [] (csCcOptions lib2)
  lx64_2 <- maybe (Left "missing linux_x86_64") Right (Map.lookup "linux_x86_64" (csSelect lib2))
  assertEq "linux_x86_64 keeps intact -include pair" ["-include", "linux.h"] (pdCcOptions lx64_2)

testPublicAndExternalSublibraries :: TestResult
testPublicAndExternalSublibraries = do
  let availExt = Map.insert "tar" (mkVersion [0, 6, 3, 0]) (Map.insert "my-suite" (mkVersion [1, 0, 0]) availBase)
      -- 1. Package declaring a public sublibrary (unreferenced by main library) that depends on main library
      cabalProducer =
        BS8.unlines
          [ "cabal-version: 3.0"
          , "name: my-suite"
          , "version: 1.0.0"
          , "build-type: Simple"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: MySuite"
          , "  build-depends: base"
          , "library my-suite-pub"
          , "  visibility: public"
          , "  default-language: Haskell2010"
          , "  hs-source-dirs: pub"
          , "  exposed-modules: MySuite.Pub"
          , "  build-depends: base, my-suite"
          ]
  gpdProd <- parseCabalBytes cabalProducer
  epProd <- extractComponentSpecs "9.10.3" availExt bootBase Map.empty [] [] gpdProd
  pubSub <- maybe (Left "missing public sublibrary my-suite-pub") Right (Map.lookup "my-suite-pub" (epSublibraries epProd))
  assertEq "sublib depending on main lib records selfPkg in sublib_deps" ["my-suite"] (csSublibDeps pubSub)

  -- 2. Consumer declaring build-depends: tar:tar-internal
  let cabalConsumer =
        BS8.unlines
          [ "cabal-version: 3.0"
          , "name: conduit-tar-user"
          , "version: 0.1.0"
          , "build-type: Simple"
          , "library"
          , "  default-language: Haskell2010"
          , "  exposed-modules: Conduit.TarUser"
          , "  build-depends: base, tar:tar-internal"
          ]
  gpdCons <- parseCabalBytes cabalConsumer
  epCons <- extractComponentSpecs "9.10.3" availExt bootBase Map.empty [] [] gpdCons
  consLib <- maybe (Left "missing consumer library") Right (epLibrary epCons)
  assertEq "external sublibrary mapped to pkg__sub" ["base", "tar__tar-internal"] (csDeps consLib)
  assertEq "epAllNonBootDeps resolves base package name 'tar'" (Set.singleton "tar") (epAllNonBootDeps epCons)

allTests :: [(String, TestResult)]
allTests =
  [ ("simple_and_defaults", testSimpleAndDefaults)
  , ("flag_overrides_zlib", testFlagOverridesZlib)
  , ("arch_and_os_select", testArchAndOsSelect)
  , ("internal_sublibrary", testInternalSublibrary)
  , ("paths_and_custom_doctest", testPathsAndCustomDoctest)
  , ("configure_package", testConfigurePackage)
  , ("reexported_modules", testReexportedModules)
  , ("cxx_sources_and_old_extensions", testCxxSourcesAndOldExtensions)
  , ("cmm_sources", testCmmSources)
  , ("multi_token_flags_preserved", testMultiTokenFlagsPreserved)
  , ("public_and_external_sublibraries", testPublicAndExternalSublibraries)
  , ("stackage_yaml_parser", testStackageYamlParser)
  , ("json_encoding", testJsonEncoding)
  ]

main :: IO ()
main = do
  let failures = [(n, e) | (n, Left e) <- allTests]
  mapM_ (\(n, _) -> putStrLn ("PASS: " ++ n)) [(n, ()) | (n, Right ()) <- allTests]
  mapM_ (\(n, e) -> putStrLn ("FAIL: " ++ n ++ "\n  " ++ e)) failures
  putStrLn ("Ran " ++ show (length allTests) ++ " tests, " ++ show (length failures) ++ " failed.")
  if null failures then exitSuccess else exitFailure
