{
-- UTF-8 grammar check under strict action env: Café λ
module CalcLexer (Token (..), scanCalc) where
}

%wrapper "basic"

$digit = 0-9

tokens :-
  $white+       ;
  $digit+       { \s -> TokInt (read s) }
  \+            { \_ -> TokPlus }
  \*            { \_ -> TokStar }
  \(            { \_ -> TokLParen }
  \)            { \_ -> TokRParen }

{
data Token
    = TokInt Int
    | TokPlus
    | TokStar
    | TokLParen
    | TokRParen
    deriving (Eq, Show)

scanCalc :: String -> [Token]
scanCalc = alexScanTokens
}
