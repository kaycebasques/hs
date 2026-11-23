Literate Happy parser (.ly) using Bird-style `>` tracks.

> {
> module LitCalcParser (parseLitSum) where
>
> import CalcLexer (Token (..))
> }
>
> %name parseLitSum
> %tokentype { Token }
> %error { litParseError }
>
> %token
>   int   { TokInt $$ }
>   '+'   { TokPlus }
>
> %left '+'
>
> %%
>
> Sum :: { Int }
>   : Sum '+' int   { $1 + $3 }
>   | int           { $1 }
>
> {
> litParseError :: [Token] -> a
> litParseError toks = error ("LitCalcParser error: " ++ show toks)
> }
