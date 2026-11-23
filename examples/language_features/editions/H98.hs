module H98 (countdownH98) where

-- NPlusKPatterns is enabled in Haskell98 and removed in Haskell2010+.
countdownH98 :: Int -> Int
countdownH98 0 = 0
countdownH98 (n + 1) = (n + 1) + countdownH98 n
