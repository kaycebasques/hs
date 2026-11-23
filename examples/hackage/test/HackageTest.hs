{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Codec.Archive.Tar.Check.Internal (FileNameError (..))
import Codec.Archive.Tar.Entry (entryPath, fileEntry, toTarPath)
import Codec.Compression.GZip qualified as GZip
import Conduit (runConduitRes, sinkList, (.|))
import Control.Monad (unless)
import Data.Attoparsec.ByteString.FastSet (charClass, memberChar)
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List.Split (splitOn)
import Data.UnixTime (fromEpochTime, toEpochTime)
import Network.Socket (Family (AF_INET), tupleToHostAddress)
import System.Console.ANSI (SGR (Reset), setSGRCode)
import System.Exit (exitFailure)
import Text.Libyaml qualified as Yaml
import Text.Show.Pretty (parseValue)
import Text.XML (Document (..), Element (..), Name (..), def, parseLBS)

assertTrue :: String -> Bool -> IO ()
assertTrue label cond =
  unless cond $ do
    putStrLn ("FAIL: " ++ label)
    exitFailure

main :: IO ()
main = do
  -- 1. Cabal build-type: Simple (@hackage//:split)
  assertTrue "Simple (split)" (splitOn "," "a,b,c" == ["a", "b", "c"])

  -- 2. hackage.override wiring BCR @zlib//:zlib into @hackage//:zlib
  let sample = BL8.pack "hello-bcr-zlib-override"
  assertTrue "hackage.override (zlib + @zlib//:zlib)" (GZip.decompress (GZip.compress sample) == sample)

  -- 3. Cabal build-type: Configure + configure_args override + hsc2hs (@hackage//:network & unix-time)
  assertTrue "Configure (network)" (AF_INET == AF_INET && tupleToHostAddress (127, 0, 0, 1) /= 0)
  assertTrue "Configure + hsc2hs (unix-time)" (toEpochTime (fromEpochTime 1700000000) == 1700000000)

  -- 4. Cabal build-type: Custom cabal-doctest -> Simple (@hackage//:xml-conduit)
  case parseLBS def "<doc><ok/></doc>" of
    Left err -> putStrLn (show err) >> exitFailure
    Right d -> assertTrue "Custom cabal-doctest (xml-conduit)" (nameLocalName (elementName (documentRoot d)) == "doc")

  -- 5. C-only Cabal package (@hackage//:libyaml -> libyaml-clib)
  evs <- runConduitRes (Yaml.decode (BS8.pack "k: v\n") .| sinkList)
  assertTrue "C-only Cabal package (libyaml-clib)" (length evs >= 4)

  -- 6. Internal sublibrary (@hackage//:attoparsec__attoparsec-internal)
  --    and Cabal 3.0 public sublibrary (@hackage//:tar__tar-internal)
  assertTrue "Internal sublibrary (attoparsec-internal)" (memberChar 'a' (charClass "abc"))
  case toTarPath False "safe/file.txt" of
    Left e -> putStrLn e >> exitFailure
    Right tp -> do
      let entry = fileEntry tp "ok"
          sampleErr = AbsoluteFileName "/etc/passwd"
      assertTrue "Public sublibrary (tar:tar-internal)" (entryPath entry == "safe/file.txt" && show sampleErr /= "")

  -- 7. Cabal reexported-modules (@hackage//:ansi-terminal)
  assertTrue "reexported-modules (ansi-terminal)" (not (null (setSGRCode [Reset])))

  -- 8. Paths_<pkg> + source-bootstrapped Alex (.x) & Happy (.y) (@hackage//:pretty-show)
  assertTrue "Paths_* + Alex + Happy (pretty-show)" (parseValue "Just 42" /= Nothing)
