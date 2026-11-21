module H2010Lib (doIfH2010, lookupAddH2010) where

-- DoAndIfThenElse (enabled in Haskell2010, rejected in Haskell98).
doIfH2010 :: Bool -> Maybe Int
doIfH2010 flag = do
    x <- Just 20
    if flag
    then return (x + 22)
    else return (x - 10)

-- PatternGuards (enabled in Haskell2010, rejected in Haskell98).
lookupAddH2010 :: [(String, Int)] -> String -> String -> Int
lookupAddH2010 env k1 k2
    | Just a <- lookup k1 env
    , Just b <- lookup k2 env = a + b
    | otherwise = -1
