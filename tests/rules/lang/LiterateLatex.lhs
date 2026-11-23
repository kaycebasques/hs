Literate Haskell module using LaTeX-style `\begin{code} ... \end{code}` blocks.

\begin{code}
module LiterateLatex (latexSquareSum) where

latexSquareSum :: [Int] -> Int
latexSquareSum xs = sum [x * x | x <- xs]
\end{code}
