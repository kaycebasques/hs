Mutually recursive literate module A.

> module LitBootA (LitEven (..), isLitEven) where
>
> import LitBootB (isLitOdd)
>
> newtype LitEven = LitEven Bool
>     deriving (Eq, Show)
>
> isLitEven :: Int -> LitEven
> isLitEven 0 = LitEven True
> isLitEven n = LitEven (isLitOdd (abs n - 1))
