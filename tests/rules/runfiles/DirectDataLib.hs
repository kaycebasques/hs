module DirectDataLib (readDirectLibData, readTransitiveLibData) where

import DataLib (readLibData, readRunfileTrimmed)

readDirectLibData :: IO String
readDirectLibData = readRunfileTrimmed "tests/rules/runfiles/direct_lib_data.txt"

readTransitiveLibData :: IO String
readTransitiveLibData = readLibData
