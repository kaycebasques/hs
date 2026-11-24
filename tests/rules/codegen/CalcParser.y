{
-- UTF-8 grammar check under strict action env: Café λ
module CalcParser (parseCalc) where

import CalcLexer (Token (..))
}

%name parseCalc
%tokentype { Token }
%error { parseError }

%token
  int   { TokInt $$ }
  '+'   { TokPlus }
  '*'   { TokStar }
  '('   { TokLParen }
  ')'   { TokRParen }

%left '+'
%left '*'

%%

Expr :: { Int }
  : Expr '+' Expr   { $1 + $3 }
  | Expr '*' Expr   { $1 * $3 }
  | '(' Expr ')'    { $2 }
  | int             { $1 }

{
parseError :: [Token] -> a
parseError toks = error ("CalcParser syntax error on: " ++ show toks)
}
