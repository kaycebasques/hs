module H2010 (lookupSumH2010) where

-- PatternGuards is enabled in Haskell2010+.
lookupSumH2010 :: [(String, Int)] -> String -> String -> Maybe Int
lookupSumH2010 env k1 k2
  | Just v1 <- lookup k1 env
  , Just v2 <- lookup k2 env =
      Just (v1 + v2)
  | otherwise = Nothing
