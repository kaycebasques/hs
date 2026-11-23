module ReplAlpha (
    alphaExported,
    replUniqueCompletionSymbol,
    replDebugTarget,
) where

alphaInternalSecret :: Int
alphaInternalSecret = 300

alphaExported :: Int -> Int
alphaExported n = n + alphaInternalSecret

replUniqueCompletionSymbol :: Int -> Int
replUniqueCompletionSymbol x = x * 11

replDebugTarget :: Int -> Int
replDebugTarget x =
    let doubled = x * 2
     in doubled
