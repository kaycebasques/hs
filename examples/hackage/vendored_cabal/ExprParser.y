{
module ExprParser (evalExpr) where

import ExprLexer (Tok (..))
}

%name evalExpr
%tokentype { Tok }
%error { parseErr }

%token
  num { TNum $$ }
  '+' { TAdd }
  '*' { TMul }

%left '+'
%left '*'

%%

E :: { Int }
  : E '+' E { $1 + $3 }
  | E '*' E { $1 * $3 }
  | num     { $1 }

{
parseErr :: [Tok] -> a
parseErr ts = error ("ExprParser error: " ++ show ts)
}
