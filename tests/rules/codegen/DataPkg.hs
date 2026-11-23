{-# LANGUAGE TemplateHaskell #-}

module DataPkg
    ( embeddedCabalData
    , dataPkgVersionString
    , withSubHelper
    ) where

import Data.FileEmbed (embedStringFile)
import Data.Version (showVersion)
import Paths_demo_data_pkg (version)
import SubHelper (subHelperStep)

embeddedCabalData :: String
embeddedCabalData = $(embedStringFile "pkg_data.txt")

dataPkgVersionString :: String
dataPkgVersionString = showVersion version

withSubHelper :: Int -> Int
withSubHelper = subHelperStep
