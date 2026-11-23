Literate Haskell executable using LaTeX `\begin{code}` blocks.

\begin{code}
module Main (main) where

import LiterateCalc (triangularNumber)

main :: IO ()
main = print (triangularNumber 9)
\end{code}
