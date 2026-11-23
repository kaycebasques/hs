{-# LANGUAGE TemplateHaskell #-}

module FileEmbedLib
    ( embeddedLibText
    , runIoLibText
    ) where

import Data.FileEmbed (embedStringFile)
import Language.Haskell.TH (litE, runIO, stringL)
import Language.Haskell.TH.Syntax (qAddDependentFile)

embeddedLibText :: String
embeddedLibText = $(embedStringFile "lib_embed_fixture.txt")

runIoLibText :: String
runIoLibText =
    $( do
        qAddDependentFile "tests/rules/th/lib_embed_fixture.txt"
        txt <- runIO (readFile "tests/rules/th/lib_embed_fixture.txt")
        litE (stringL txt)
     )
