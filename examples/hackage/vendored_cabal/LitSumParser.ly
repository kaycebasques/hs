Literate Happy grammar (.ly) summing `+`-separated integers.

> {
> module LitSumParser (evalLitSum) where
>
> import ExprLexer (Tok (..))
> }
>
> %name evalLitSum
> %tokentype { Tok }
> %error { litErr }
>
> %token
>   num { TNum $$ }
>   '+' { TAdd }
>
> %left '+'
>
> %%
>
> S :: { Int }
>   : S '+' num { $1 + $3 }
>   | num       { $1 }
>
> {
> litErr :: [Tok] -> a
> litErr ts = error ("LitSumParser error: " ++ show ts)
> }
