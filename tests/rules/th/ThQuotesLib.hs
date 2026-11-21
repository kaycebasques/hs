{-# LANGUAGE TemplateHaskellQuotes #-}
module ThQuotesLib
    ( quotedExpSummary
    , quotedMaybeTypeName
    , quotedJustValueName
    , quotedAddTree
    ) where

import Language.Haskell.TH
    ( Exp (..)
    , Lit (..)
    , Name
    , Q
    , nameBase
    , runQ
    )

-- Pure TemplateHaskellQuotes (no compile-time splices required):
-- quotes desugar to Language.Haskell.TH AST constructors backed by @hs_boot//:template-haskell.

quotedMaybeTypeName :: Name
quotedMaybeTypeName = ''Maybe

quotedJustValueName :: Name
quotedJustValueName = 'Just

quotedAddTree :: Q Exp
quotedAddTree = [| (20 :: Integer) + (22 :: Integer) |]

quotedExpSummary :: IO String
quotedExpSummary = do
    expr <- runQ [| 1 + 2 |]
    pure $ case expr of
        InfixE (Just (LitE (IntegerL a))) op (Just (LitE (IntegerL b))) ->
            show a ++ " " ++ describeOp op ++ " " ++ show b
        other ->
            "unexpected:" ++ show other
  where
    describeOp (VarE n) = nameBase n
    describeOp other    = show other
