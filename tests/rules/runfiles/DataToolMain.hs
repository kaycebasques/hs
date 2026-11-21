module Main where

import DataLib (readLibData, readRunfileTrimmed)

main :: IO ()
main = do
    toolTxt <- readRunfileTrimmed "tests/rules/runfiles/tool_data.txt"
    libTxt <- readLibData
    putStrLn ("tool=" ++ toolTxt)
    putStrLn ("lib=" ++ libTxt)
