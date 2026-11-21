module H98Lib (predH98, sumDownH98) where

-- NPlusKPatterns is enabled in Haskell98 and disabled in Haskell2010 / GHC2021.
predH98 :: Int -> Int
predH98 (n + 1) = n
predH98 _       = 0

sumDownH98 :: Int -> Int
sumDownH98 0       = 0
sumDownH98 (n + 1) = (n + 1) + sumDownH98 n
sumDownH98 _       = 0
