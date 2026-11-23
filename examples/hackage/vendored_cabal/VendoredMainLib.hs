{-# LANGUAGE TemplateHaskell #-}

module VendoredMainLib
  ( pkgVer
  , embeddedPkgAsset
  ) where

import Data.FileEmbed (embedStringFile)
import Data.Version (showVersion)
import Paths_vendored_demo (version)

pkgVer :: String
pkgVer = showVersion version

embeddedPkgAsset :: String
embeddedPkgAsset = $(embedStringFile "pkg_asset.txt")
