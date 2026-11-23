{-# LANGUAGE TemplateHaskell #-}

module EmbeddedLib (embeddedBanner) where

import Data.FileEmbed (embedStringFile)

embeddedBanner :: String
embeddedBanner = $(embedStringFile "banner.txt")
