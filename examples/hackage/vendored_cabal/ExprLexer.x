{
module ExprLexer (Tok (..), lexExpr) where
}

%wrapper "basic"

$digit = 0-9

tokens :-
  $white+   ;
  $digit+   { \s -> TNum (read s) }
  \+        { \_ -> TAdd }
  \*        { \_ -> TMul }

{
data Tok = TNum Int | TAdd | TMul
  deriving (Eq, Show)

lexExpr :: String -> [Tok]
lexExpr = alexScanTokens
}
