Literate Haskell module using Bird-style (`>`) code tracks.
Prose lines outside `>` blocks are stripped by GHC's staged `unlit` preprocessor.

> module LiterateBird (birdFibonacci, birdBanner) where
>
> birdBanner :: String
> birdBanner = "literate-bird-ok"
>
> birdFibonacci :: Int -> Int
> birdFibonacci n
>     | n <= 0 = 0
>     | n == 1 = 1
>     | otherwise = birdFibonacci (n - 1) + birdFibonacci (n - 2)
